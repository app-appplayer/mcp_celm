// A barrel-only consumer: builds a CeLM over in-memory ports, runs a goal
// end to end and reads the evidence. This is what a host does; nothing
// here reaches into `src/`. It also compiles to JS and wasm, which is the
// platform check.
import 'package:mcp_celm/mcp_celm.dart';

Map<String, dynamic> cell(Object? v, [double q = 0.95]) =>
    {'value': v, 'quality': q};

/// A perception port that answers honestly: the requested scope, at the
/// requested depth, and only what that depth can see.
class DemoPerception implements CelmPerceptionPort {
  DemoPerception(this.actuator);
  final DemoActuator actuator;

  @override
  Set<CelmDepth> get depths => CelmDepth.values.toSet();

  @override
  Future<CelmObservation> observe(CelmObserveRequest request) async {
    final opened = actuator.log.length >= 3;
    return CelmObservation(
      descriptor: {
        'app': {'focused': cell(true), 'name': cell('Editor')},
        'window': {
          'frontmost': {
            'title': cell(opened ? 'notes.txt' : 'Untitled'),
            'usable': cell(opened),
          },
        },
      },
      coverage: [
        CelmCoverage(scope: request.scope ?? 'screen', depth: request.depth),
      ],
      at: DateTime.now(),
    );
  }
}

class DemoActuator implements CelmActuatorPort {
  final List<String> log = [];

  @override
  Set<String> get vocabulary => {'click', 'type', 'key'};

  @override
  Map<String, CelmActionKind> get kinds => const {
        'click': CelmActionKind.discrete,
        'type': CelmActionKind.discrete,
        'key': CelmActionKind.discrete,
      };

  @override
  Future<void> act(CelmAction action) async => log.add(action.port);
}

const surfacePack = {
  'pack': 'celm/surface@0.1',
  'id': 'desktop-hid',
  'skills': [
    {
      'name': 'open_file',
      'params': {'path': 'string'},
      'preconditions': [
        {'kind': 'observe', 'expr': 'app.focused == true'},
      ],
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
        {
          'kind': 'observe',
          'expr': r'window.frontmost.title contains basename($path)',
          'requires_quality': 0.8,
        },
        {
          'kind': 'judge',
          'ask': 'Did the document open in a usable state?',
          'reads': ['window.frontmost'],
        },
      ],
      'writes': true,
    },
  ],
  'goals': [
    {
      'id': 'open_document',
      'params': {'path': 'string'},
      'observe': {'scope': 'screen', 'depth': 'structure'},
      'entry': 'open',
      'steps': {
        'open': {
          'skill': 'open_file',
          'params': {'path': r'$path'},
          'on_pass': null
        },
      },
      'completion': [
        {
          'kind': 'observe',
          'expr': r'window.frontmost.title contains basename($path)'
        },
      ],
    },
  ],
};

const domainPack = {
  'pack': 'celm/domain@0.1',
  'id': 'editor',
  'references': <Object>[],
  'reasoner': {
    'kind': 'rules',
    'rules': [
      {
        'question': 'usable',
        'when': 'window.frontmost.usable == true',
        'verdict': true,
        'confidence': 0.95,
        'rationale': 'the window reports itself usable',
      },
      {
        'question': 'usable',
        'when': 'window.frontmost.usable == false',
        'verdict': false,
        'confidence': 0.95,
      },
    ],
  },
};

const manifest = {
  'manifest': 'celm/manifest@0.1',
  'instance': 'example',
  'inputs': [
    {
      'channel': 'vision',
      'port': 'mcp:vision.read',
      'schema': 'descriptor@0.3'
    },
  ],
  'outputs': [
    {
      'actuator': 'hid',
      'port': 'mcp:hid',
      'vocab': ['click', 'type', 'key'],
      'writes': 'allow_list',
      'allowed': ['click', 'type', 'key'],
    },
  ],
  'surface_pack': 'desktop-hid',
  'domain_pack': 'editor',
  'reasoner': {'kind': 'rules'},
  'regime': 'discrete-verify-retry',
};

Future<void> main() async {
  final actuator = DemoActuator();
  final port = CelmPortAdapter.fromManifest(
    manifest,
    surfacePacks: {'desktop-hid': CelmSurfacePack.fromJson(surfacePack)},
    domainPacks: {'editor': CelmDomainPack.fromJson(domainPack)},
    perception: DemoPerception(actuator),
    actuators: {'hid': actuator},
  );

  final handle = await port.execute(
    const CelmGoalRef(id: 'open_document', params: {'path': '/tmp/notes.txt'}),
  );
  final outcome = await handle.outcome;

  final lines = <String>[
    'run ${handle.runId}: ${outcome.runtimeType}',
    'actions: ${actuator.log.join(', ')}',
    'reasoner calls: ${port.runner.counters.reasonerCalls}',
  ];
  if (outcome is CelmCompleted) {
    for (final c in outcome.conclusions) {
      final tag = c is JudgedConclusion
          ? 'judged ${c.confidence} by ${c.reasoner}'
          : 'observed';
      lines.add('  $tag: ${c.statement}');
    }
    final standalone = await port.standalone(handle.runId);
    lines.add('standalone evidence: ${standalone.length} observations');
  }
  // The example's only output. A host would log through its own logger.
  // ignore: avoid_print
  print(lines.join('\n'));
}
