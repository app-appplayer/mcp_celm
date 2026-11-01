/// The downward side of MCP (`infra-ports`).
///
/// Nothing above this file knows a tool exists. The loop asks a
/// perception port to look and an actuator port to act; here those
/// become tool calls. A new sensor or actuator is a new tool the
/// manifest names, not a change here.
library;

import 'package:mcp_bundle/ports.dart';

/// Looks, and says what it examined.
abstract class CelmPerceptionPort {
  /// Look at [request]. The answer states what it examined; an adapter
  /// that cannot say must say nothing (empty coverage).
  Future<CelmObservation> observe(CelmObserveRequest request);

  /// Depths this port can honour (`manifest.unsupported_depth`).
  Set<CelmDepth> get depths;
}

/// One action, resolved: which actuator, which verb, which arguments.
class CelmAction {
  const CelmAction({
    required this.actuator,
    required this.verb,
    this.args = const {},
  });
  final String actuator;
  final String verb;
  final Map<String, dynamic> args;

  String get port => '$actuator.$verb';
}

/// What a verb does to the world, declared by the actuator binding —
/// what the regime check (D7) reads.
enum CelmActionKind { discrete, setpoint, effector }

/// Acts.
abstract class CelmActuatorPort {
  /// Perform one action. Throws on refusal or error.
  Future<void> act(CelmAction action);

  /// Verbs this port accepts (`manifest.unknown_verb`).
  Set<String> get vocabulary;

  /// What each verb does. A verb not listed is an effector write — the
  /// conservative reading, rejected under `supervisory`.
  Map<String, CelmActionKind> get kinds;
}

/// Answers whether the world permits an irreversible action right now.
/// Asked after the allow-list, before acting; never answered from
/// confidence.
abstract class CelmInterlockPort {
  Future<bool> satisfied(CelmAction action, CelmObservation state);
}

/// One gate question with everything the party answering may need to show
/// a person what is being approved, and until when the answer counts.
class CelmGateRequest {
  const CelmGateRequest({
    required this.action,
    required this.state,
    required this.runId,
    required this.goal,
    required this.step,
    required this.skill,
    required this.params,
    required this.timeout,
    required this.deadline,
  });
  final CelmAction action;
  final CelmObservation state;
  final String runId;

  /// Goal id.
  final String goal;

  /// Step id.
  final String step;

  /// Skill name.
  final String skill;

  /// The step's resolved params.
  final Map<String, dynamic> params;

  /// How long the runtime will wait (`policy.gate_timeout_ms`).
  final Duration timeout;

  /// When the runtime stops waiting: asked-at plus [timeout].
  final DateTime deadline;
}

/// An interlock that is told why it is being asked. The loop calls [check]
/// on one of these and `satisfied` on any other; the time limit applies to
/// both.
abstract class CelmContextualInterlock extends CelmInterlockPort {
  Future<bool> check(CelmGateRequest request);
}

/// The safe default: an interlock that never opens. A manifest with an
/// irreversible skill and no real interlock escalates every such step,
/// which is the right thing for it to do.
class RefusingInterlock implements CelmInterlockPort {
  const RefusingInterlock();
  @override
  Future<bool> satisfied(CelmAction action, CelmObservation state) async =>
      false;
}

/// The host's MCP client, as this package sees it: one call.
abstract class McpToolCaller {
  Future<Map<String, dynamic>> call(
    String server,
    String tool,
    Map<String, dynamic> args,
  );
}

/// A perception tool as a port. The tool's answer is the JSON form of
/// [CelmObservation]; coverage is taken from it verbatim and never
/// inferred from content.
class McpPerceptionAdapter implements CelmPerceptionPort {
  const McpPerceptionAdapter({
    required this.caller,
    required this.server,
    required this.tool,
    this.depths = const {
      CelmDepth.coarse,
      CelmDepth.structure,
      CelmDepth.atoms
    },
  });
  final McpToolCaller caller;
  final String server;
  final String tool;
  @override
  final Set<CelmDepth> depths;

  @override
  Future<CelmObservation> observe(CelmObserveRequest request) async {
    final raw = await caller.call(server, tool, request.toJson());
    return CelmObservation(
      descriptor: (raw['descriptor'] as Map<String, dynamic>?) ?? const {},
      coverage: [
        for (final c in (raw['coverage'] as List<dynamic>?) ?? const [])
          CelmCoverage.fromJson(c as Map<String, dynamic>),
      ],
      at: raw['at'] is String
          ? DateTime.parse(raw['at'] as String)
          : DateTime.now(),
    );
  }
}

/// An actuator server as a port: each verb is a tool on [server].
class McpActuatorAdapter implements CelmActuatorPort {
  const McpActuatorAdapter({
    required this.caller,
    required this.server,
    required this.vocabulary,
    this.kinds = const {},
  });
  final McpToolCaller caller;
  final String server;
  @override
  final Set<String> vocabulary;
  @override
  final Map<String, CelmActionKind> kinds;

  @override
  Future<void> act(CelmAction action) async {
    if (!vocabulary.contains(action.verb)) {
      throw AnalysisError(
        code: 'celm.actuator_failed',
        message: 'Actuator "$server" has no verb "${action.verb}"',
        details: {'actuator': action.actuator, 'verb': action.verb},
      );
    }
    await caller.call(server, action.verb, action.args);
  }
}

/// An interlock tool as a port: the tool answers `{ "satisfied": bool }`.
/// Anything else is read as not satisfied.
class McpInterlockAdapter implements CelmContextualInterlock {
  const McpInterlockAdapter({
    required this.caller,
    required this.server,
    required this.tool,
  });
  final McpToolCaller caller;
  final String server;
  final String tool;

  @override
  Future<bool> satisfied(CelmAction action, CelmObservation state) async {
    final r = await caller.call(server, tool, {
      'action': {'port': action.port, 'args': action.args},
      'at': state.at.toIso8601String(),
    });
    return r['satisfied'] == true;
  }

  @override
  Future<bool> check(CelmGateRequest request) async {
    final r = await caller.call(server, tool, {
      'action': {'port': request.action.port, 'args': request.action.args},
      'at': request.state.at.toIso8601String(),
      'context': {
        'runId': request.runId,
        'goal': request.goal,
        'step': request.step,
        'skill': request.skill,
        'params': request.params,
      },
      'timeoutMs': request.timeout.inMilliseconds,
      'deadline': request.deadline.toUtc().toIso8601String(),
    });
    return r['satisfied'] == true;
  }
}
