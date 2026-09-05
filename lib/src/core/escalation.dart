/// Escalation — suspend a run so a planner can help, and resume it
/// without pretending nothing happened in between (`core-escalation`).
library;

import 'dart:convert';

import 'package:mcp_bundle/ports.dart';

import 'evidence.dart';

/// Refuses a second escalation from one step on an unchanged state.
///
/// The fingerprint is over the values the blocked check reads — not the
/// whole descriptor: a clock ticking in a corner must not read as
/// progress.
class CelmNoProgressGuard {
  CelmNoProgressGuard([Map<String, String>? initial]) : _lastAt = {...?initial};
  final Map<String, String> _lastAt;

  Map<String, String> get fingerprints => Map.unmodifiable(_lastAt);

  static String fingerprint(Map<String, Object?> values) {
    final keys = values.keys.toList()..sort();
    return jsonEncode([
      for (final k in keys) [k, values[k]]
    ]);
  }

  /// Records the state at this escalation. Returns false when this step
  /// already escalated on exactly this state.
  bool admit(String step, Map<String, Object?> values) {
    final fp = fingerprint(values);
    if (_lastAt[step] == fp) return false;
    _lastAt[step] = fp;
    return true;
  }

  /// True when [step]'s re-perceived state matches its last escalation.
  bool unchanged(String step, Map<String, Object?> values) =>
      _lastAt[step] == fingerprint(values);
}

/// Writes the example record every resolution produces (FR-LEARN).
class CelmExampleWriter {
  CelmExampleWriter(this.store);
  final CelmStore store;
  int _seq = 0;

  Future<CelmExample> write({
    required String runId,
    required String step,
    required CelmDigest state,
    required String question,
    required CelmResumption resolution,
    required String resolver,
    required DateTime at,
  }) async {
    final e = CelmExample(
      id: '$runId-x${++_seq}',
      runId: runId,
      step: step,
      state: state,
      question: question,
      resolution: resolution,
      resolver: resolver,
      at: at,
    );
    await store.examples.save(e.id, e);
    return e;
  }
}
