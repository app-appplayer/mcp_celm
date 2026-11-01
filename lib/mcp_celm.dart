/// CeLM — a guarded local execution loop over structured state.
///
/// It exists to take load off the LLM, and to do it locally. Perception
/// hands it structured state, a surface pack hands it skills and goals, a
/// domain pack hands it knowledge, and it decides and verifies locally —
/// so the planner is reached only where a planner is the answer.
///
/// The contract (`CelmPort` and its types) lives in `mcp_bundle`; this
/// package implements it.
library;

export 'package:mcp_bundle/ports.dart'
    show
        AnalysisActor,
        AnalysisError,
        Abandon,
        CelmAttempt,
        CelmBudgetUse,
        CelmCancelled,
        CelmCompleted,
        CelmConclusion,
        CelmConstraints,
        CelmCoverage,
        CelmDepth,
        CelmDigest,
        CelmEscalated,
        CelmEscalationReason,
        CelmEvidence,
        CelmFieldRef,
        CelmGoalRef,
        CelmObservation,
        CelmObserveRequest,
        CelmOutcome,
        CelmPort,
        CelmProgress,
        CelmReferenceRef,
        CelmRefusalReason,
        CelmRefused,
        CelmResumption,
        CelmRunHandle,
        JudgedConclusion,
        ObservedConclusion,
        ResumeAt,
        ResumeWith,
        StubCelmPort;

// core
export 'src/core/budget.dart';
export 'src/core/escalation.dart';
export 'src/core/evaluator.dart';
export 'src/core/evidence.dart';
export 'src/core/expr.dart';
export 'src/core/loop.dart';
export 'src/core/manifest.dart';
export 'src/core/path.dart';
export 'src/core/port_adapter.dart';

// feat
export 'src/feat/pack.dart';
export 'src/feat/reasoner.dart';

// infra
export 'src/infra/observation_check.dart';
export 'src/infra/ports.dart';

// mcp
export 'src/mcp/tool_handler.dart';
