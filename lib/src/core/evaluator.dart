/// The evaluator — one question about one check: did it hold? The answer
/// is one of three things, and which three, and what each may carry, is
/// the whole design (D1, `core-evaluator`).
library;

import 'package:mcp_bundle/ports.dart';

import '../feat/pack.dart';
import '../feat/reasoner.dart';
import 'path.dart';

/// A fact. Deterministic, and carries no confidence because it has none.
class Observed extends CelmCheckResult {
  const Observed(this.value, super.digest, super.values, {super.statement});
  final bool value;
}

/// A judgment. Confidence comes from the reasoner and nowhere else.
class Judged extends CelmCheckResult {
  const Judged({
    required this.verdict,
    required this.confidence,
    required this.reasoner,
    required this.remote,
    required this.rationale,
    required CelmDigest digest,
    required Map<String, Object?> values,
    String statement = '',
  }) : super(digest, values, statement: statement);
  final bool verdict;
  final double confidence;
  final String reasoner;
  final bool remote;
  final String rationale;
}

/// The question could not be answered from what perception supplied.
class Unobservable extends CelmCheckResult {
  const Unobservable({
    required this.notCovered,
    required this.belowFloor,
    required CelmDigest digest,
    required Map<String, Object?> values,
    String statement = '',
  }) : super(digest, values, statement: statement);
  final List<String> notCovered;
  final List<CelmFieldRef> belowFloor;
}

sealed class CelmCheckResult {
  const CelmCheckResult(this.digest, this.values, {this.statement = ''});

  /// The check's expression or question, for the evidence record.
  final String statement;

  /// What the check read — the digest an escalation carries, and the
  /// evidence an observation records.
  final CelmDigest digest;

  /// The resolved values behind [digest], for the fingerprint.
  final Map<String, Object?> values;
}

/// How the loop reads a result (SDD §3.1.2). Every result is exactly one
/// band, and every place the loop reads a result has a row for every
/// band.
enum CelmBand { pass, fail, undecided, unobservable }

class CelmEvaluator {
  CelmEvaluator({
    required this.reasoner,
    required this.thetaPass,
    required this.thetaEscalate,
  });
  final CelmReasoner reasoner;
  final double thetaPass;
  final double thetaEscalate;

  /// Calls made to the reasoner — the count the purpose is measured by.
  int reasonerCalls = 0;

  CelmBand band(CelmCheckResult r) => switch (r) {
        Observed(:final value) => value ? CelmBand.pass : CelmBand.fail,
        Judged(:final verdict, :final confidence) => confidence >= thetaPass
            ? (verdict ? CelmBand.pass : CelmBand.fail)
            : confidence >= thetaEscalate
                ? CelmBand.fail
                : CelmBand.undecided,
        Unobservable() => CelmBand.unobservable,
      };

  /// Evaluates [checks] in order, short-circuiting on the first that is
  /// not a pass. Returns the results evaluated, the last of which is the
  /// one that decides.
  Future<List<CelmCheckResult>> evaluateAll(
    List<CelmCheck> checks,
    CelmObservation state,
    Map<String, dynamic> params,
  ) async {
    final out = <CelmCheckResult>[];
    for (final c in checks) {
      final r = await evaluate(c, state, params);
      out.add(r);
      if (band(r) != CelmBand.pass) break;
    }
    return out;
  }

  Future<CelmCheckResult> evaluate(
    CelmCheck check,
    CelmObservation state,
    Map<String, dynamic> params,
  ) async {
    final coverage = CelmCoverageMatcher(state.coverage);
    switch (check.kind) {
      case CelmCheckKind.observe:
        final r = check.expr!.evaluate(state.descriptor, params);
        final reads = <CelmPath, CelmFieldValue>{};
        for (final read in r.reads) {
          reads.putIfAbsent(read.path, () => read.value);
        }
        final gate = _gate(reads, check, state, coverage);
        if (gate != null) return gate;
        return Observed(
            r.holds, _digest(reads, check, coverage), _values(reads),
            statement: check.statement);
      case CelmCheckKind.judge:
        final reads = _concrete(state.descriptor, check.reads);
        final gate = _gate(reads, check, state, coverage);
        if (gate != null) return gate;
        final digest = _digest(reads, check, coverage);
        final values = _values(reads);
        reasonerCalls++;
        final j = await reasoner.judge(CelmJudgmentRequest(
          digest: digest,
          values: values,
          question: check.ask!,
        ));
        return Judged(
          verdict: j.verdict,
          confidence: j.confidence,
          reasoner: reasoner.id,
          remote: reasoner.remote,
          rationale: j.rationale,
          digest: digest,
          values: values,
          statement: check.statement,
        );
    }
  }

  /// Resolves [paths], expanding a wildcard into the concrete fields it
  /// stands for — so the digest names what was actually read, and a rule
  /// can address one element. A wildcard whose list is absent stays as
  /// the wildcard path, absent, for the coverage test.
  Map<CelmPath, CelmFieldValue> _concrete(
    Map<String, dynamic> descriptor,
    List<CelmPath> paths,
  ) {
    final out = <CelmPath, CelmFieldValue>{};
    for (final p in paths) {
      final expanded = CelmFieldValue.expand(descriptor, p);
      final whole = CelmFieldValue.resolve(descriptor, p);
      if (!p.hasWildcard || expanded.isEmpty || !whole.present) {
        out[p] = whole;
        continue;
      }
      for (final c in expanded) {
        out[c] = CelmFieldValue.resolve(descriptor, c);
      }
    }
    return out;
  }

  /// The resolution order of `core-evaluator` §3.1, applied to every
  /// field the check read. Returns the `Unobservable` if any field is,
  /// else null.
  Unobservable? _gate(
    Map<CelmPath, CelmFieldValue> reads,
    CelmCheck check,
    CelmObservation state,
    CelmCoverageMatcher coverage,
  ) {
    final notCovered = <String>[];
    final belowFloor = <CelmFieldRef>[];
    for (final e in reads.entries) {
      final v = e.value;
      if (v.present) {
        if (check.requiresQuality > 0 &&
            (v.quality == null || v.quality! < check.requiresQuality)) {
          belowFloor.add(
              CelmFieldRef(field: e.key.toString(), quality: v.quality ?? 0));
        }
      } else if (!coverage.covers(
          state.descriptor, e.key, check.requiresDepth)) {
        notCovered.add(e.key.toString());
      }
    }
    if (notCovered.isEmpty && belowFloor.isEmpty) return null;
    return Unobservable(
      notCovered: notCovered,
      belowFloor: belowFloor,
      digest: _digest(reads, check, coverage),
      values: _values(reads),
      statement: check.statement,
    );
  }

  CelmDigest _digest(
    Map<CelmPath, CelmFieldValue> reads,
    CelmCheck check,
    CelmCoverageMatcher coverage,
  ) {
    final cov = <String, CelmCoverage>{};
    for (final p in reads.keys) {
      for (final c in coverage.bearingOn(p)) {
        cov['${c.scope}@${c.depth.name}'] = c;
      }
    }
    return CelmDigest(
      relevant: [
        for (final e in reads.entries)
          CelmFieldRef(field: e.key.toString(), quality: e.value.quality ?? 0),
      ],
      coverage: cov.values.toList(),
      knowledge: check.attached,
    );
  }

  Map<String, Object?> _values(Map<CelmPath, CelmFieldValue> reads) => {
        for (final e in reads.entries)
          if (e.value.present) e.key.toString(): e.value.value,
      };
}
