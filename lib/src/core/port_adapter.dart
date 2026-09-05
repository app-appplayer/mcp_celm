/// `CelmPort` over the runtime — a facade with one job of its own,
/// authorization (`core-port-adapter`).
library;

import 'package:mcp_bundle/ports.dart';

import '../feat/pack.dart';
import '../feat/reasoner.dart';
import '../infra/ports.dart';
import 'evidence.dart';
import 'loop.dart';
import 'manifest.dart';

/// Who may do what. Null actor passes: a host that does not pass one has
/// chosen not to gate.
abstract class CelmAuthorizer {
  /// Throws `governance.unauthorized`.
  void authorize(String operation, AnalysisActor? actor, {bool writes = false});
}

/// Roles that may read, and roles that may write. `execute` of a goal
/// with a writing skill, `resume` and `cancel` need write.
class RoleAuthorizer implements CelmAuthorizer {
  const RoleAuthorizer({
    this.readRoles = const {'viewer', 'operator', 'admin'},
    this.writeRoles = const {'operator', 'admin'},
  });
  final Set<String> readRoles;
  final Set<String> writeRoles;

  @override
  void authorize(String operation, AnalysisActor? actor,
      {bool writes = false}) {
    if (actor == null) return;
    final ok = writes
        ? writeRoles.contains(actor.role)
        : readRoles.contains(actor.role);
    if (!ok) {
      throw AnalysisError(
        code: 'governance.unauthorized',
        message:
            'Actor "${actor.id}" with role "${actor.role}" lacks permission for "$operation"',
        details: {
          'actorId': actor.id,
          'role': actor.role,
          'operation': operation
        },
      );
    }
  }
}

class CelmPortAdapter implements CelmPort {
  CelmPortAdapter._(this.runner, this.perception, this.authorizer);

  /// The standard construction. Perception and actuators are required: a
  /// CeLM with no eyes and no hands has nothing to be. An interlock is
  /// required as soon as the packs contain an irreversible skill.
  factory CelmPortAdapter.fromManifest(
    Map<String, dynamic> manifestJson, {
    required Map<String, CelmSurfacePack> surfacePacks,
    required Map<String, CelmDomainPack> domainPacks,
    required CelmPerceptionPort perception,
    required Map<String, CelmActuatorPort> actuators,
    CelmInterlockPort? interlock,
    CelmReasoner? reasoner,
    CelmStore? store,
    CelmAuthorizer authorizer = const RoleAuthorizer(),
    DateTime Function()? now,
  }) {
    final manifest = CelmManifest.load(
      manifestJson,
      surfacePacks: surfacePacks,
      domainPacks: domainPacks,
      actuators: actuators,
      perceptionDepths: perception.depths,
      reasoner: reasoner,
    );
    final runner = CelmRunner(
      manifest: manifest,
      perception: perception,
      actuators: actuators,
      interlock: interlock,
      store: store ?? InMemoryCelmStore(),
      now: now,
    );
    return CelmPortAdapter._(runner, perception, authorizer);
  }
  final CelmRunner runner;
  final CelmPerceptionPort perception;
  final CelmAuthorizer authorizer;

  CelmManifest get manifest => runner.manifest;

  @override
  Future<CelmRunHandle> execute(
    CelmGoalRef goal, {
    CelmConstraints? constraints,
    AnalysisActor? actor,
  }) {
    final g = manifest.surface.goals[goal.id];
    final writes = g != null &&
        g.steps.values
            .any((s) => manifest.surface.skills[s.skill]?.writes ?? false);
    authorizer.authorize('execute', actor, writes: writes);
    return runner.execute(goal, constraints: constraints, actor: actor);
  }

  @override
  Future<CelmOutcome> cancel(String runId, {AnalysisActor? actor}) {
    authorizer.authorize('cancel', actor, writes: true);
    return runner.cancel(runId);
  }

  @override
  Future<CelmObservation> observe(
      {CelmObserveRequest? request, AnalysisActor? actor}) {
    authorizer.authorize('observe', actor);
    return perception.observe(request ?? const CelmObserveRequest());
  }

  @override
  Future<CelmProgress> progress(String runId, {AnalysisActor? actor}) {
    authorizer.authorize('progress', actor);
    return runner.progress(runId);
  }

  @override
  Future<CelmEvidence> explain(String conclusionId, {AnalysisActor? actor}) {
    authorizer.authorize('explain', actor);
    return runner.ledger.explain(conclusionId);
  }

  @override
  Future<CelmOutcome> resume(String runId, CelmResumption resumption,
      {AnalysisActor? actor}) {
    authorizer.authorize('resume', actor, writes: true);
    return runner.resume(runId, resumption, actor: actor);
  }

  @override
  Future<List<ObservedConclusion>> standalone(String runId,
      {AnalysisActor? actor}) {
    authorizer.authorize('standalone', actor);
    return runner.ledger.standalone(runId);
  }
}
