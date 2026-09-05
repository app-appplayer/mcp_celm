import 'package:mcp_celm/mcp_celm.dart';
import 'package:test/test.dart';

import 'fixtures/fixtures.dart';

/// TEST-PLAN §2 (the invariant), §3 (unobservable and what is not),
/// §5 (termination), §6 (sequencing).
void main() {
  Matcher refused(String code) =>
      throwsA(isA<AnalysisError>().having((e) => e.code, 'code', code));

  const path = {'path': '/tmp/notes.txt'};

  /// A port over the open-document flow with a scripted reasoner in the
  /// `llm` slot, so the judge postcondition is under test control.
  ({
    CelmPortAdapter port,
    ScriptedReasoner reasoner,
    RecordingActuator actuator
  }) judged(CelmJudgment Function(CelmJudgmentRequest r, int i) answer,
      {Map<String, dynamic>? policy, ScriptedPerception? perception}) {
    final flow = openFlow();
    final reasoner = ScriptedReasoner(answer);
    final port = build(
      manifest: manifestJson(reasoner: {'kind': 'llm'}, policy: policy),
      reasoner: reasoner,
      perception: perception ?? flow.perception,
      actuators: {'hid': flow.actuator, 'scpi': scpi()},
    );
    return (port: port, reasoner: reasoner, actuator: flow.actuator);
  }

  group('§2 the invariant', () {
    test('a passing goal completes, and every step was verified', () async {
      final actuator = hid();
      final perception = perceptionAfterActs(actuator,
          before: desktopEmpty(), after: desktopOpen());
      final port = build(
          perception: perception, actuators: {'hid': actuator, 'scpi': scpi()});
      final o = await run(port, 'open_document', params: path);
      expect(o, isA<CelmCompleted>());
      // entry: open (precondition fails: not focused) -> focus -> open.
      expect(actuator.actions.map((a) => a.verb).toList(),
          ['click', 'key', 'type', 'key']);
      expect(port.runner.counters.stepsAdvanced, 2);
    });

    test('failed observation does not advance', () async {
      final port =
          build(perception: answering((i) => desktopOpen(title: 'other.txt')));
      final o = await run(port, 'open_document', params: path);
      expect(o, isA<CelmEscalated>());
      expect((o as CelmEscalated).reason, CelmEscalationReason.budgetExhausted);
      final p = await port.progress(o.runId);
      expect(p.history.where((h) => h.step == 'open' && h.result == 'pass'),
          isEmpty);
    });

    test(
        'confident and wrong does not advance: confidence never overrides an observation',
        () async {
      final j = judged(
          (r, i) => const CelmJudgment(verdict: true, confidence: 0.99),
          perception: answering((i) => desktopOpen(title: 'other.txt')));
      final o = await run(j.port, 'open_document', params: path);
      expect(o, isA<CelmEscalated>());
      final p = await j.port.progress(o.runId);
      expect(p.history.where((h) => h.step == 'open' && h.result == 'pass'),
          isEmpty);
      // The observation failed first; the judgment was never even asked.
      expect(j.reasoner.calls, 0);
    });

    test(
        'actuator error does not advance; recorded, attempt spent, on_fail taken',
        () async {
      final actuator = hid(failWith: StateError('hid offline'));
      final port = build(
        perception: answering((i) => desktopOpen(title: 'blank')),
        actuators: {'hid': actuator, 'scpi': scpi()},
      );
      final o = await run(port, 'open_document', params: path);
      expect((o as CelmEscalated).reason, CelmEscalationReason.budgetExhausted);
      final p = await port.progress(o.runId);
      expect(p.history.any((h) => h.result == 'celm.actuator_failed'), isTrue);
      expect(
          p.history.map((h) => '${h.step}:${h.result}'), contains('focus:fail'),
          reason: 'on_fail was taken');
      expect(p.budget.attemptsSpent, greaterThanOrEqualTo(1));
      expect(p.history.where((h) => h.result == 'pass'), isEmpty);
    });

    test(
        'timeout does not advance; perception is called before the failure is routed',
        () async {
      final actuator = hid(delay: const Duration(milliseconds: 400));
      final perception = answering((i) => desktopOpen(title: 'blank'));
      final port = build(
        manifest: manifestJson(policy: {
          'budget': {'attempts': 0, 'max_escalations': 3, 'wall_ms': 60000},
        }),
        perception: perception,
        actuators: {'hid': actuator, 'scpi': scpi()},
      );
      final o = await run(port, 'open_document', params: path);
      expect((o as CelmEscalated).reason, CelmEscalationReason.budgetExhausted);
      final p = await port.progress(o.runId);
      expect(p.history.any((h) => h.result == 'celm.timeout'), isTrue);
      // entry observation + the re-perceive after the timed-out act.
      expect(perception.calls, 2);
    });

    test('a confident false fails the step (takes on_fail)', () async {
      final j = judged(
          (r, i) => const CelmJudgment(verdict: false, confidence: 0.95));
      final o = await run(j.port, 'open_document', params: path);
      expect((o as CelmEscalated).reason, CelmEscalationReason.budgetExhausted);
      final p = await j.port.progress(o.runId);
      expect(p.budget.attemptsSpent, 3,
          reason: 'each confident false spent an attempt via on_fail');
      expect(p.history.where((h) => h.step == 'focus'), isNotEmpty);
    });

    test('a leaning judgment retries', () async {
      final j =
          judged((r, i) => const CelmJudgment(verdict: true, confidence: 0.7));
      final o = await run(j.port, 'open_document', params: path);
      expect((o as CelmEscalated).reason, CelmEscalationReason.budgetExhausted);
      expect((await j.port.progress(o.runId)).budget.attemptsSpent, 3);
    });

    test('an undecided judgment escalates lowConfidence, no attempt spent',
        () async {
      final j =
          judged((r, i) => const CelmJudgment(verdict: true, confidence: 0.2));
      final o = await run(j.port, 'open_document', params: path);
      expect((o as CelmEscalated).reason, CelmEscalationReason.lowConfidence);
      expect(o.blockedAt, 'open');
      expect((await j.port.progress(o.runId)).budget.attemptsSpent, 0);
      expect(o.digest.relevant.map((f) => f.field), ['window.frontmost']);
    });

    test('re-perceive after every action, before every postcondition',
        () async {
      final perception = answering(
          (i) => {...desktopOpen(), if (i >= 3) 'steps_done': cell(true)});
      final port = build(perception: perception);
      expect(await run(port, 'three_plain'), isA<CelmCompleted>());
      // 1 at entry + 1 after each of three steps.
      expect(perception.calls, 4);
    });

    test('every band has a destination at every site (D9)', () async {
      final sites = <String, Map<String, dynamic>>{
        'precondition': {
          'name': 'j',
          'preconditions': [
            judgeCheck('site precondition?', ['app'])
          ],
          'action': {'sequence': <Object>[]},
        },
        'postcondition': {
          'name': 'j',
          'action': {'sequence': <Object>[]},
          'postconditions': [
            judgeCheck('site postcondition?', ['app'])
          ],
        },
      };
      const cases = [(true, 0.9), (false, 0.9), (true, 0.7), (true, 0.1)];
      for (final site in sites.entries) {
        for (final (verdict, conf) in cases) {
          final port = build(
            manifest: manifestJson(reasoner: {'kind': 'llm'}),
            reasoner: ScriptedReasoner(
                (r, i) => CelmJudgment(verdict: verdict, confidence: conf)),
            surface: desktopSurface(extraSkills: [
              site.value
            ], extraGoals: [
              {
                'id': 'g',
                'observe': {'scope': 'screen', 'depth': 'structure'},
                'entry': 'a',
                'steps': {
                  'a': {'skill': 'j', 'on_pass': null, 'on_fail': null},
                },
                'completion': [observeCheck('done == true')],
              },
            ]),
            perception: answering(
                (i) => {...desktopOpen(), if (i >= 1) 'done': cell(true)}),
          );
          final o = await run(port, 'g');
          expect(o, anyOf(isA<CelmCompleted>(), isA<CelmEscalated>()),
              reason: '${site.key} $verdict $conf');
        }
      }
      for (final (verdict, conf) in cases) {
        final port = build(
          manifest: manifestJson(reasoner: {'kind': 'llm'}),
          reasoner: ScriptedReasoner(
              (r, i) => CelmJudgment(verdict: verdict, confidence: conf)),
          perception: desktopWithPanel(),
        );
        expect(await run(port, 'read_panel_status'),
            anyOf(isA<CelmCompleted>(), isA<CelmEscalated>()));
        expect(await run(port, 'judged_done'),
            anyOf(isA<CelmCompleted>(), isA<CelmEscalated>()));
      }
    });
  });

  group('§3 unobservable, and what is not', () {
    Map<String, dynamic> goalReading() => {
          'id': 'g',
          'observe': {'scope': 'screen', 'depth': 'structure'},
          'entry': 'a',
          'steps': {
            'a': {'skill': 'chk', 'on_pass': null, 'on_fail': 'a'},
          },
          'completion': [observeCheck('done == true')],
        };
    CelmPortAdapter withCheck(String expr, CelmObservation state,
            {double quality = 0}) =>
        build(
          surface: desktopSurface(extraSkills: [
            {
              'name': 'chk',
              'action': {'sequence': <Object>[]},
              'postconditions': [observeCheck(expr, quality: quality)],
            },
          ], extraGoals: [
            goalReading()
          ]),
          perception: ScriptedPerception((r, i) => state),
        );

    test('absent but covered retries: "the app is not open yet"', () async {
      final port =
          withCheck('window.frontmost.title == "x"', obs(desktopEmpty()));
      final o = await run(port, 'g');
      expect((o as CelmEscalated).reason, CelmEscalationReason.budgetExhausted);
      expect((await port.progress(o.runId)).budget.attemptsSpent, 3,
          reason: 'retried until the budget');
    });

    test('absent and uncovered escalates, does not retry', () async {
      final port = withCheck(
          'window.frontmost.title == "x"',
          obs(desktopEmpty(), coverage: const [
            CelmCoverage(scope: 'app', depth: CelmDepth.atoms)
          ]));
      final o = await run(port, 'g');
      expect((o as CelmEscalated).reason, CelmEscalationReason.unobservable);
      expect((await port.progress(o.runId)).budget.attemptsSpent, 0);
      expect(o.digest.relevant.map((f) => f.field), ['window.frontmost.title']);
    });

    test('no coverage statement: every absence is unobservable', () async {
      final port = withCheck('window.frontmost.title == "x"',
          obs(desktopEmpty(), coverage: const []));
      final o = await run(port, 'g');
      expect((o as CelmEscalated).reason, CelmEscalationReason.unobservable);
    });

    test('below floor escalates with the field named; reasoner not called',
        () async {
      final reasoner = constantReasoner(true, 0.9);
      final port = build(
        manifest: manifestJson(reasoner: {'kind': 'llm'}),
        reasoner: reasoner,
        surface: desktopSurface(extraSkills: [
          {
            'name': 'chk',
            'action': {'sequence': <Object>[]},
            'postconditions': [
              {
                ...judgeCheck('is it fine?', ['window.frontmost.title']),
                'requires_quality': 0.8
              },
            ],
          },
        ], extraGoals: [
          goalReading()
        ]),
        perception: ScriptedPerception((r, i) => obs(desktopOpen(q: 0.4))),
      );
      final o = await run(port, 'g');
      expect((o as CelmEscalated).reason, CelmEscalationReason.unobservable);
      expect(reasoner.calls, 0);
      expect(o.digest.relevant.single.quality, 0.4);
    });

    test('failed precondition retries through on_fail, no escalation',
        () async {
      final actuator = hid();
      final perception = perceptionAfterActs(actuator,
          before: desktopEmpty(), after: desktopOpen());
      final port = build(
          perception: perception, actuators: {'hid': actuator, 'scpi': scpi()});
      final o = await run(port, 'open_document', params: path);
      expect(o, isA<CelmCompleted>());
      final p = await port.progress(o.runId);
      expect(p.history.first.result, 'fail');
      expect(p.history.first.why, startsWith('precondition'));
    });

    test('failed precondition with no alternative escalates preconditionFailed',
        () async {
      final port = build(
        surface: desktopSurface(extraGoals: [
          {
            'id': 'g',
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
          },
        ]),
        perception: answering((i) => desktopEmpty()),
      );
      final o = await run(port, 'g', params: {'path': '/x'});
      expect(
          (o as CelmEscalated).reason, CelmEscalationReason.preconditionFailed);
    });

    test('deeper coverage satisfies a shallower requirement', () async {
      final port = withCheck(
          'window.frontmost.title == "x"',
          obs(desktopEmpty(), coverage: const [
            CelmCoverage(scope: 'screen', depth: CelmDepth.atoms)
          ]));
      final o = await run(port, 'g');
      expect((o as CelmEscalated).reason, CelmEscalationReason.budgetExhausted,
          reason: 'observed(false), retried');
    });

    test('shallower coverage does not satisfy: examined, but not deeply enough',
        () async {
      final port = withCheck(
          'window.frontmost.title == "x"',
          obs(desktopEmpty(), coverage: const [
            CelmCoverage(scope: 'screen', depth: CelmDepth.coarse)
          ]));
      final o = await run(port, 'g');
      expect((o as CelmEscalated).reason, CelmEscalationReason.unobservable);
    });

    test('scope is a prefix', () async {
      final port = withCheck(
          'window.frontmost.title == "x"',
          obs(desktopEmpty(), coverage: const [
            CelmCoverage(scope: 'window.other', depth: CelmDepth.atoms)
          ]));
      final o = await run(port, 'g');
      expect((o as CelmEscalated).reason, CelmEscalationReason.unobservable);
    });
  });

  group('§5 termination', () {
    test('budget exhaustion reachable', () async {
      final port = build(perception: answering((i) => desktopOpen(title: 'z')));
      final o = await run(port, 'open_document', params: path);
      expect((o as CelmEscalated).reason, CelmEscalationReason.budgetExhausted);
    });

    test(
        'escalation cannot repeat forever: same step, unchanged state → noProgress',
        () async {
      final j =
          judged((r, i) => const CelmJudgment(verdict: true, confidence: 0.1));
      final first = await run(j.port, 'open_document', params: path);
      expect(
          (first as CelmEscalated).reason, CelmEscalationReason.lowConfidence);
      final second = await j.port.resume(first.runId, const ResumeAt('open'));
      expect((second as CelmEscalated).reason, CelmEscalationReason.noProgress);
      expect((await j.port.progress(first.runId)).outcome, isA<CelmEscalated>(),
          reason: 'terminal');
    });

    test(
        'a helpful escalation is not punished: completes, retry budget untouched',
        () async {
      var answer = 0.1;
      var after = desktopOpen();
      final actuator = hid();
      final port = build(
        manifest: manifestJson(reasoner: {'kind': 'llm'}),
        reasoner: ScriptedReasoner(
            (r, i) => CelmJudgment(verdict: true, confidence: answer)),
        perception: ScriptedPerception((r, i) => obsFor(
            r,
            actuator.actions.length >= 3
                ? after
                : desktopOpen(title: 'blank'))),
        actuators: {'hid': actuator, 'scpi': scpi()},
      );
      final first = await run(port, 'open_document', params: path);
      expect(first, isA<CelmEscalated>());
      // The planner's answer: a corrected path; the world now shows it, and
      // the reasoner recognizes what it sees.
      after = desktopOpen(title: 'notes.txt.bak');
      answer = 0.95;
      final second = await port.resume(first.runId,
          const ResumeWith('open', {'path': '/tmp/notes.txt.bak'}));
      expect(second, isA<CelmCompleted>());
      expect((second as CelmCompleted).budget.attemptsSpent, 0);
      expect(second.budget.escalationsSpent, 1);
    });

    test('escalation ceiling terminates', () async {
      var n = 0;
      final actuator = hid();
      final port = build(
        manifest: manifestJson(reasoner: {
          'kind': 'llm'
        }, policy: {
          'budget': {'attempts': 3, 'max_escalations': 2, 'wall_ms': 60000},
        }),
        reasoner: ScriptedReasoner(
            (r, i) => const CelmJudgment(verdict: true, confidence: 0.1)),
        // The state changes every look, so no-progress never fires and the
        // ceiling is what ends it.
        perception: ScriptedPerception((r, i) => obsFor(
            r,
            actuator.actions.length >= 3
                ? desktopOpen(title: 'notes.txt.${n++}')
                : desktopOpen(title: 'blank'))),
        actuators: {'hid': actuator, 'scpi': scpi()},
      );
      var o = await run(port, 'open_document', params: path);
      var rounds = 0;
      while (o is CelmEscalated &&
          o.reason == CelmEscalationReason.lowConfidence &&
          rounds < 10) {
        o = await port.resume(o.runId, const ResumeAt('open'));
        rounds++;
      }
      expect((o as CelmEscalated).reason, CelmEscalationReason.budgetExhausted);
      expect(o.budget.escalationsSpent, 2);
      expect((await port.progress(o.runId)).outcome, isNotNull,
          reason: 'terminal');
    });

    test('wall clock terminates a run under its attempt count', () async {
      final clock = FakeClock();
      final perception = ScriptedPerception((r, i) {
        clock.advance(const Duration(seconds: 30));
        return obsFor(r, desktopOpen(title: 'z'));
      });
      final port = build(perception: perception, now: clock.call);
      final o = await run(port, 'open_document', params: path);
      expect((o as CelmEscalated).reason, CelmEscalationReason.budgetExhausted);
      expect((await port.progress(o.runId)).budget.attemptsSpent, lessThan(3));
      expect((await port.progress(o.runId)).outcome, isNotNull,
          reason: 'terminal');
    });

    test('resume re-perceives before deciding', () async {
      final j =
          judged((r, i) => const CelmJudgment(verdict: true, confidence: 0.1));
      final first = await run(j.port, 'open_document', params: path);
      final perception = j.port.perception as ScriptedPerception;
      final before = perception.calls;
      await j.port.resume(first.runId, const ResumeAt('open'));
      expect(perception.calls, greaterThan(before));
    });

    test('fingerprint ignores noise elsewhere in the descriptor', () async {
      var tick = 0;
      final actuator = hid();
      final port = build(
        manifest: manifestJson(reasoner: {'kind': 'llm'}),
        reasoner: ScriptedReasoner(
            (r, i) => const CelmJudgment(verdict: true, confidence: 0.1)),
        perception: ScriptedPerception((r, i) => obsFor(r, {
              ...(actuator.actions.length >= 3
                  ? desktopOpen()
                  : desktopOpen(title: 'blank')),
              'clock': cell(tick++),
            })),
        actuators: {'hid': actuator, 'scpi': scpi()},
      );
      final first = await run(port, 'open_document', params: path);
      final second = await port.resume(first.runId, const ResumeAt('open'));
      expect((second as CelmEscalated).reason, CelmEscalationReason.noProgress);
    });

    test(
        'cancel terminates a supervisory run; evidence before the stop survives',
        () async {
      final ctl = RecordingActuator(
          vocabulary: {'set'}, kinds: const {'set': CelmActionKind.setpoint});
      final port = build(
        manifest: manifestJson(regime: 'supervisory', outputs: [
          {
            'actuator': 'ctl',
            'port': 'mcp:ctl',
            'vocab': ['set'],
            'writes': 'allow_list',
            'allowed': ['set']
          },
        ]),
        surface: {
          'pack': CelmSurfacePack.schema,
          'id': 'desktop-hid',
          'skills': [
            {
              'name': 'set_target',
              'action': {
                'sequence': [
                  {
                    'port': 'ctl.set',
                    'args': {'v': 1}
                  },
                ]
              },
              'postconditions': [observeCheck('a == 1')],
              'writes': true,
            },
          ],
          'goals': [
            {
              'id': 'hold',
              'observe': {'scope': 'screen', 'depth': 'structure'},
              'entry': 's',
              'steps': {
                's': {'skill': 'set_target', 'on_pass': 's'},
              },
            },
          ],
        },
        actuators: {'ctl': ctl},
        perception: answering((i) => {'a': cell(1)}),
      );
      final h = await port.execute(const CelmGoalRef(id: 'hold'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final o = await port.cancel(h.runId);
      expect(o, isA<CelmCancelled>());
      expect((o as CelmCancelled).conclusions, isNotEmpty);
      expect(ctl.actions.length, greaterThan(1), reason: 'it was looping');
      expect(await h.outcome, isA<CelmCancelled>());
    });

    test('unknown resume step is refused; the run is not consumed', () async {
      final j =
          judged((r, i) => const CelmJudgment(verdict: true, confidence: 0.1));
      final first = await run(j.port, 'open_document', params: path);
      final r =
          await j.port.resume(first.runId, const ResumeAt('no_such_step'));
      expect((r as CelmRefused).reason, CelmRefusalReason.stepUnknown);
      expect((await j.port.progress(first.runId)).escalated, isTrue);
    });

    test('deadline narrows, never widens', () async {
      final clock = FakeClock();
      final perception = ScriptedPerception((r, i) {
        clock.advance(const Duration(seconds: 1));
        return obsFor(r, desktopOpen(title: 'z'));
      });
      final port = build(perception: perception, now: clock.call);
      final o = await run(port, 'open_document',
          params: path,
          constraints: const CelmConstraints(deadline: Duration(seconds: 2)));
      expect((o as CelmEscalated).reason, CelmEscalationReason.budgetExhausted);
      expect(o.budget.attemptsSpent, lessThan(3),
          reason: 'the deadline, not the attempts, ended it');
      final wide = build(perception: perception, now: clock.call);
      final w = await run(wide, 'open_document',
          params: path,
          constraints: const CelmConstraints(deadline: Duration(seconds: 120)));
      expect((w as CelmEscalated).budget.attemptsSpent, 3,
          reason: '120 s did not widen the 60 s wall; attempts ended it');
    });

    test('replay: same descriptors, same answers, same actions (NFR-DET-001)',
        () async {
      Future<List<String>> once() async {
        final actuator = hid();
        final port = build(
          perception: perceptionAfterActs(actuator,
              before: desktopEmpty(), after: desktopOpen()),
          actuators: {'hid': actuator, 'scpi': scpi()},
        );
        await run(port, 'open_document', params: path);
        return actuator.actions.map((a) => a.port).toList();
      }

      expect(await once(), equals(await once()));
    });

    test('resumed after restart: a new runtime over the same store continues',
        () async {
      final store = InMemoryCelmStore();
      final first =
          judged((r, i) => const CelmJudgment(verdict: true, confidence: 0.1));
      final port1 = build(
        manifest: manifestJson(reasoner: {'kind': 'llm'}),
        reasoner: first.reasoner,
        perception: first.port.perception,
        actuators: {'hid': first.actuator, 'scpi': scpi()},
        store: store,
      );
      final o = await run(port1, 'open_document', params: path);
      expect(o, isA<CelmEscalated>());

      final actuator2 = hid();
      final port2 = build(
        manifest: manifestJson(reasoner: {'kind': 'llm'}),
        reasoner: constantReasoner(true, 0.95),
        perception: ScriptedPerception(
            (r, i) => obsFor(r, desktopOpen(title: 'notes.txt.v2'))),
        actuators: {'hid': actuator2, 'scpi': scpi()},
        store: store,
      );
      final r = await port2.resume(
          o.runId, const ResumeWith('open', {'path': '/tmp/notes.txt.v2'}));
      expect(r, isA<CelmCompleted>());
      expect((r as CelmCompleted).budget.escalationsSpent, 1,
          reason: 'budget as it stood');
    });
  });

  group('§6 sequencing', () {
    test('no reasoner call for a plain goal', () async {
      final reasoner = constantReasoner(true, 0.9);
      final port = build(
        manifest: manifestJson(reasoner: {'kind': 'llm'}),
        reasoner: reasoner,
        perception: answering(
            (i) => {...desktopOpen(), if (i >= 3) 'steps_done': cell(true)}),
      );
      expect(await run(port, 'three_plain'), isA<CelmCompleted>());
      expect(reasoner.calls, 0);
      expect(port.runner.counters.stepsAdvanced, 3);
    });

    test('one call for a declared branch, recorded as a judgment', () async {
      final port = build(perception: desktopWithPanel(color2: 'red'));
      final o = await run(port, 'read_panel_status');
      expect(o, isA<CelmCompleted>());
      expect(port.runner.counters.reasonerCalls, 1);
      final judgedOnes =
          (o as CelmCompleted).conclusions.whereType<JudgedConclusion>();
      expect(judgedOnes, hasLength(1));
      expect(judgedOnes.single.reasoner, 'rules:lab-panel');
      expect(judgedOnes.single.reasonerRemote, isFalse);
      // red -> on_true -> detail, then completion.
      expect((await port.progress(o.runId)).history.map((h) => h.step),
          contains('detail'));
    });

    test('on_pass followed, on_fail followed with one attempt spent', () async {
      final actuator = hid();
      final port = build(
        perception: perceptionAfterActs(actuator,
            before: desktopEmpty(), after: desktopOpen()),
        actuators: {'hid': actuator, 'scpi': scpi()},
      );
      final o = await run(port, 'open_document', params: path);
      final p = await port.progress(o.runId);
      expect(p.budget.attemptsSpent, 1);
      expect(p.history.map((h) => '${h.step}:${h.result}'),
          ['open:fail', 'focus:pass', 'open:pass']);
    });

    test('no on_fail: a failing step escalates rather than stopping silently',
        () async {
      final port = build(
        surface: desktopSurface(extraGoals: [
          {
            'id': 'g',
            'observe': {'scope': 'screen', 'depth': 'structure'},
            'entry': 'a',
            'steps': {
              'a': {
                'skill': 'focus_app',
                'params': {'app': 'x'},
                'on_pass': null
              },
            },
          },
        ]),
        perception: answering((i) => desktopEmpty()),
      );
      final o = await run(port, 'g');
      expect((o as CelmEscalated).reason, CelmEscalationReason.budgetExhausted);
      expect(o.blockedAt, 'a');
    });

    test('branch on unobservable escalates; the branch is not guessed',
        () async {
      // At atoms the panel comes back with its indicators' states but no
      // colors, and coverage says only the first indicator was examined.
      final port = build(
        perception: ScriptedPerception((r, i) => r.depth == CelmDepth.atoms
            ? obs({
                ...desktopOpen(),
                'panel': {
                  'mode': cell('run'),
                  'indicators': [
                    {'state': cell('ok')},
                    {'state': cell('ok')},
                    {'state': cell('fault')},
                  ],
                },
              }, coverage: const [
                CelmCoverage(
                    scope: 'panel.indicators[0]', depth: CelmDepth.atoms),
                CelmCoverage(scope: 'app', depth: CelmDepth.atoms),
              ])
            : obsFor(r, {
                ...desktopOpen(),
                'panel': {'mode': cell('run')}
              })),
      );
      final o = await run(port, 'read_panel_status');
      expect((o as CelmEscalated).reason, CelmEscalationReason.unobservable);
      expect(port.runner.counters.reasonerCalls, 0);
    });

    test('branch leaning goes to on_false, no attempt spent', () async {
      final port = build(
        manifest: manifestJson(reasoner: {'kind': 'llm'}),
        reasoner: ScriptedReasoner(
            (r, i) => const CelmJudgment(verdict: true, confidence: 0.7)),
        perception: desktopWithPanel(),
      );
      final o = await run(port, 'read_panel_status');
      expect(o, isA<CelmCompleted>());
      expect((o as CelmCompleted).budget.attemptsSpent, 0);
      expect((await port.progress(o.runId)).history.map((h) => h.step),
          isNot(contains('detail')));
    });

    test('judged completion completes', () async {
      final port = build(perception: answering((i) => desktopOpen()));
      final o = await run(port, 'judged_done');
      expect(o, isA<CelmCompleted>());
      expect((o as CelmCompleted).conclusions.whereType<JudgedConclusion>(),
          isNotEmpty);
    });

    test(
        "completion decided after the terminal step, on that step's observation",
        () async {
      final perception = desktopWithPanel();
      final port = build(perception: perception);
      final o = await run(port, 'read_panel_status');
      expect(o, isA<CelmCompleted>());
      // Entry asked for structure and did not escalate; the terminal step
      // asked for the panel at atoms and completion was decided on that.
      expect(perception.requests.first.depth, CelmDepth.structure);
      expect(perception.requests.last.depth, CelmDepth.atoms);
      expect(perception.requests.last.scope, 'panel');
    });

    test('terminal step passes, completion false: takes on_fail, then budget',
        () async {
      final port = build(
        surface: desktopSurface(extraGoals: [
          {
            'id': 'g',
            'observe': {'scope': 'screen', 'depth': 'structure'},
            'entry': 'a',
            'steps': {
              'a': {'skill': 'look', 'on_pass': null, 'on_fail': 'a'},
            },
            'completion': [observeCheck('app.name == "Never"')],
          },
        ]),
        perception: answering((i) => desktopOpen()),
      );
      final o = await run(port, 'g');
      expect((o as CelmEscalated).reason, CelmEscalationReason.budgetExhausted);
      expect(o.blockedAt, 'a');
      expect((await port.progress(o.runId)).budget.attemptsSpent, 3);
    });

    test('already done at entry: completed with zero actions', () async {
      final actuator = hid();
      final port = build(
          perception: answering((i) => desktopOpen()),
          actuators: {'hid': actuator, 'scpi': scpi()});
      final o = await run(port, 'open_document', params: path);
      expect(o, isA<CelmCompleted>());
      expect(actuator.actions, isEmpty);
    });

    test('goal unknown is Refused on the handle, with an id on record',
        () async {
      final port = build();
      final h = await port.execute(const CelmGoalRef(id: 'nope'));
      expect(h.runId, isNotEmpty);
      expect((await h.outcome as CelmRefused).reason,
          CelmRefusalReason.goalUnknown);
      expect((await port.progress(h.runId)).outcome, isA<CelmRefused>());
    });

    test('missing params is Refused(goalUnsatisfiable)', () async {
      final o = await run(build(), 'open_document');
      expect((o as CelmRefused).reason, CelmRefusalReason.goalUnsatisfiable);
    });

    test('progress on an unknown run is an error', () async {
      expect(() => build().progress('nope'), refused('celm.run_not_found'));
    });
  });
}
