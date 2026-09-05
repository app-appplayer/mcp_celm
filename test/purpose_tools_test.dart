import 'package:mcp_celm/mcp_celm.dart';
import 'package:test/test.dart';

import 'fixtures/fixtures.dart';

/// TEST-PLAN §16 (the purpose, measured), §14 (arms A and B), §17 (the
/// tool surface). The package exists to take load off the model; these
/// count and size rather than describe.
void main() {
  const path = {'path': '/tmp/notes.txt'};

  group('§16 the purpose, measured', () {
    test(
        'a routine goal reaches no model: zero reasoner calls, zero planner calls',
        () async {
      final reasoner = constantReasoner(true, 0.9);
      final port = build(
        manifest: manifestJson(reasoner: {'kind': 'llm'}),
        reasoner: reasoner,
        perception: answering(
            (i) => {...desktopOpen(), if (i >= 3) 'steps_done': cell(true)}),
      );
      final o = await run(port, 'three_plain');
      expect(o, isA<CelmCompleted>());
      expect(port.runner.counters.reasonerCalls, 0);
      expect((o as CelmCompleted).budget.escalationsSpent, 0,
          reason: 'no planner call');
    });

    test(
        'a judged goal on a local reasoner reaches no planner while confidence holds',
        () async {
      final port = build(perception: desktopWithPanel(color2: 'red'));
      final o = await run(port, 'read_panel_status') as CelmCompleted;
      expect(port.runner.counters.reasonerCalls, 1);
      expect(o.budget.escalationsSpent, 0);
      expect(port.manifest.reasoner.remote, isFalse);
    });

    test('the digest is bounded by the check, not by the descriptor', () async {
      Future<int> payloadFor(int noise) async {
        final reasoner = constantReasoner(true, 0.1);
        final flow = openFlow();
        final port = build(
          manifest: manifestJson(reasoner: {'kind': 'llm'}),
          reasoner: reasoner,
          perception: ScriptedPerception((r, i) => obsFor(r, {
                ...(flow.actuator.actions.length >= 3
                    ? desktopOpen()
                    : desktopOpen(title: 'blank')),
                for (var k = 0; k < noise; k++)
                  'widget_$k': {
                    'text': cell('lorem ipsum $k'),
                    'bounds': cell([k, k, k, k])
                  },
              })),
          actuators: {'hid': flow.actuator, 'scpi': scpi()},
        );
        final o = await run(port, 'open_document', params: path);
        return (o as CelmEscalated).digest.toJson().toString().length;
      }

      final small = await payloadFor(0);
      final large = await payloadFor(1000);
      expect(small, greaterThan(0));
      expect(large, equals(small),
          reason:
              'grow the descriptor a thousandfold; the payload does not grow');
    });

    test('the planner may ask for more through observe', () async {
      final perception = desktopWithPanel();
      final port = build(perception: perception);
      final wide = await port.observe(
          request:
              const CelmObserveRequest(scope: 'panel', depth: CelmDepth.atoms));
      expect(wide.descriptor['panel'], isA<Map<String, dynamic>>());
      expect(wide.coverage.single.depth, CelmDepth.atoms);
    });

    test('a remote reasoner is marked on every conclusion', () async {
      final flow = openFlow();
      final port = build(
        manifest: manifestJson(reasoner: {'kind': 'llm'}),
        reasoner: constantReasoner(true, 0.95, remote: true),
        perception: flow.perception,
        actuators: {'hid': flow.actuator, 'scpi': scpi()},
      );
      final o = await run(port, 'open_document', params: path) as CelmCompleted;
      final judged = o.conclusions.whereType<JudgedConclusion>();
      expect(judged, isNotEmpty);
      expect(judged.every((j) => j.reasonerRemote), isTrue);
    });

    test('a remote reasoner is never a default', () {
      expect(
        () => build(manifest: manifestJson()..remove('reasoner')),
        throwsA(isA<AnalysisError>()
            .having((e) => e.code, 'code', 'manifest.unsourced_reasoner')),
      );
    });

    test(
        'a new domain costs no code: second domain pack, zero training, zero skill re-authoring',
        () async {
      // The same surface pack JSON, byte for byte, with a different domain.
      final a = build(
          manifest: manifestJson(domain: 'lab-panel'),
          perception: desktopWithPanel(color2: 'red'));
      final b = build(
          manifest: manifestJson(domain: 'oven'),
          perception: desktopWithPanel(color2: 'red'));
      expect(await run(a, 'read_panel_status'), isA<CelmCompleted>());
      expect(await run(b, 'read_panel_status'), isA<CelmCompleted>());
      expect(b.manifest.surface.skills.keys, a.manifest.surface.skills.keys);
    });
  });

  group('§14 the claim this exists to support (arms A and B)', () {
    /// Arm A: a planner drives every step directly against the same
    /// perception and actuators — no graph, no postconditions, no gate.
    /// It advances after each action whether or not the action took.
    Future<({int unverifiedAdvances, bool succeeded, int plannerCalls})>
        armA() async {
      final actuator = hid(failWith: StateError('the click did not land'));
      var plannerCalls = 0;
      var unverified = 0;
      final steps = ['click', 'key', 'type', 'key'];
      for (final verb in steps) {
        plannerCalls++;
        try {
          await actuator.act(CelmAction(actuator: 'hid', verb: verb));
        } catch (_) {
          // The planner is not told; it proceeds.
        }
        unverified++;
      }
      return (
        unverifiedAdvances: unverified,
        succeeded: false,
        plannerCalls: plannerCalls
      );
    }

    /// Arm B: this package, same failing actuator.
    Future<({int unverifiedAdvances, bool succeeded, int plannerCalls})>
        armB() async {
      final actuator = hid(failWith: StateError('the click did not land'));
      final port = build(
        perception: answering((i) => desktopEmpty()),
        actuators: {'hid': actuator, 'scpi': scpi()},
      );
      final o = await run(port, 'open_document', params: path);
      return (
        unverifiedAdvances: port.runner.counters.stepsAdvanced,
        succeeded: o is CelmCompleted,
        plannerCalls: o is CelmEscalated ? 1 : 0,
      );
    }

    test('arm A advances past steps that did not happen; arm B cannot',
        () async {
      final a = await armA();
      final b = await armB();
      expect(a.unverifiedAdvances, 4);
      expect(b.unverifiedAdvances, 0);
      expect(b.succeeded, isFalse,
          reason: 'it stopped and handed up, rather than claiming success');
      expect(b.plannerCalls, 1,
          reason: 'one escalation, not one call per step');
      expect(a.plannerCalls, 4);
    });
  });

  group('§17 the tool surface', () {
    test('every tool round-trips through JSON and comes back as its own type',
        () async {
      final flow = openFlow();
      final port = build(
        manifest: manifestJson(reasoner: {'kind': 'llm'}),
        reasoner: constantReasoner(true, 0.1),
        perception: flow.perception,
        actuators: {'hid': flow.actuator, 'scpi': scpi()},
      );
      final tools = CelmToolHandler(port);

      final started = await tools.call('celm.execute', {
        'goal': {'id': 'open_document', 'params': path},
        'constraints': {'deadlineMs': 5000},
      });
      final runId = started['runId'] as String;
      expect(started.keys, ['runId']);

      // Over a wire, the outcome is read from progress.
      Map<String, dynamic> progress;
      do {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        progress = await tools.call('celm.progress', {'runId': runId});
      } while (progress['escalated'] != true && progress['outcome'] == null);
      expect(progress['escalated'], isTrue);
      expect(CelmProgress.fromJson(progress).escalated, isTrue);

      final observed = await tools.call('celm.observe', {
        'request': {'scope': 'screen', 'depth': 'structure'}
      });
      expect(CelmObservation.fromJson(observed).coverage.single.depth,
          CelmDepth.structure);

      final standalone = await tools.call('celm.standalone', {'runId': runId});
      final list =
          (standalone['conclusions'] as List).cast<Map<String, dynamic>>();
      expect(
          list
              .map(CelmConclusion.fromJson)
              .every((c) => c is ObservedConclusion),
          isTrue);

      final explained =
          await tools.call('celm.explain', {'conclusionId': list.first['id']});
      expect(CelmEvidence.fromJson(explained).conclusion,
          isA<ObservedConclusion>());

      final resumed = await tools.call('celm.resume', {
        'runId': runId,
        'resumption': {'kind': 'abandon', 'why': 'test'},
        'actor': {'id': 'op', 'role': 'operator'},
      });
      expect(CelmOutcome.fromJson(resumed), isA<CelmCancelled>());

      final after = await tools.call('celm.progress', {'runId': runId});
      expect(CelmOutcome.fromJson(after['outcome'] as Map<String, dynamic>),
          isA<CelmCancelled>());

      final cancelled = await tools.call('celm.cancel', {'runId': runId});
      expect(CelmOutcome.fromJson(cancelled), isA<CelmCancelled>());
    });

    test('an unknown tool, a missing argument, an unknown kind are refused',
        () async {
      final tools = CelmToolHandler(build());
      Matcher refused(String code) =>
          throwsA(isA<AnalysisError>().having((e) => e.code, 'code', code));
      expect(() => tools.call('celm.fly', {}), refused('celm.unknown_tool'));
      expect(
          () => tools.call('celm.progress', {}), refused('celm.missing_field'));
      expect(
          () => tools.call('celm.resume', {
                'runId': 'r',
                'resumption': {'kind': 'retry'}
              }),
          refused('celm.unknown_value'));
      expect(
          () => tools.call('celm.observe', {
                'request': {'depth': 'atom'}
              }),
          refused('celm.unknown_value'));
    });

    test(
        'the MCP actuator adapter maps a verb to a tool call and refuses one it lacks',
        () async {
      final caller = InMemoryToolCaller({'hid.key': (a) async => {}});
      final adapter = McpActuatorAdapter(
          caller: caller, server: 'hid', vocabulary: {'key'});
      await adapter.act(const CelmAction(
          actuator: 'hid', verb: 'key', args: {'combo': 'Cmd+O'}));
      expect(caller.calls.single.$1, 'hid');
      expect(caller.calls.single.$2, 'key');
      expect(caller.calls.single.$3, {'combo': 'Cmd+O'});
      expect(
          () => adapter.act(const CelmAction(actuator: 'hid', verb: 'launch')),
          throwsA(isA<AnalysisError>()
              .having((e) => e.code, 'code', 'celm.actuator_failed')));
    });

    test('the MCP perception adapter takes coverage verbatim and infers none',
        () async {
      final caller = InMemoryToolCaller({
        'vision.read': (a) async =>
            {'descriptor': desktopOpen(), 'at': '2026-09-04T00:00:00Z'},
      });
      final adapter =
          McpPerceptionAdapter(caller: caller, server: 'vision', tool: 'read');
      final o = await adapter.observe(const CelmObserveRequest());
      expect(o.coverage, isEmpty, reason: 'content is not coverage');
    });

    test('the MCP interlock adapter reads satisfied and nothing else as open',
        () async {
      final yes = McpInterlockAdapter(
          caller: InMemoryToolCaller({
            'hil.check': (a) async => {'satisfied': true}
          }),
          server: 'hil',
          tool: 'check');
      final no = McpInterlockAdapter(
          caller: InMemoryToolCaller({
            'hil.check': (a) async => {'ok': true}
          }),
          server: 'hil',
          tool: 'check');
      const action = CelmAction(actuator: 'hid', verb: 'key');
      final state = obs(desktopOpen());
      expect(await yes.satisfied(action, state), isTrue);
      expect(await no.satisfied(action, state), isFalse);
    });
  });
}
