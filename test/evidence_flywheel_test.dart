import 'package:mcp_bundle/ports.dart' show InMemoryKvStoragePort;
import 'package:mcp_celm/mcp_celm.dart';
import 'package:test/test.dart';

import 'fixtures/fixtures.dart';

/// TEST-PLAN §10 (evidence) and §11 (the flywheel).
void main() {
  Matcher refused(String code) =>
      throwsA(isA<AnalysisError>().having((e) => e.code, 'code', code));

  const path = {'path': '/tmp/notes.txt'};

  group('§10 evidence', () {
    test('every conclusion is observed or judged, with inputs and premises',
        () async {
      final port = build(perception: desktopWithPanel(color2: 'red'));
      final o = await run(port, 'read_panel_status') as CelmCompleted;
      expect(o.conclusions, isNotEmpty);
      for (final c in o.conclusions) {
        switch (c) {
          case ObservedConclusion(:final inputs):
            expect(inputs, isNotEmpty, reason: c.statement);
          case JudgedConclusion(:final premises, :final reasoner):
            expect(premises, isNotEmpty);
            expect(reasoner, isNotEmpty);
        }
      }
    });

    test('standalone returns observations only', () async {
      final port = build(perception: desktopWithPanel(color2: 'red'));
      final o = await run(port, 'read_panel_status');
      final s = await port.standalone(o.runId);
      expect(s, isNotEmpty);
      expect(s.every((c) => c is ObservedConclusion), isTrue);
      expect((await port.progress(o.runId)).outcome, isA<CelmCompleted>());
      final all = ((await port.progress(o.runId)).outcome! as CelmCompleted)
          .conclusions;
      expect(all.whereType<JudgedConclusion>(), isNotEmpty,
          reason: 'there was a judgment to filter out');
    });

    test('explain walks premises to observations; the chain reaches ground',
        () async {
      final port = build(perception: desktopWithPanel(color2: 'red'));
      final o = await run(port, 'read_panel_status') as CelmCompleted;
      final j = o.conclusions.whereType<JudgedConclusion>().single;
      final e = await port.explain(j.id);
      expect(e.conclusion.id, j.id);
      expect(e.chain, isNotEmpty);
      expect(e.chain.every((c) => c is ObservedConclusion), isTrue);
      expect(e.chain.map((c) => c.id), containsAll(j.premises));
      // Judgment premises are the fields it read, as measured facts.
      expect(e.chain.map((c) => (c as ObservedConclusion).inputs.single.field),
          contains('panel.indicators[2].color'));
    });

    test('explain of an unknown conclusion is an error', () async {
      expect(
          () => build().explain('nope'), refused('celm.conclusion_not_found'));
    });

    test(
        'append precedes advance: a run stopped mid-step leaves the ledger at the last completed step',
        () async {
      final store = InMemoryCelmStore();
      final actuator = hid(delay: const Duration(milliseconds: 100));
      final port = build(
        store: store,
        perception: perceptionAfterActs(actuator,
            before: desktopEmpty(), after: desktopOpen()),
        actuators: {'hid': actuator, 'scpi': scpi()},
      );
      final h = await port
          .execute(const CelmGoalRef(id: 'open_document', params: path));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final o = await port.cancel(h.runId);
      expect(o, isA<CelmCancelled>());
      final conclusions = await store.conclusions.getAll();
      // The first step's precondition (open: not focused) was recorded;
      // nothing claims a step that had not completed.
      expect(conclusions, isNotEmpty);
      expect(
          conclusions.every((c) =>
              c.statement.contains('open:') || c.statement.contains('focus:')),
          isTrue);
      final state = await store.runs.get(h.runId);
      expect(state!.history.where((a) => a.result == 'pass'), isEmpty);
    });

    test(
        'provenance survives the store: a judged record cannot come back as an observation',
        () async {
      final kv = InMemoryKvStoragePort();
      final store = KvCelmStore(kv);
      final port =
          build(store: store, perception: desktopWithPanel(color2: 'red'));
      final o = await run(port, 'read_panel_status') as CelmCompleted;
      final j = o.conclusions.whereType<JudgedConclusion>().single;
      final back = await store.conclusions.get(j.id);
      expect(back, isA<JudgedConclusion>());
      final raw = Map<String, dynamic>.from(
          await kv.get('celm/conclusion/${j.id}') as Map);
      expect(() => ObservedConclusion.fromJson(raw),
          refused('celm.provenance_mismatch'));
      raw.remove('provenance');
      expect(() => CelmConclusion.fromJson(raw), refused('celm.missing_field'));
    });

    test('a kv-backed store round-trips run state and examples too', () async {
      final kv = InMemoryKvStoragePort();
      final store = KvCelmStore(kv);
      final flow = openFlow();
      final port = build(
        store: store,
        manifest: manifestJson(reasoner: {'kind': 'llm'}),
        reasoner: constantReasoner(true, 0.1),
        perception: flow.perception,
        actuators: {'hid': flow.actuator, 'scpi': scpi()},
      );
      final o = await run(port, 'open_document', params: path);
      expect(o, isA<CelmEscalated>());
      await port.resume(o.runId, const Abandon('operator declined'));
      final state = await store.runs.get(o.runId);
      expect(state!.outcome, isA<CelmCancelled>());
      final ex = await store.examples.getAll();
      expect(ex.single.resolution, isA<Abandon>());
      expect(ex.single.runId, o.runId);
    });
  });

  group('§11 the flywheel', () {
    test('a resolved escalation writes (state, question, resolution, resolver)',
        () async {
      final store = InMemoryCelmStore();
      var answer = 0.1;
      final flow = openFlow();
      final port = build(
        store: store,
        manifest: manifestJson(reasoner: {'kind': 'llm'}),
        reasoner: ScriptedReasoner(
            (r, i) => CelmJudgment(verdict: true, confidence: answer)),
        perception: ScriptedPerception((r, i) => obsFor(
            r,
            flow.actuator.actions.length >= 3
                ? desktopOpen(
                    title: 'notes.txt.${flow.actuator.actions.length}')
                : desktopOpen(title: 'blank'))),
        actuators: {'hid': flow.actuator, 'scpi': scpi()},
      );
      final o = await run(port, 'open_document', params: path);
      expect(o, isA<CelmEscalated>());
      answer = 0.95;
      final r = await port.resume(o.runId, const ResumeAt('open'),
          actor: const AnalysisActor(id: 'alice', role: 'operator'));
      expect(r, isA<CelmCompleted>());
      final ex = (await store.examples.getAll()).single;
      expect(ex.question, 'Did the document open in a usable state?');
      expect(ex.state.relevant.map((f) => f.field), ['window.frontmost']);
      expect(ex.state.toJson().containsKey('descriptor'), isFalse,
          reason: 'the example carries the digest, not a screen');
      expect(ex.resolution, isA<ResumeAt>());
      expect(ex.resolver, 'alice');
      expect(ex.runId, o.runId);
    });

    test('abandonment produces a labelled negative', () async {
      final store = InMemoryCelmStore();
      final flow = openFlow();
      final port = build(
        store: store,
        manifest: manifestJson(reasoner: {'kind': 'llm'}),
        reasoner: constantReasoner(true, 0.1),
        perception: flow.perception,
        actuators: {'hid': flow.actuator, 'scpi': scpi()},
      );
      final o = await run(port, 'open_document', params: path);
      final r = await port.resume(o.runId, const Abandon('not worth it'));
      expect(r, isA<CelmCancelled>());
      final ex = (await store.examples.getAll()).single;
      expect((ex.resolution as Abandon).why, 'not worth it');
    });

    test('example and conclusions share the run id', () async {
      final store = InMemoryCelmStore();
      final flow = openFlow();
      final port = build(
        store: store,
        manifest: manifestJson(reasoner: {'kind': 'llm'}),
        reasoner: constantReasoner(true, 0.1),
        perception: flow.perception,
        actuators: {'hid': flow.actuator, 'scpi': scpi()},
      );
      final o = await run(port, 'open_document', params: path);
      await port.resume(o.runId, const Abandon('x'));
      final ex = (await store.examples.getAll()).single;
      final cs = await store.conclusions.query({'runId': o.runId});
      expect(cs.map((c) => c.runId).toSet(), {ex.runId});
    });

    test(
        'no cold start: a pack with zero examples runs on llm and produces them',
        () async {
      final store = InMemoryCelmStore();
      expect(await store.examples.getAll(), isEmpty);
      final flow = openFlow();
      final port = build(
        store: store,
        manifest: manifestJson(reasoner: {'kind': 'llm'}),
        reasoner: LlmReasoner(
            id: 'planner',
            ask: (r) async =>
                const CelmJudgment(verdict: true, confidence: 0.1)),
        perception: flow.perception,
        actuators: {'hid': flow.actuator, 'scpi': scpi()},
      );
      final o = await run(port, 'open_document', params: path);
      await port.resume(o.runId, const Abandon('x'));
      expect(await store.examples.getAll(), hasLength(1));
      final j = (await store.conclusions.getAll())
          .whereType<JudgedConclusion>()
          .first;
      expect(j.reasonerRemote, isTrue,
          reason: 'the bootstrap is labelled as one');
    });
  });
}
