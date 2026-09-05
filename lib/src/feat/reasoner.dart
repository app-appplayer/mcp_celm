/// The reasoner — the only source of confidence in the system, and the
/// middle tier of the ladder the package's purpose rests on
/// (`feat-reasoner`).
///
/// The slot is local by definition. `llm` exists as a bootstrap and is
/// labelled as one: every conclusion it makes records `reasonerRemote`.
library;

import 'package:mcp_bundle/ports.dart';

import '../core/expr.dart';
import '../core/path.dart';

/// What a reasoner is asked. The state is the digest — the fields the
/// check reads, quality-gated — and the same digest an escalation would
/// carry. Not the descriptor.
class CelmJudgmentRequest {
  const CelmJudgmentRequest({
    required this.digest,
    required this.values,
    required this.question,
    this.premises = const [],
  });
  final CelmDigest digest;

  /// The resolved values of the digest's fields, for a backend that
  /// evaluates over them.
  final Map<String, Object?> values;
  final String question;
  final List<String> premises;
}

class CelmJudgment {
  const CelmJudgment({
    required this.verdict,
    required this.confidence,
    this.rationale = '',
  });
  final bool verdict;
  final double confidence;
  final String rationale;
}

abstract class CelmReasoner {
  String get id;

  /// True when judgments are made off-box. Recorded on every conclusion.
  bool get remote;

  Future<CelmJudgment> judge(CelmJudgmentRequest request);
}

/// A local backend that answers from the pack's rules: the first rule
/// whose `when` holds over the digest's values gives the verdict and the
/// confidence. No rule matching is an undecided answer (confidence 0),
/// which escalates — a rule set that does not cover a state does not
/// guess about it.
///
/// ```json
/// { "question": "fault", "when": "panel.indicators[2].color == 'red'",
///   "verdict": true, "confidence": 0.9, "rationale": "indicator 2 is red" }
/// ```
///
/// `question`, when present, must occur in the check's `ask` for the rule
/// to apply — one rule set serves every question the pack asks.
class RulesReasoner implements CelmReasoner {
  RulesReasoner({required this.id, required List<Map<String, dynamic>> rules})
      : _rules = [
          for (final r in rules)
            _Rule(
              CelmExpr.parse(r['when'] as String),
              r['verdict'] as bool? ?? false,
              (r['confidence'] as num?)?.toDouble() ?? 0,
              r['rationale'] as String? ?? '',
              r['question'] as String?,
            ),
        ];
  @override
  final String id;
  final List<_Rule> _rules;

  @override
  bool get remote => false;

  @override
  Future<CelmJudgment> judge(CelmJudgmentRequest request) async {
    final descriptor = _nest(request.values);
    for (final r in _rules) {
      if (r.question != null && !request.question.contains(r.question!)) {
        continue;
      }
      if (r.when.evaluate(descriptor, const {}).holds) {
        return CelmJudgment(
          verdict: r.verdict,
          confidence: r.confidence,
          rationale: r.rationale,
        );
      }
    }
    return const CelmJudgment(
      verdict: false,
      confidence: 0,
      rationale: 'no rule covers this state',
    );
  }

  /// Rebuilds a descriptor tree from the digest's paths so rule
  /// expressions address fields the way checks do. A wildcard path's
  /// value is the list of elements, placed where the list lives.
  static Map<String, dynamic> _nest(Map<String, Object?> flat) {
    final root = <String, dynamic>{};
    for (final e in flat.entries) {
      var segs = CelmPath.parse(e.key).segments;
      if (segs.isNotEmpty && segs.last is WildcardSegment) {
        segs = segs.sublist(0, segs.length - 1);
      }
      if (segs.isEmpty) continue;
      Object container = root;
      for (var i = 0; i < segs.length; i++) {
        final seg = segs[i];
        final last = i == segs.length - 1;
        final nextIsIndex = !last && segs[i + 1] is IndexSegment;
        Object fresh() => nextIsIndex ? <Object?>[] : <String, dynamic>{};
        switch (seg) {
          case KeySegment(:final key):
            final m = container as Map<String, dynamic>;
            if (last) {
              m[key] = e.value;
            } else {
              container = (m[key] ??= fresh()) as Object;
            }
          case IndexSegment(:final index):
            final l = container as List<Object?>;
            while (l.length <= index) {
              l.add(null);
            }
            if (last) {
              l[index] = e.value;
            } else {
              container = l[index] ??= fresh();
            }
          case WildcardSegment():
            break;
        }
      }
    }
    return root;
  }
}

/// The bootstrap: a planner-class model in the reasoner slot, reached
/// through a host-supplied call. Marked remote on every conclusion; the
/// load-reduction property is not claimed while this is in use.
class LlmReasoner implements CelmReasoner {
  const LlmReasoner({
    required this.id,
    required Future<CelmJudgment> Function(CelmJudgmentRequest) ask,
  }) : _ask = ask;
  @override
  final String id;
  final Future<CelmJudgment> Function(CelmJudgmentRequest request) _ask;

  @override
  bool get remote => true;

  @override
  Future<CelmJudgment> judge(CelmJudgmentRequest request) => _ask(request);
}

class _Rule {
  const _Rule(
      this.when, this.verdict, this.confidence, this.rationale, this.question);
  final CelmExpr when;
  final bool verdict;
  final double confidence;
  final String rationale;
  final String? question;
}
