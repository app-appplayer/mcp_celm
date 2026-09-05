import 'dart:io';

import 'package:mcp_celm/mcp_celm.dart';
import 'package:test/test.dart';

import 'fixtures/fixtures.dart';

/// TEST-PLAN §7 (packs compose), §8 (a primitive, not one consumer's
/// backend), §9 (knowledge in descriptor terms), §12/§13 (regime and
/// safety), §17 (platform).
void main() {
  Matcher refused(String code) =>
      throwsA(isA<AnalysisError>().having((e) => e.code, 'code', code));

  const path = {'path': '/tmp/notes.txt'};

  group('§7 one runtime, packs that compose', () {
    test(
        'a second domain, same surface: zero runtime change, zero skill re-authoring',
        () async {
      final port = build(
          manifest: manifestJson(domain: 'oven'),
          perception: desktopWithPanel());
      final o = await run(port, 'read_panel_status');
      expect(o, isA<CelmCompleted>());
      final j =
          (o as CelmCompleted).conclusions.whereType<JudgedConclusion>().single;
      expect(j.reasoner, 'rules:oven');
      expect(port.manifest.surface.id, 'desktop-hid');
    });

    test('a second surface, same domain: the references are used unchanged',
        () async {
      final bus = scpi();
      final port = build(
        manifest: manifestJson(surface: 'scpi-bus'),
        perception: perceptionAfterActs(bus,
            before: {
              'panel': {'mode': cell('run')}
            },
            after: panel(color2: 'red')),
        actuators: {'hid': hid(), 'scpi': bus},
      );
      final o = await run(port, 'read_panel_status');
      expect(o, isA<CelmCompleted>());
      expect(bus.actions.single.verb, 'query');
      final j =
          (o as CelmCompleted).conclusions.whereType<JudgedConclusion>().single;
      expect(j.reasoner, 'rules:lab-panel');
      // The same reference reached the same question over a different surface.
      final branch =
          port.manifest.surface.goals['read_panel_status']!.steps['q']!.branch!;
      expect(branch.check.attached.map((r) => r.id), ['panel_supply_nominal']);
    });

    test('knowledge names no skill', () {
      expect(
          () => CelmDomainPack.fromJson(
              {...labPanelDomain(), 'goals': <Object>[]}),
          refused('pack.domain_names_surface'));
    });

    test('runtime holds no pack symbol and no consumer concept (NFR-ISO)', () {
      final core = Directory('lib/src/core').listSync().whereType<File>();
      for (final f in core) {
        final src = f.readAsStringSync();
        for (final banned in [
          'hw_os',
          'desktop-hid',
          'lab-panel',
          'scpi',
          'gimbal',
          'RK3588',
          'dart:io'
        ]) {
          expect(src.contains(banned), isFalse,
              reason: '${f.path} mentions $banned');
        }
      }
    });

    test('packs are data: both load from JSON with no code path of their own',
        () {
      final s = CelmSurfacePack.fromJson(desktopSurface());
      final d = CelmDomainPack.fromJson(labPanelDomain());
      expect(s.skills, isNotEmpty);
      expect(d.references, isNotEmpty);
    });
  });

  group('§8 a primitive, not one consumer\'s backend', () {
    test('two shapes, one runtime: a read-only bench and a writing screen',
        () async {
      final bench = build(
        manifest: manifestJson(surface: 'scpi-bus', outputs: [
          {
            'actuator': 'scpi',
            'port': 'mcp:scpi',
            'vocab': ['query']
          },
        ]),
        perception: ScriptedPerception((r, i) => obsFor(r, panel())),
      );
      expect(await run(bench, 'read_panel_status'), isA<CelmCompleted>());
      final screen = build(perception: openFlow().perception);
      expect(screen.manifest.outputs['hid']!.writes, CelmWrites.allowList);
    });

    test(
        'ports are named, not imported: swapping the perception tool is a manifest edit',
        () async {
      final callerA = InMemoryToolCaller({
        'visionA.read': (args) async =>
            obsFor(CelmObserveRequest.fromJson(args), desktopOpen()).toJson(),
      });
      final callerB = InMemoryToolCaller({
        'visionB.look': (args) async =>
            obsFor(CelmObserveRequest.fromJson(args), desktopOpen()).toJson(),
      });
      for (final (caller, server, tool) in [
        (callerA, 'visionA', 'read'),
        (callerB, 'visionB', 'look')
      ]) {
        final port = build(
          manifest: manifestJson(inputs: [
            {
              'channel': 'vision',
              'port': 'mcp:$server.$tool',
              'schema': 'descriptor@0.3'
            },
          ]),
          perception:
              McpPerceptionAdapter(caller: caller, server: server, tool: tool),
        );
        expect(await run(port, 'open_document', params: path),
            isA<CelmCompleted>());
        expect(caller.calls.first.$1, server);
      }
    });
  });

  group('§9 knowledge in descriptor terms', () {
    test('a reference is checkable against a descriptor without a model', () {
      final d = CelmDomainPack.fromJson(labPanelDomain());
      final ref = d.references['panel_supply_nominal']!;
      final v = CelmFieldValue.resolve(panel(), ref.field);
      expect(v.value, [3.30, 3.29, 3.31]);
      expect(ref.expected['value'], 3.30);
    });

    test('attached by overlap, and by name; unknown name refused', () {
      final port = build();
      final open = port.manifest.surface.skills['open_file']!;
      final judge = open.postconditions.last;
      expect(judge.attached, isEmpty,
          reason: 'no reference under window.frontmost');
      final branch = port
          .manifest.surface.goals['read_panel_status']!.steps['read']!.branch!;
      expect(branch.check.attached.map((r) => r.id), ['panel_supply_nominal']);

      final named = build(
        surface: desktopSurface(extraSkills: [
          {
            'name': 'x',
            'action': {'sequence': <Object>[]},
            'postconditions': [
              judgeCheck('fine?', ['app'], references: ['panel_supply_nominal'])
            ],
          },
        ]),
      );
      expect(
          named.manifest.surface.skills['x']!.postconditions.single.attached
              .single.id,
          'panel_supply_nominal');
      expect(
          () => build(
                surface: desktopSurface(extraSkills: [
                  {
                    'name': 'x',
                    'action': {'sequence': <Object>[]},
                    'postconditions': [
                      judgeCheck('fine?', ['app'], references: ['nope'])
                    ],
                  },
                ]),
              ),
          refused('pack.unknown_reference'));
    });

    test(
        'the runtime does not apply a reference: within and outside tolerance both reach the reasoner',
        () async {
      for (final voltage in [3.30, 9.99]) {
        final reasoner = constantReasoner(false, 0.9);
        final port = build(
          manifest: manifestJson(reasoner: {'kind': 'llm'}),
          reasoner: reasoner,
          perception: ScriptedPerception((r, i) => obsFor(
              r,
              r.depth == CelmDepth.atoms
                  ? {
                      ...desktopOpen(),
                      'panel': {
                        'mode': cell('run'),
                        'indicators': [
                          {
                            'state': cell('ok'),
                            'color': cell('green'),
                            'voltage': cell(voltage)
                          },
                        ],
                      },
                    }
                  : {
                      ...desktopOpen(),
                      'panel': {'mode': cell('run')}
                    })),
        );
        await run(port, 'read_panel_status');
        expect(reasoner.calls, 1, reason: 'voltage $voltage');
        expect(reasoner.requests.single.digest.knowledge.single.id,
            'panel_supply_nominal');
      }
    });
  });

  group('§13 safety', () {
    test('a writing skill outside the allow-list cannot load', () {
      expect(
          () => build(
                manifest: manifestJson(outputs: [
                  {
                    'actuator': 'hid',
                    'port': 'mcp:hid',
                    'vocab': ['click', 'type', 'key', 'scroll'],
                    'writes': 'allow_list',
                    'allowed': ['click', 'type'],
                  },
                  {
                    'actuator': 'scpi',
                    'port': 'mcp:scpi',
                    'vocab': ['query']
                  },
                ]),
              ),
          refused('manifest.write_not_permitted'));
    });

    test(
        'irreversible, interlock open: escalates irreversibleGate; actuator not called',
        () async {
      final actuator = hid();
      final interlock = ScriptedInterlock(false);
      final port = build(
        actuators: {'hid': actuator, 'scpi': scpi()},
        interlock: interlock,
        perception: perceptionAfterActs(actuator,
            before: desktopOpen(),
            after: {...desktopOpen(), 'deleted': cell(true)}),
      );
      final o = await run(port, 'delete_document', params: path);
      expect(
          (o as CelmEscalated).reason, CelmEscalationReason.irreversibleGate);
      expect(interlock.asked, 1);
      expect(actuator.actions, isEmpty);
    });

    test(
        'confidence does not authorize: reasoner at 0.99, interlock open, still escalates',
        () async {
      final actuator = hid();
      final port = build(
        manifest: manifestJson(reasoner: {'kind': 'llm'}),
        reasoner: constantReasoner(true, 0.99),
        actuators: {'hid': actuator, 'scpi': scpi()},
        interlock: ScriptedInterlock(false),
        perception: perceptionAfterActs(actuator,
            before: desktopOpen(),
            after: {...desktopOpen(), 'deleted': cell(true)}),
      );
      final o = await run(port, 'delete_document', params: path);
      expect(
          (o as CelmEscalated).reason, CelmEscalationReason.irreversibleGate);
      expect(actuator.actions, isEmpty);
    });

    test('interlock closed: acts', () async {
      final actuator = hid();
      final port = build(
        actuators: {'hid': actuator, 'scpi': scpi()},
        interlock: ScriptedInterlock(true),
        perception: perceptionAfterActs(actuator,
            before: desktopOpen(),
            after: {...desktopOpen(), 'deleted': cell(true)}),
      );
      final o = await run(port, 'delete_document', params: path);
      expect(o, isA<CelmCompleted>());
      expect(actuator.actions.single.verb, 'key');
    });

    test('interlock required when any skill is irreversible', () {
      expect(
          () => build(noInterlock: true), refused('celm.interlock_required'));
    });

    test(
        'read-only refuses a write; actuator not called; a constraint cannot widen',
        () async {
      final actuator = hid();
      final port = build(
          actuators: {'hid': actuator, 'scpi': scpi()},
          perception: answering((i) => desktopOpen(title: 'blank')));
      final o = await run(port, 'open_document',
          params: path, constraints: const CelmConstraints(readOnly: true));
      expect((o as CelmRefused).reason, CelmRefusalReason.notPermitted);
      expect(actuator.actions, isEmpty);
    });

    test(
        'policy default: a manifest with no theta_pass loads and uses the documented default',
        () {
      expect(
          build(manifest: manifestJson(policy: {})).manifest.policy.thetaPass,
          0.85);
    });

    test('depth reaches perception', () async {
      final perception = desktopWithPanel();
      final port = build(perception: perception);
      await run(port, 'read_panel_status');
      expect(perception.requests.map((r) => '${r.scope}@${r.depth.name}'),
          contains('panel@atoms'));
    });

    test('actor reaches authorization before anything else', () async {
      final port = build();
      expect(
        () => port.execute(const CelmGoalRef(id: 'open_document', params: path),
            actor: const AnalysisActor(id: 'v', role: 'viewer')),
        refused('governance.unauthorized'),
      );
      // A read-only goal is fine for a viewer.
      final o = await run(port, 'three_plain',
          actor: const AnalysisActor(id: 'v', role: 'viewer'));
      expect(o, isA<CelmOutcome>());
      expect(
          () => port.cancel('x',
              actor: const AnalysisActor(id: 'v', role: 'viewer')),
          refused('governance.unauthorized'));
      expect(
          () => port.resume('x', const ResumeAt('a'),
              actor: const AnalysisActor(id: 'v', role: 'viewer')),
          refused('governance.unauthorized'));
      expect(
          await port.observe(
              actor: const AnalysisActor(id: 'v', role: 'viewer')),
          isA<CelmObservation>());
    });
  });

  group('§17 platform', () {
    test('no dart:io in lib/', () {
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      for (final f in files) {
        expect(f.readAsStringSync().contains('dart:io'), isFalse,
            reason: f.path);
      }
    });

    test('seven tools, and celm.execute has no slot for structure', () {
      expect(CelmToolHandler.tools, hasLength(7));
      final exec = CelmToolHandler.schemas['celm.execute']!;
      final goal = (exec['properties'] as Map)['goal'] as Map;
      expect((goal['properties'] as Map).keys, ['id', 'params']);
      expect(goal['additionalProperties'], isFalse);
    });
  });
}
