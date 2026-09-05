/// Test doubles and packs. The perception stub here is the reference
/// producer of the descriptor shape this package consumes (infra-ports
/// §2): path-addressable fields, per-field quality as cells, coverage
/// entries with depth.
library;

import 'dart:async';

import 'package:mcp_celm/mcp_celm.dart';

// ---------------------------------------------------------------------------
// Descriptors
// ---------------------------------------------------------------------------

Map<String, dynamic> cell(Object? value, [double quality = 0.95]) =>
    {'value': value, 'quality': quality};

/// A desktop with the editor focused and a document window in front.
Map<String, dynamic> desktopOpen(
        {String title = 'notes.txt', double q = 0.95}) =>
    {
      'app': {'focused': cell(true, q), 'name': cell('Editor', q)},
      'window': {
        'frontmost': {'title': cell(title, q), 'usable': cell(true, q)},
      },
    };

/// A desktop with nothing open yet.
Map<String, dynamic> desktopEmpty() => {
      'app': {'focused': cell(false), 'name': cell('Finder')},
    };

/// A lab panel with three indicators.
Map<String, dynamic> panel({String color2 = 'green', double q = 0.9}) => {
      'panel': {
        'mode': cell('run', q),
        'indicators': [
          {
            'state': cell('ok', q),
            'color': cell('green', q),
            'voltage': cell(3.30, q)
          },
          {
            'state': cell('ok', q),
            'color': cell('green', q),
            'voltage': cell(3.29, q)
          },
          {
            'state': cell('fault', q),
            'color': cell(color2, q),
            'voltage': cell(3.31, q)
          },
        ],
      },
    };

CelmObservation obs(Map<String, dynamic> descriptor,
        {List<CelmCoverage> coverage = const [
          CelmCoverage(scope: 'screen', depth: CelmDepth.atoms),
        ],
        DateTime? at}) =>
    CelmObservation(
        descriptor: descriptor,
        coverage: coverage,
        at: at ?? DateTime.utc(2026, 9, 4));

/// The honest producer: an observation that covers exactly what was
/// asked — the requested scope, at the requested depth.
CelmObservation obsFor(CelmObserveRequest r, Map<String, dynamic> descriptor) =>
    obs(descriptor,
        coverage: [CelmCoverage(scope: r.scope ?? 'screen', depth: r.depth)]);

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// Answers observation requests from a script: a function of the request
/// and the call index. Records every request.
class ScriptedPerception implements CelmPerceptionPort {
  ScriptedPerception(this.script,
      {this.depths = const {
        CelmDepth.coarse,
        CelmDepth.structure,
        CelmDepth.atoms
      }});
  final CelmObservation Function(CelmObserveRequest request, int call) script;
  final List<CelmObserveRequest> requests = [];
  @override
  final Set<CelmDepth> depths;

  int get calls => requests.length;

  @override
  Future<CelmObservation> observe(CelmObserveRequest request) async {
    requests.add(request);
    return script(request, requests.length - 1);
  }
}

/// A perception whose answer changes when the actuator has acted:
/// [before] until [actuator] has performed [after] actions, then [after].
ScriptedPerception perceptionAfterActs(
  RecordingActuator actuator, {
  required Map<String, dynamic> before,
  required Map<String, dynamic> after,
  int actsNeeded = 1,
}) =>
    ScriptedPerception((r, i) =>
        obsFor(r, actuator.actions.length >= actsNeeded ? after : before));

/// A desktop with a lab panel on it, answered honestly by depth: at
/// `structure` the panel is a region with a mode; only at `atoms` are its
/// indicators readable.
ScriptedPerception desktopWithPanel(
        {String color2 = 'green', double q = 0.9}) =>
    ScriptedPerception((r, i) => obsFor(
        r,
        r.depth == CelmDepth.atoms
            ? {...desktopOpen(), ...panel(color2: color2, q: q)}
            : {
                ...desktopOpen(),
                'panel': {'mode': cell('run', q)},
              }));

/// Answers every request with [descriptor], covering what was asked.
ScriptedPerception answering(
        Map<String, dynamic> Function(int call) descriptor) =>
    ScriptedPerception((r, i) => obsFor(r, descriptor(i)));

/// The open-document flow: focused, a blank window; after the actuator
/// has acted, the document is in front.
({RecordingActuator actuator, ScriptedPerception perception}) openFlow(
    {int actsNeeded = 3}) {
  final a = hid();
  return (
    actuator: a,
    perception: perceptionAfterActs(a,
        before: desktopOpen(title: 'blank'),
        after: desktopOpen(),
        actsNeeded: actsNeeded),
  );
}

/// Records actions; can fail, delay, or refuse a verb.
class RecordingActuator implements CelmActuatorPort {
  RecordingActuator({
    required this.vocabulary,
    this.kinds = const {},
    this.failWith,
    this.delay,
  });
  @override
  final Set<String> vocabulary;
  @override
  final Map<String, CelmActionKind> kinds;
  final Object? failWith;
  final Duration? delay;
  final List<CelmAction> actions = [];

  @override
  Future<void> act(CelmAction action) async {
    actions.add(action);
    if (delay != null) await Future<void>.delayed(delay!);
    if (failWith != null) throw failWith!;
  }
}

class ScriptedInterlock implements CelmInterlockPort {
  ScriptedInterlock(this.answer);
  bool answer;
  int asked = 0;
  @override
  Future<bool> satisfied(CelmAction action, CelmObservation state) async {
    asked++;
    return answer;
  }
}

/// A reasoner that answers from a script and counts calls.
class ScriptedReasoner implements CelmReasoner {
  ScriptedReasoner(this.answer, {this.id = 'scripted', this.remote = false});
  final CelmJudgment Function(CelmJudgmentRequest request, int call) answer;
  @override
  final String id;
  @override
  final bool remote;
  final List<CelmJudgmentRequest> requests = [];
  int get calls => requests.length;

  @override
  Future<CelmJudgment> judge(CelmJudgmentRequest request) async {
    requests.add(request);
    return answer(request, requests.length - 1);
  }
}

ScriptedReasoner constantReasoner(bool verdict, double confidence,
        {bool remote = false}) =>
    ScriptedReasoner(
        (r, i) => CelmJudgment(
            verdict: verdict, confidence: confidence, rationale: 'scripted'),
        remote: remote);

class FakeClock {
  DateTime now = DateTime.utc(2026, 9, 4, 12);
  void advance(Duration d) => now = now.add(d);
  DateTime call() => now;
}

/// A tool caller over in-memory ports, for the MCP adapters.
class InMemoryToolCaller implements McpToolCaller {
  InMemoryToolCaller(this.handlers);
  final Map<String, Future<Map<String, dynamic>> Function(Map<String, dynamic>)>
      handlers;
  final List<(String, String, Map<String, dynamic>)> calls = [];
  @override
  Future<Map<String, dynamic>> call(
      String server, String tool, Map<String, dynamic> args) {
    calls.add((server, tool, args));
    final h = handlers['$server.$tool'];
    if (h == null) throw StateError('no tool $server.$tool');
    return h(args);
  }
}

// ---------------------------------------------------------------------------
// Packs
// ---------------------------------------------------------------------------

Map<String, dynamic> observeCheck(String expr,
        {double quality = 0, String depth = 'structure'}) =>
    {
      'kind': 'observe',
      'expr': expr,
      'requires_quality': quality,
      'requires_depth': depth
    };

Map<String, dynamic> judgeCheck(String ask, List<String> reads,
        {List<String>? references, String depth = 'structure'}) =>
    {
      'kind': 'judge',
      'ask': ask,
      'reads': reads,
      if (references != null) 'references': references,
      'requires_depth': depth,
    };

/// The desktop surface: HID skills, and goals over them.
Map<String, dynamic> desktopSurface({
  List<Map<String, dynamic>> extraSkills = const [],
  List<Map<String, dynamic>> extraGoals = const [],
}) =>
    {
      'pack': CelmSurfacePack.schema,
      'id': 'desktop-hid',
      'skills': [
        {
          'name': 'focus_app',
          'params': {'app': 'string'},
          'action': {
            'sequence': [
              {
                'port': 'hid.click',
                'args': {'target': r'$app'}
              },
            ]
          },
          'postconditions': [observeCheck('app.focused == true')],
          'writes': true,
        },
        {
          'name': 'open_file',
          'params': {'path': 'string'},
          'preconditions': [observeCheck('app.focused == true')],
          'action': {
            'sequence': [
              {
                'port': 'hid.key',
                'args': {'combo': 'Cmd+O'}
              },
              {
                'port': 'hid.type',
                'args': {'text': r'$path'}
              },
              {
                'port': 'hid.key',
                'args': {'combo': 'Enter'}
              },
            ]
          },
          'postconditions': [
            observeCheck(r'window.frontmost.title contains basename($path)',
                quality: 0.8),
            judgeCheck('Did the document open in a usable state?',
                ['window.frontmost']),
          ],
          'writes': true,
          'timeout_ms': 200,
        },
        {
          'name': 'look',
          'action': {'sequence': <Object>[]},
          'postconditions': [observeCheck('app.name != null')],
        },
        {
          'name': 'read_indicators',
          'action': {'sequence': <Object>[]},
          'postconditions': [
            observeCheck('panel.indicators.count >= 1', depth: 'atoms')
          ],
        },
        {
          'name': 'delete_file',
          'params': {'path': 'string'},
          'action': {
            'sequence': [
              {
                'port': 'hid.key',
                'args': {'combo': 'Cmd+Backspace'}
              },
            ]
          },
          'postconditions': [observeCheck('app.focused == true')],
          'writes': true,
          'reversibility': 'irreversible',
        },
        ...extraSkills,
      ],
      'goals': [
        {
          'id': 'open_document',
          'params': {'path': 'string'},
          'observe': {'scope': 'screen', 'depth': 'structure'},
          'entry': 'open',
          'steps': {
            'focus': {
              'skill': 'focus_app',
              'params': {'app': 'Editor'},
              'on_pass': 'open',
              'on_fail': null
            },
            'open': {
              'skill': 'open_file',
              'params': {'path': r'$path'},
              'on_pass': null,
              'on_fail': 'focus'
            },
          },
          'completion': [
            observeCheck(r'window.frontmost.title contains basename($path)')
          ],
        },
        {
          'id': 'three_plain',
          'observe': {'scope': 'screen', 'depth': 'structure'},
          'entry': 'a',
          'steps': {
            'a': {'skill': 'look', 'on_pass': 'b'},
            'b': {'skill': 'look', 'on_pass': 'c'},
            'c': {'skill': 'look', 'on_pass': null},
          },
          'completion': [observeCheck('steps_done == true')],
        },
        {
          'id': 'read_panel_status',
          'observe': {'scope': 'screen', 'depth': 'structure'},
          'entry': 'read',
          'steps': {
            'read': {
              'skill': 'read_indicators',
              'observe': {'scope': 'panel', 'depth': 'atoms'},
              'on_pass': null,
              'branch': {
                ...judgeCheck('Do the indicators show a fault condition?',
                    ['panel.indicators[*].color'],
                    depth: 'atoms'),
                'on_true': 'detail',
                'on_false': null,
              },
            },
            'detail': {
              'skill': 'look',
              'observe': {'scope': 'panel', 'depth': 'atoms'},
              'on_pass': null
            },
          },
          'completion': [
            observeCheck('panel.indicators.count >= 1', depth: 'atoms'),
            observeCheck('panel.indicators.all(has(state))', depth: 'atoms'),
          ],
        },
        {
          'id': 'judged_done',
          'observe': {'scope': 'screen', 'depth': 'structure'},
          'entry': 'a',
          'steps': {
            'a': {'skill': 'look', 'on_pass': null},
          },
          'completion': [
            judgeCheck('Is the desktop in a usable state?', ['app'])
          ],
        },
        {
          'id': 'delete_document',
          'params': {'path': 'string'},
          'observe': {'scope': 'screen', 'depth': 'structure'},
          'entry': 'del',
          'steps': {
            'del': {
              'skill': 'delete_file',
              'params': {'path': r'$path'},
              'on_pass': null
            },
          },
          'completion': [observeCheck('deleted == true')],
        },
        ...extraGoals,
      ],
      'intents': {'open it': 'open_document'},
    };

/// A second surface — the same subject reached over an instrument bus.
Map<String, dynamic> scpiSurface() => {
      'pack': CelmSurfacePack.schema,
      'id': 'scpi-bus',
      'skills': [
        {
          'name': 'query_panel',
          'action': {
            'sequence': [
              {
                'port': 'scpi.query',
                'args': {'cmd': 'STAT:PANEL?'}
              },
            ]
          },
          'postconditions': [
            observeCheck('panel.indicators.count >= 1', depth: 'atoms')
          ],
        },
      ],
      'goals': [
        {
          'id': 'read_panel_status',
          'observe': {'scope': 'panel', 'depth': 'atoms'},
          'entry': 'q',
          'steps': {
            'q': {
              'skill': 'query_panel',
              'on_pass': null,
              'branch': {
                ...judgeCheck('Do the indicators show a fault condition?',
                    ['panel.indicators[*].color'],
                    depth: 'atoms'),
                'on_true': null,
                'on_false': null,
              },
            },
          },
          'completion': [
            observeCheck('panel.indicators.all(has(state))', depth: 'atoms')
          ],
        },
      ],
    };

/// The lab-panel domain: references over the panel's fields, and rules.
Map<String, dynamic> labPanelDomain() => {
      'pack': CelmDomainPack.schema,
      'id': 'lab-panel',
      'references': [
        {
          'id': 'panel_supply_nominal',
          'field': 'panel.indicators[*].voltage',
          'expected': {'value': 3.30, 'unit': 'V'},
          'tolerance': {'abs': 0.15},
        },
      ],
      'reasoner': {
        'kind': 'rules',
        'rules': [
          {
            'question': 'fault',
            'when': "panel.indicators[2].color == 'red'",
            'verdict': true,
            'confidence': 0.9,
            'rationale': 'indicator 2 is red'
          },
          {
            'question': 'fault',
            'when': "panel.indicators[2].color == 'green'",
            'verdict': false,
            'confidence': 0.9,
            'rationale': 'indicator 2 is green'
          },
          {
            'question': 'usable',
            'when': 'window.frontmost.usable == true',
            'verdict': true,
            'confidence': 0.95
          },
          {
            'question': 'usable',
            'when': 'window.frontmost.usable == false',
            'verdict': false,
            'confidence': 0.95
          },
          {
            'question': 'usable',
            'when': "app.name == 'Editor'",
            'verdict': true,
            'confidence': 0.95
          },
        ],
      },
    };

/// A second domain — an oven, with its own references and rules, and no
/// skill anywhere.
Map<String, dynamic> ovenDomain() => {
      'pack': CelmDomainPack.schema,
      'id': 'oven',
      'references': [
        {
          'id': 'oven_temp_nominal',
          'field': 'panel.indicators[*].voltage',
          'expected': {'value': 5.0, 'unit': 'V'}
        },
      ],
      'reasoner': {
        'kind': 'rules',
        'rules': [
          {
            'question': 'fault',
            'when': "panel.indicators[2].color == 'red'",
            'verdict': true,
            'confidence': 0.92
          },
          {
            'question': 'fault',
            'when': "panel.indicators[2].color != 'red'",
            'verdict': false,
            'confidence': 0.92
          },
          {
            'question': 'usable',
            'when': 'has(app)',
            'verdict': true,
            'confidence': 0.9
          },
        ],
      },
    };

Map<String, dynamic> manifestJson({
  String surface = 'desktop-hid',
  String domain = 'lab-panel',
  String regime = 'discrete-verify-retry',
  Map<String, dynamic>? reasoner,
  Map<String, dynamic>? policy,
  List<Map<String, dynamic>>? outputs,
  List<Map<String, dynamic>>? inputs,
}) =>
    {
      'manifest': CelmManifest.schema,
      'instance': 'test',
      'inputs': inputs ??
          [
            {
              'channel': 'vision',
              'port': 'mcp:vision.read',
              'schema': 'descriptor@0.3',
              'quality_floor': 0.7
            },
          ],
      'outputs': outputs ??
          [
            {
              'actuator': 'hid',
              'port': 'mcp:hid',
              'vocab': ['click', 'type', 'key', 'scroll'],
              'writes': 'allow_list',
              'allowed': ['click', 'type', 'key'],
            },
            {
              'actuator': 'scpi',
              'port': 'mcp:scpi',
              'vocab': ['query'],
            },
          ],
      'surface_pack': surface,
      'domain_pack': domain,
      'reasoner': reasoner ?? {'kind': 'rules'},
      'policy': policy ??
          {
            'theta_pass': 0.85,
            'theta_escalate': 0.6,
            'budget': {'attempts': 3, 'max_escalations': 3, 'wall_ms': 60000},
          },
      'regime': regime,
    };

RecordingActuator hid({Object? failWith, Duration? delay}) => RecordingActuator(
      vocabulary: {'click', 'type', 'key', 'scroll'},
      kinds: const {
        'click': CelmActionKind.discrete,
        'type': CelmActionKind.discrete,
        'key': CelmActionKind.discrete,
        'scroll': CelmActionKind.discrete,
      },
      failWith: failWith,
      delay: delay,
    );

RecordingActuator scpi() => RecordingActuator(
      vocabulary: {'query'},
      kinds: const {'query': CelmActionKind.discrete},
    );

/// One line to a running port.
CelmPortAdapter build({
  Map<String, dynamic>? manifest,
  CelmPerceptionPort? perception,
  Map<String, CelmActuatorPort>? actuators,
  CelmInterlockPort? interlock,
  CelmReasoner? reasoner,
  CelmStore? store,
  DateTime Function()? now,
  Map<String, dynamic>? surface,
  Map<String, dynamic>? domain,
  Map<String, dynamic>? secondSurface,
  Map<String, dynamic>? secondDomain,
  bool noInterlock = false,
}) =>
    CelmPortAdapter.fromManifest(
      manifest ?? manifestJson(),
      surfacePacks: {
        'desktop-hid': CelmSurfacePack.fromJson(surface ?? desktopSurface()),
        'scpi-bus': CelmSurfacePack.fromJson(secondSurface ?? scpiSurface()),
      },
      domainPacks: {
        'lab-panel': CelmDomainPack.fromJson(domain ?? labPanelDomain()),
        'oven': CelmDomainPack.fromJson(secondDomain ?? ovenDomain()),
      },
      perception:
          perception ?? ScriptedPerception((r, i) => obs(desktopOpen())),
      actuators: actuators ?? {'hid': hid(), 'scpi': scpi()},
      interlock: noInterlock ? null : (interlock ?? ScriptedInterlock(false)),
      reasoner: reasoner,
      store: store,
      now: now,
    );

Future<CelmOutcome> run(CelmPortAdapter port, String goal,
    {Map<String, dynamic> params = const {},
    CelmConstraints? constraints,
    AnalysisActor? actor}) async {
  final h = await port.execute(CelmGoalRef(id: goal, params: params),
      constraints: constraints, actor: actor);
  return h.outcome;
}
