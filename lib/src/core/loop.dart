/// The guarded loop (SDD §4.0, `core-loop`).
///
/// Decide, act, re-perceive, evaluate, branch on the band. Hold the
/// budget. Suspend on escalation and resume from a named step. It owns no
/// domain content, evaluates no check itself, and calls no reasoner —
/// every judgment reaches it as an evaluation result.
library;

import 'dart:async';

import 'package:mcp_bundle/ports.dart';

import '../feat/pack.dart';
import '../infra/ports.dart';
import 'budget.dart';
import 'escalation.dart';
import 'evaluator.dart';
import 'evidence.dart';
import 'manifest.dart';

/// Counts the purpose is measured by (TEST §16).
class CelmCounters {
  CelmCounters(this._evaluator);
  int perceptionCalls = 0;
  int actuatorCalls = 0;
  int stepsAdvanced = 0;
  int get reasonerCalls => _evaluator.reasonerCalls;
  final CelmEvaluator _evaluator;
}

class CelmRunner {
  CelmRunner({
    required this.manifest,
    required this.perception,
    required this.actuators,
    required this.store,
    this.interlock,
    DateTime Function()? now,
  })  : now = now ?? DateTime.now,
        evaluator = CelmEvaluator(
          reasoner: manifest.reasoner,
          thetaPass: manifest.policy.thetaPass,
          thetaEscalate: manifest.policy.thetaEscalate,
        ),
        ledger = CelmLedger(store),
        examples = CelmExampleWriter(store) {
    if (manifest.hasIrreversibleSkill && interlock == null) {
      throw AnalysisError(
        code: 'celm.interlock_required',
        message:
            'The loaded packs contain an irreversible skill; an interlock port is required',
      );
    }
  }
  final CelmManifest manifest;
  final CelmPerceptionPort perception;
  final Map<String, CelmActuatorPort> actuators;
  final CelmInterlockPort? interlock;
  final CelmStore store;
  final DateTime Function() now;
  final CelmEvaluator evaluator;
  final CelmLedger ledger;
  final CelmExampleWriter examples;
  late final CelmCounters counters = CelmCounters(evaluator);

  final Map<String, _Run> _runs = {};
  int _seq = 0;

  // ---------------------------------------------------------------------
  // Port surface
  // ---------------------------------------------------------------------

  Future<CelmRunHandle> execute(
    CelmGoalRef ref, {
    CelmConstraints? constraints,
    AnalysisActor? actor,
  }) async {
    final runId = 'run-${++_seq}';
    final goal = manifest.surface.goals[ref.id];
    final constraintsOrDefault = constraints ?? const CelmConstraints();
    final run = _Run(
      id: runId,
      ref: ref,
      goal: goal,
      constraints: constraintsOrDefault,
      actor: actor,
      budget: CelmBudget(manifest.policy.budget,
          deadline: constraintsOrDefault.deadline, now: now),
      guard: CelmNoProgressGuard(),
      startedAt: now(),
    );
    _runs[runId] = run;

    if (goal == null) {
      final o = CelmRefused(runId,
          reason: CelmRefusalReason.goalUnknown,
          detail:
              'Surface pack "${manifest.surface.id}" defines no goal "${ref.id}"');
      await _finish(run, o);
      return CelmRunHandle(runId: runId, outcome: Future.value(o));
    }
    final missing = goal.params.keys.where((k) => !ref.params.containsKey(k));
    if (missing.isNotEmpty) {
      final o = CelmRefused(runId,
          reason: CelmRefusalReason.goalUnsatisfiable,
          detail: 'Goal "${ref.id}" requires params: ${missing.join(', ')}');
      await _finish(run, o);
      return CelmRunHandle(runId: runId, outcome: Future.value(o));
    }
    if (constraintsOrDefault.readOnly || goal.readOnly) {
      run.readOnly = true;
    }
    await _saveState(run);
    unawaited(_start(run, goal.steps[goal.entry]!, entry: true));
    return CelmRunHandle(runId: runId, outcome: run.completer.future);
  }

  Future<CelmOutcome> cancel(String runId) async {
    final run = _require(runId);
    if (run.outcome != null) return run.outcome!;
    run.cancelRequested = true;
    if (run.driving) return run.completer.future;
    // Suspended (escalated): nothing is driving, so end it here.
    final o = CelmCancelled(runId,
        stoppedAt: run.currentStep, conclusions: await ledger.byRun(runId));
    await _finish(run, o);
    return o;
  }

  Future<CelmProgress> progress(String runId) async {
    final run = _require(runId);
    return CelmProgress(
      runId: runId,
      currentStep: run.currentStep,
      budget: run.budget.use,
      history: List.unmodifiable(run.history),
      escalated: run.escalated,
      outcome: run.outcome,
    );
  }

  Future<CelmOutcome> resume(
    String runId,
    CelmResumption resumption, {
    AnalysisActor? actor,
  }) async {
    var run = _runs[runId];
    if (run == null) {
      // Reload from the store: the process that suspended it may be gone.
      final state = await store.runs.get(runId);
      if (state == null) _notFound(runId);
      run = _Run.fromState(state, manifest, now);
      _runs[runId] = run;
    }
    if (run.outcome != null) return run.outcome!;
    if (!run.escalated) {
      throw AnalysisError(
        code: 'celm.not_escalated',
        message: 'Run "$runId" is not suspended',
        details: {'runId': runId},
      );
    }
    final goal = run.goal!;
    final blocked = run.currentStep;
    final block = run.block;

    // 1. Re-perceive. The world moved while the planner was thinking.
    final step = goal.steps[blocked]!;
    final state =
        await _perceive(run, step.observe ?? goal.observe, run.params);

    // 2. Validate the named step.
    final target = switch (resumption) {
      ResumeAt(:final step) => step,
      ResumeWith(:final step) => step,
      Abandon() => null,
    };
    if (target != null && !goal.steps.containsKey(target)) {
      return CelmRefused(runId,
          reason: CelmRefusalReason.stepUnknown,
          detail: 'Goal "${goal.id}" has no step "$target"');
    }

    // 3. No-progress guard: same step, same state as the last escalation.
    final fresh = block == null
        ? null
        : await evaluator.evaluate(block.check, state, run.paramsFor(step));
    final resolver = actor?.id ?? 'planner';

    // 4. Write the example — every resolution is one, abandonment included.
    await examples.write(
      runId: runId,
      step: blocked,
      state: block?.digest ?? const CelmDigest(),
      question: block?.check.statement ?? (run.blockWhy ?? 'action failed'),
      resolution: resumption,
      resolver: resolver,
      at: now(),
    );

    if (resumption is Abandon) {
      final o = CelmCancelled(runId,
          stoppedAt: blocked, conclusions: await ledger.byRun(runId));
      await _finish(run, o);
      return o;
    }
    // No progress means the same step, the same state, and the check still
    // not passing. A planner's answer can change the reasoner's mind about
    // an unchanged world — that is progress, and the run continues.
    if (fresh != null &&
        run.guard.unchanged(blocked, fresh.values) &&
        evaluator.band(fresh) != CelmBand.pass) {
      run.escalated = false;
      final o = CelmEscalated(runId,
          reason: CelmEscalationReason.noProgress,
          digest: fresh.digest,
          blockedAt: blocked,
          budget: run.budget.use,
          history: List.unmodifiable(run.history));
      await _finish(run, o);
      return o;
    }

    // 5. Apply and continue.
    if (resumption is ResumeWith) {
      run.overrides[resumption.step] = resumption.params;
    }
    run.escalated = false;
    run.block = null;
    run.completer = Completer<CelmOutcome>();
    unawaited(_start(run, goal.steps[target!]!, state: state));
    return run.completer.future;
  }

  // ---------------------------------------------------------------------
  // The loop
  // ---------------------------------------------------------------------

  Future<void> _start(_Run run, CelmStep step,
      {CelmObservation? state, bool entry = false}) async {
    run.driving = true;
    try {
      final o = await _drive(run, step, state: state, entry: entry);
      await _finish(run, o);
    } catch (e, st) {
      final o = CelmRefused(run.id,
          reason: CelmRefusalReason.goalUnsatisfiable, detail: '$e');
      await _finish(run, o);
      Zone.current.handleUncaughtError(e, st);
    } finally {
      run.driving = false;
    }
  }

  Future<CelmOutcome> _drive(_Run run, CelmStep step,
      {CelmObservation? state, bool entry = false}) async {
    final goal = run.goal!;
    final params = run.params;
    var current = step;
    var observed = state ?? await _perceive(run, goal.observe, params);

    if (entry) {
      // Opportunistic: a pass is a free completion; anything else is
      // "not yet", not a reason to escalate.
      final done =
          await evaluator.evaluateAll(goal.completion, observed, params);
      if (done.isEmpty || _bandOf(done) == CelmBand.pass) {
        if (goal.completion.isNotEmpty) await _record(run, done, current.id);
        if (goal.completion.isNotEmpty) return _completed(run);
      }
    }

    while (true) {
      // Yield once per iteration so a caller can cancel a loop whose ports
      // answer without ever leaving the microtask queue.
      await Future<void>.delayed(Duration.zero);
      if (run.cancelRequested) return _cancelled(run);
      if (run.budget.wallExceeded) {
        return _escalate(run, current, CelmEscalationReason.budgetExhausted,
            const CelmDigest(), null);
      }
      run.currentStep = current.id;
      final skill = manifest.surface.skills[current.skill]!;
      final stepParams = run.paramsFor(current);

      // Preconditions fail like postconditions.
      final pre = await evaluator.evaluateAll(
          skill.preconditions, observed, stepParams);
      await _record(run, pre, current.id);
      switch (_bandOf(pre)) {
        case CelmBand.pass:
          break;
        case CelmBand.fail:
          final next = await _fail(
              run,
              current,
              CelmEscalationReason.preconditionFailed,
              pre.last,
              'precondition ${pre.last.digestSummary}');
          if (next == null) return run.pendingOutcome!;
          current = next;
          continue;
        case CelmBand.undecided:
          return _escalate(
              run,
              current,
              CelmEscalationReason.lowConfidence,
              pre.last.digest,
              _Block(skill.preconditions[pre.length - 1], pre.last.digest,
                  pre.last.values));
        case CelmBand.unobservable:
          return _escalate(
              run,
              current,
              CelmEscalationReason.unobservable,
              pre.last.digest,
              _Block(skill.preconditions[pre.length - 1], pre.last.digest,
                  pre.last.values));
      }

      // Permission, then the gate, then the act.
      if (skill.writes && run.readOnly) {
        return _refused(run, CelmRefusalReason.notPermitted,
            'Skill "${skill.name}" writes and the run is read-only');
      }
      for (final call in skill.action) {
        final action = _resolveAction(call, stepParams);
        if (skill.irreversible) {
          final out = manifest.outputs[action.actuator];
          if (out == null ||
              out.writes != CelmWrites.allowList ||
              !out.allowed.contains(action.verb)) {
            return _refused(run, CelmRefusalReason.notPermitted,
                'Irreversible action "${action.port}" is not in the allow-list');
          }
          if (!await interlock!.satisfied(action, observed)) {
            return _escalate(run, current,
                CelmEscalationReason.irreversibleGate, const CelmDigest(), null,
                why: 'interlock not satisfied for ${action.port}');
          }
        }
      }

      final failure = await _act(run, skill, stepParams);
      if (run.cancelRequested) return _cancelled(run);
      observed =
          await _perceive(run, current.observe ?? goal.observe, stepParams);
      if (failure != null) {
        final next = await _fail(
            run, current, CelmEscalationReason.budgetExhausted, null, failure);
        if (next == null) return run.pendingOutcome!;
        current = next;
        continue;
      }

      // Postconditions.
      final post = await evaluator.evaluateAll(
          skill.postconditions, observed, stepParams);
      await _record(run, post, current.id);
      final lastCheck =
          post.isEmpty ? null : skill.postconditions[post.length - 1];
      switch (_bandOf(post)) {
        case CelmBand.pass:
          run.history.add(CelmAttempt(
              step: current.id, action: skill.name, result: 'pass', at: now()));
          counters.stepsAdvanced++;
          await _saveState(run);
        case CelmBand.fail:
          final next = await _fail(
              run,
              current,
              CelmEscalationReason.budgetExhausted,
              post.last,
              'postcondition ${post.last.digestSummary}');
          if (next == null) return run.pendingOutcome!;
          current = next;
          continue;
        case CelmBand.undecided:
          return _escalate(
              run,
              current,
              CelmEscalationReason.lowConfidence,
              post.last.digest,
              _Block(lastCheck!, post.last.digest, post.last.values));
        case CelmBand.unobservable:
          return _escalate(
              run,
              current,
              CelmEscalationReason.unobservable,
              post.last.digest,
              _Block(lastCheck!, post.last.digest, post.last.values));
      }

      // Where a passed step goes.
      final branch = current.branch;
      if (branch != null) {
        final j = await evaluator.evaluate(branch.check, observed, stepParams);
        await _record(run, [j], current.id);
        final String? target;
        switch (evaluator.band(j)) {
          case CelmBand.pass:
            target = branch.onTrue;
          case CelmBand.fail:
            target = branch.onFalse;
          case CelmBand.undecided:
            return _escalate(run, current, CelmEscalationReason.lowConfidence,
                j.digest, _Block(branch.check, j.digest, j.values));
          case CelmBand.unobservable:
            return _escalate(run, current, CelmEscalationReason.unobservable,
                j.digest, _Block(branch.check, j.digest, j.values));
        }
        if (target == null) {
          // A branch arm that goes nowhere is terminal.
          final done = await _completion(run, current, observed, params);
          if (done != null) return done;
          current = run.pendingStep!;
          continue;
        }
        current = goal.steps[target]!;
        continue;
      }
      if (current.onPass != null) {
        current = goal.steps[current.onPass!]!;
        continue;
      }

      // Terminal step: completion decides, on this step's observation.
      final done = await _completion(run, current, observed, params);
      if (done != null) return done;
      current = run.pendingStep!;
    }
  }

  /// Completion after a terminal step. Returns the outcome when the run
  /// ends here, or null with [run.pendingStep] set when it continues.
  Future<CelmOutcome?> _completion(
    _Run run,
    CelmStep terminal,
    CelmObservation observed,
    Map<String, dynamic> params,
  ) async {
    final goal = run.goal!;
    if (goal.completion.isEmpty) {
      return manifest.regime == CelmRegime.supervisory
          ? _continueSupervisory(run, terminal)
          : _completed(run);
    }
    final done = await evaluator.evaluateAll(goal.completion, observed, params);
    await _record(run, done, terminal.id);
    final lastCheck = goal.completion[done.length - 1];
    switch (_bandOf(done)) {
      case CelmBand.pass:
        if (manifest.regime == CelmRegime.supervisory) {
          return _continueSupervisory(run, terminal);
        }
        return _completed(run);
      case CelmBand.fail:
        final next = await _fail(
            run,
            terminal,
            CelmEscalationReason.budgetExhausted,
            done.last,
            'completion ${done.last.digestSummary}');
        if (next == null) return run.pendingOutcome!;
        run.pendingStep = next;
        return null;
      case CelmBand.undecided:
        return _escalate(
            run,
            terminal,
            CelmEscalationReason.lowConfidence,
            done.last.digest,
            _Block(lastCheck, done.last.digest, done.last.values));
      case CelmBand.unobservable:
        return _escalate(
            run,
            terminal,
            CelmEscalationReason.unobservable,
            done.last.digest,
            _Block(lastCheck, done.last.digest, done.last.values));
    }
  }

  /// Under `supervisory` a goal with nothing more to do goes back to its
  /// entry and keeps watching until cancelled or the clock runs out.
  CelmOutcome? _continueSupervisory(_Run run, CelmStep terminal) {
    run.pendingStep = run.goal!.steps[run.goal!.entry]!;
    return null;
  }

  /// Where a failed step goes: its `on_fail` if the budget allows one
  /// more attempt, otherwise up with [reason]. Returns the next step, or
  /// null with [run.pendingOutcome] set.
  Future<CelmStep?> _fail(
    _Run run,
    CelmStep step,
    CelmEscalationReason reason,
    CelmCheckResult? result,
    String why,
  ) async {
    run.history.add(CelmAttempt(
        step: step.id,
        action: step.skill,
        result: 'fail',
        why: why,
        at: now()));
    if (step.onFail != null && run.budget.spendAttempt()) {
      await _saveState(run);
      return run.goal!.steps[step.onFail!]!;
    }
    run.pendingOutcome = await _escalate(
        run, step, reason, result?.digest ?? const CelmDigest(), null,
        why: why);
    return null;
  }

  /// Performs the skill's action sequence under its timeout. Returns a
  /// failure description, or null on success.
  Future<String?> _act(
      _Run run, CelmSkill skill, Map<String, dynamic> params) async {
    for (final call in skill.action) {
      final action = _resolveAction(call, params);
      final port = actuators[action.actuator];
      if (port == null) {
        return 'celm.actuator_failed: no actuator "${action.actuator}"';
      }
      counters.actuatorCalls++;
      try {
        await port.act(action).timeout(skill.timeout);
      } on TimeoutException {
        run.history.add(CelmAttempt(
            step: run.currentStep,
            action: action.port,
            result: 'celm.timeout',
            at: now()));
        return 'celm.timeout: ${action.port} exceeded ${skill.timeout.inMilliseconds} ms';
      } catch (e) {
        run.history.add(CelmAttempt(
            step: run.currentStep,
            action: action.port,
            result: 'celm.actuator_failed',
            why: '$e',
            at: now()));
        return 'celm.actuator_failed: $e';
      }
    }
    return null;
  }

  CelmAction _resolveAction(CelmActionCall call, Map<String, dynamic> params) =>
      CelmAction(
        actuator: call.actuator,
        verb: call.verb,
        args: call.args.map((k, v) => MapEntry(k, _subst(v, params))),
      );

  Object? _subst(Object? v, Map<String, dynamic> params) {
    if (v is String && v.startsWith(r'$')) {
      final name = v.substring(1);
      return params.containsKey(name) ? params[name] : v;
    }
    if (v is Map<String, dynamic>) {
      return v.map((k, x) => MapEntry(k, _subst(x, params)));
    }
    if (v is List) return [for (final x in v) _subst(x, params)];
    return v;
  }

  Future<CelmObservation> _perceive(
      _Run run, CelmObserveRequest request, Map<String, dynamic> params) {
    counters.perceptionCalls++;
    final scope = request.scope;
    final resolved = scope != null && scope.startsWith(r'$')
        ? '${params[scope.substring(1)] ?? scope}'
        : scope;
    return perception
        .observe(CelmObserveRequest(scope: resolved, depth: request.depth));
  }

  CelmBand _bandOf(List<CelmCheckResult> results) =>
      results.isEmpty ? CelmBand.pass : evaluator.band(results.last);

  /// Appends a conclusion per result — before the loop advances.
  Future<void> _record(
      _Run run, List<CelmCheckResult> results, String step) async {
    for (final r in results) {
      switch (r) {
        case Observed(:final value):
          await ledger.append(ObservedConclusion(
            id: ledger.nextId(run.id),
            runId: run.id,
            statement: '$step: ${r.statement} = $value',
            at: now(),
            inputs: r.digest.relevant,
          ));
        case Judged():
          final premises = <String>[];
          for (final f in r.digest.relevant) {
            final id = ledger.nextId(run.id);
            premises.add(id);
            await ledger.append(ObservedConclusion(
              id: id,
              runId: run.id,
              statement: '${f.field} = ${_show(r.values[f.field])}',
              at: now(),
              inputs: [f],
            ));
          }
          await ledger.append(JudgedConclusion(
            id: ledger.nextId(run.id),
            runId: run.id,
            statement: '$step: ${r.statement} = ${r.verdict}'
                '${r.rationale.isEmpty ? '' : ' (${r.rationale})'}',
            at: now(),
            confidence: r.confidence,
            reasoner: r.reasoner,
            reasonerRemote: r.remote,
            premises: premises,
            rationale: r.rationale,
          ));
        case Unobservable():
          break;
      }
    }
  }

  Future<CelmOutcome> _escalate(
    _Run run,
    CelmStep step,
    CelmEscalationReason reason,
    CelmDigest digest,
    _Block? block, {
    String? why,
  }) async {
    if (why != null) {
      run.history.add(CelmAttempt(
          step: step.id,
          action: step.skill,
          result: reason.name,
          why: why,
          at: now()));
    }
    final terminal = reason == CelmEscalationReason.noProgress ||
        reason == CelmEscalationReason.budgetExhausted &&
            run.budget.wallExceeded;
    run.escalated = false;
    if (!terminal && block != null) {
      if (!run.guard.admit(step.id, block.values)) {
        return CelmEscalated(run.id,
            reason: CelmEscalationReason.noProgress,
            digest: digest,
            blockedAt: step.id,
            budget: run.budget.use,
            history: List.unmodifiable(run.history));
      }
      if (!run.budget.spendEscalation()) {
        final o = CelmEscalated(run.id,
            reason: CelmEscalationReason.budgetExhausted,
            digest: digest,
            blockedAt: step.id,
            budget: run.budget.use,
            history: List.unmodifiable(run.history));
        return o;
      }
      run.escalated = true;
      run.block = block;
      run.currentStep = step.id;
    } else if (!terminal) {
      if (!run.budget.spendEscalation()) {
        return CelmEscalated(run.id,
            reason: CelmEscalationReason.budgetExhausted,
            digest: digest,
            blockedAt: step.id,
            budget: run.budget.use,
            history: List.unmodifiable(run.history));
      }
      run.escalated = true;
      run.currentStep = step.id;
      run.blockWhy = why;
    }
    final o = CelmEscalated(run.id,
        reason: reason,
        digest: digest,
        blockedAt: step.id,
        budget: run.budget.use,
        history: List.unmodifiable(run.history));
    if (run.escalated) {
      await _saveState(run);
    }
    return o;
  }

  CelmOutcome _completed(_Run run) =>
      CelmCompleted(run.id, budget: run.budget.use, conclusions: const []);

  Future<CelmOutcome> _cancelled(_Run run) async => CelmCancelled(run.id,
      stoppedAt: run.currentStep, conclusions: await ledger.byRun(run.id));

  CelmOutcome _refused(_Run run, CelmRefusalReason reason, String detail) =>
      CelmRefused(run.id, reason: reason, detail: detail);

  Future<void> _finish(_Run run, CelmOutcome o) async {
    // A suspension keeps the run open; everything else ends it.
    final suspended = o is CelmEscalated && run.escalated;
    if (o is CelmCompleted) {
      o = CelmCompleted(run.id,
          budget: o.budget, conclusions: await ledger.byRun(run.id));
    }
    if (!suspended) {
      run.outcome = o;
      run.escalated = false;
    }
    await _saveState(run);
    if (!run.completer.isCompleted) run.completer.complete(o);
  }

  Future<void> _saveState(_Run run) => store.runs.save(
        run.id,
        CelmRunState(
          runId: run.id,
          goal: run.ref,
          currentStep: run.currentStep,
          budget: run.budget.use,
          startedAt: run.startedAt,
          history: List.unmodifiable(run.history),
          fingerprints: run.guard.fingerprints,
          outcome: run.outcome,
          escalated: run.escalated,
        ),
      );

  _Run _require(String runId) => _runs[runId] ?? _notFound(runId);

  Never _notFound(String runId) => throw AnalysisError(
        code: 'celm.run_not_found',
        message: 'Run "$runId" not found',
        details: {'runId': runId},
      );
}

/// What blocked, so a resumption can re-evaluate exactly it.
class _Block {
  const _Block(this.check, this.digest, this.values);
  final CelmCheck check;
  final CelmDigest digest;
  final Map<String, Object?> values;
}

class _Run {
  _Run({
    required this.id,
    required this.ref,
    required this.goal,
    required this.constraints,
    required this.actor,
    required this.budget,
    required this.guard,
    required this.startedAt,
  });

  /// Rebuilds a suspended run from its stored state. The block is
  /// recovered from the goal's step, so a resumption can re-evaluate it.
  factory _Run.fromState(
      CelmRunState s, CelmManifest manifest, DateTime Function() now) {
    final goal = manifest.surface.goals[s.goal.id];
    final run = _Run(
      id: s.runId,
      ref: s.goal,
      goal: goal,
      constraints: const CelmConstraints(),
      actor: null,
      budget: CelmBudget(
        manifest.policy.budget,
        now: now,
        started: s.startedAt,
        attemptsSpent: s.budget.attemptsSpent,
        escalationsSpent: s.budget.escalationsSpent,
      ),
      guard: CelmNoProgressGuard(s.fingerprints),
      startedAt: s.startedAt,
    );
    run.history.addAll(s.history);
    run.currentStep = s.currentStep;
    run.escalated = s.escalated;
    run.outcome = s.outcome;
    if (goal != null && s.escalated) {
      final step = goal.steps[s.currentStep];
      final skill = step == null ? null : manifest.surface.skills[step.skill];
      final check = step?.branch?.check ??
          (skill != null && skill.postconditions.isNotEmpty
              ? skill.postconditions.last
              : goal.completion.isNotEmpty
                  ? goal.completion.last
                  : null);
      if (check != null) {
        run.block = _Block(check, const CelmDigest(), const {});
      }
    }
    return run;
  }
  final String id;
  final CelmGoalRef ref;
  final CelmGoal? goal;
  final CelmConstraints constraints;
  final AnalysisActor? actor;
  final CelmBudget budget;
  final CelmNoProgressGuard guard;
  final DateTime startedAt;
  final List<CelmAttempt> history = [];
  final Map<String, Map<String, dynamic>> overrides = {};
  Completer<CelmOutcome> completer = Completer<CelmOutcome>();
  String currentStep = '';
  bool escalated = false;
  bool driving = false;
  bool cancelRequested = false;
  bool readOnly = false;
  _Block? block;
  String? blockWhy;
  CelmOutcome? outcome;
  CelmOutcome? pendingOutcome;
  CelmStep? pendingStep;

  Map<String, dynamic> get params => ref.params;

  Map<String, dynamic> paramsFor(CelmStep step) => {
        ...ref.params,
        ...step.params.map((k, v) => MapEntry(
            k,
            v is String && v.startsWith(r'$')
                ? ref.params[v.substring(1)] ?? v
                : v)),
        ...?overrides[step.id],
      };
}

/// Renders a value for a statement with quality cells unwrapped.
Object? _show(Object? v) {
  if (v is Map<String, dynamic> &&
      v.containsKey('value') &&
      (v.length == 1 || (v.length == 2 && v['quality'] is num))) {
    return _show(v['value']);
  }
  if (v is Map<String, dynamic>) return v.map((k, x) => MapEntry(k, _show(x)));
  if (v is List) return [for (final x in v) _show(x)];
  return v;
}

extension on CelmCheckResult {
  String get digestSummary => digest.relevant.map((f) => f.field).join(', ');
}
