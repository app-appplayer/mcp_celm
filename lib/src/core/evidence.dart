/// Evidence — every conclusion with how it was reached, the run state a
/// resumption reloads, and the example record the next reasoner learns
/// from (`core-evidence`, `core-escalation` §6).
library;

import 'package:mcp_bundle/ports.dart';

/// What a resumption reloads.
class CelmRunState {
  const CelmRunState({
    required this.runId,
    required this.goal,
    required this.currentStep,
    required this.budget,
    required this.startedAt,
    this.history = const [],
    this.fingerprints = const {},
    this.outcome,
    this.escalated = false,
  });

  factory CelmRunState.fromJson(Map<String, dynamic> json) => CelmRunState(
        runId: json['runId'] as String,
        goal: CelmGoalRef.fromJson(json['goal'] as Map<String, dynamic>),
        currentStep: json['currentStep'] as String? ?? '',
        budget: CelmBudgetUse.fromJson(json['budget'] as Map<String, dynamic>),
        startedAt: DateTime.parse(json['startedAt'] as String),
        history: [
          for (final h in (json['history'] as List<dynamic>?) ?? const [])
            CelmAttempt.fromJson(h as Map<String, dynamic>),
        ],
        fingerprints:
            ((json['fingerprints'] as Map<String, dynamic>?) ?? const {})
                .map((k, v) => MapEntry(k, '$v')),
        outcome: json['outcome'] == null
            ? null
            : CelmOutcome.fromJson(json['outcome'] as Map<String, dynamic>),
        escalated: json['escalated'] as bool? ?? false,
      );
  final String runId;
  final CelmGoalRef goal;
  final String currentStep;
  final CelmBudgetUse budget;
  final List<CelmAttempt> history;

  /// step -> state fingerprint at the last escalation from it.
  final Map<String, String> fingerprints;
  final CelmOutcome? outcome;
  final bool escalated;
  final DateTime startedAt;

  Map<String, dynamic> toJson() => {
        'runId': runId,
        'goal': goal.toJson(),
        'currentStep': currentStep,
        'budget': budget.toJson(),
        'startedAt': startedAt.toIso8601String(),
        if (history.isNotEmpty)
          'history': history.map((h) => h.toJson()).toList(),
        if (fingerprints.isNotEmpty) 'fingerprints': fingerprints,
        if (outcome != null) 'outcome': outcome!.toJson(),
        if (escalated) 'escalated': true,
      };
}

/// A resolved escalation, as a labelled example (SDD §5.6).
class CelmExample {
  const CelmExample({
    required this.id,
    required this.runId,
    required this.step,
    required this.state,
    required this.question,
    required this.resolution,
    required this.resolver,
    required this.at,
  });

  factory CelmExample.fromJson(Map<String, dynamic> json) => CelmExample(
        id: json['id'] as String,
        runId: json['runId'] as String,
        step: json['step'] as String? ?? '',
        state: CelmDigest.fromJson(
            (json['state'] as Map<String, dynamic>?) ?? const {}),
        question: json['question'] as String? ?? '',
        resolution:
            CelmResumption.fromJson(json['resolution'] as Map<String, dynamic>),
        resolver: json['resolver'] as String? ?? '',
        at: DateTime.parse(json['at'] as String),
      );
  final String id;
  final String runId;
  final String step;
  final CelmDigest state;
  final String question;
  final CelmResumption resolution;
  final String resolver;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'example': 'celm/example@0.1',
        'id': id,
        'runId': runId,
        'step': step,
        'state': state.toJson(),
        'question': question,
        'resolution': resolution.toJson(),
        'resolver': resolver,
        'at': at.toIso8601String(),
      };
}

/// One object with three ports, so a host that wires persistence wires
/// it once and a run's three records cannot land in three stores.
abstract class CelmStore {
  StoragePort<CelmConclusion> get conclusions;
  StoragePort<CelmRunState> get runs;
  StoragePort<CelmExample> get examples;
}

class InMemoryCelmStore implements CelmStore {
  @override
  final StoragePort<CelmConclusion> conclusions =
      InMemoryStoragePort<CelmConclusion>();
  @override
  final StoragePort<CelmRunState> runs = InMemoryStoragePort<CelmRunState>();
  @override
  final StoragePort<CelmExample> examples = InMemoryStoragePort<CelmExample>();
}

/// A store over the host's key-value port. Records are written as JSON
/// and read back through the contract's decoders, so provenance is
/// checked on every read.
class KvCelmStore implements CelmStore {
  KvCelmStore(KvStoragePort kv)
      : conclusions = _KvTyped(
            kv, 'celm/conclusion/', CelmConclusion.fromJson, (c) => c.toJson()),
        runs =
            _KvTyped(kv, 'celm/run/', CelmRunState.fromJson, (r) => r.toJson()),
        examples = _KvTyped(
            kv, 'celm/example/', CelmExample.fromJson, (e) => e.toJson());

  @override
  final StoragePort<CelmConclusion> conclusions;
  @override
  final StoragePort<CelmRunState> runs;
  @override
  final StoragePort<CelmExample> examples;
}

class _KvTyped<T> implements StoragePort<T> {
  const _KvTyped(this.kv, this.prefix, this.decode, this.encode);
  final KvStoragePort kv;
  final String prefix;
  final T Function(Map<String, dynamic>) decode;
  final Map<String, dynamic> Function(T) encode;

  @override
  Future<void> save(String id, T item) => kv.set('$prefix$id', encode(item));

  @override
  Future<T?> get(String id) async {
    final raw = await kv.get('$prefix$id');
    if (raw == null) return null;
    return decode(Map<String, dynamic>.from(raw as Map));
  }

  @override
  Future<void> delete(String id) => kv.remove('$prefix$id');

  @override
  Future<List<T>> getAll() async {
    final keys = await kv.keys(prefix: prefix);
    final out = <T>[];
    for (final k in keys) {
      final raw = await kv.get(k);
      if (raw != null) out.add(decode(Map<String, dynamic>.from(raw as Map)));
    }
    return out;
  }

  @override
  Future<List<T>> query(Map<String, dynamic> criteria) async {
    final all = await getAll();
    final runId = criteria['runId'];
    if (runId == null) return all;
    return [
      for (final item in all)
        if (encode(item)['runId'] == runId) item,
    ];
  }

  @override
  Future<bool> exists(String id) => kv.exists('$prefix$id');
}

/// The ledger: conclusions appended before the loop advances
/// (NFR-OBS-001), the chain served by id, and the standalone filter.
class CelmLedger {
  CelmLedger(this.store);
  final CelmStore store;
  int _seq = 0;

  String nextId(String runId) => '$runId-c${++_seq}';

  Future<void> append(CelmConclusion c) => store.conclusions.save(c.id, c);

  Future<List<CelmConclusion>> byRun(String runId) async {
    final all = await store.conclusions.getAll();
    return [
      for (final c in all)
        if (c.runId == runId) c,
    ]..sort((a, b) => a.at.compareTo(b.at));
  }

  /// Conclusions that may stand alone as evidence.
  Future<List<ObservedConclusion>> standalone(String runId) async =>
      (await byRun(runId)).whereType<ObservedConclusion>().toList();

  /// Walks premises transitively. A chain that reaches no observation is
  /// a judgment resting on nothing, and is visible as such.
  Future<CelmEvidence> explain(String conclusionId) async {
    final root = await store.conclusions.get(conclusionId);
    if (root == null) {
      throw AnalysisError(
        code: 'celm.conclusion_not_found',
        message: 'Conclusion "$conclusionId" not found',
        details: {'conclusionId': conclusionId},
      );
    }
    final chain = <CelmConclusion>[];
    final seen = <String>{root.id};
    final queue = <String>[
      if (root is JudgedConclusion) ...root.premises,
    ];
    while (queue.isNotEmpty) {
      final id = queue.removeAt(0);
      if (!seen.add(id)) continue;
      final c = await store.conclusions.get(id);
      if (c == null) continue;
      chain.add(c);
      if (c is JudgedConclusion) queue.addAll(c.premises);
    }
    return CelmEvidence(conclusion: root, chain: chain);
  }
}
