/// Retries and escalations, bounded apart (D2, `core-loop` §3).
library;

import 'package:mcp_bundle/ports.dart';

import 'manifest.dart';

class CelmBudget {
  CelmBudget(
    CelmBudgetSpec spec, {
    Duration? deadline,
    DateTime Function()? now,
    DateTime? started,
    this.attemptsSpent = 0,
    this.escalationsSpent = 0,
  })  : attempts = spec.attempts,
        maxEscalations = spec.maxEscalations,
        wall = deadline != null && deadline < spec.wall ? deadline : spec.wall,
        _now = now ?? DateTime.now,
        _started = started ?? (now ?? DateTime.now)();
  final int attempts;
  final int maxEscalations;
  final Duration wall;
  final DateTime Function() _now;
  final DateTime _started;
  int attemptsSpent;
  int escalationsSpent;

  bool spendAttempt() {
    if (attemptsSpent >= attempts) return false;
    attemptsSpent++;
    return true;
  }

  bool spendEscalation() {
    if (escalationsSpent >= maxEscalations) return false;
    escalationsSpent++;
    return true;
  }

  Duration get elapsed => _now().difference(_started);

  bool get wallExceeded => elapsed > wall;

  CelmBudgetUse get use => CelmBudgetUse(
        attemptsSpent: attemptsSpent,
        attemptsAllowed: attempts,
        escalationsSpent: escalationsSpent,
        escalationsAllowed: maxEscalations,
        elapsed: elapsed,
      );
}
