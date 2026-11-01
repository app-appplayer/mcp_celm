import 'dart:async';

import 'package:mcp_celm/mcp_celm.dart';
import 'package:test/test.dart';

import 'fixtures/fixtures.dart';

/// TEST-PLAN §13 (gate time limit, context) and §7 (observation check).
class _Contextual implements CelmContextualInterlock {
  _Contextual(this.answer);
  bool answer;
  CelmGateRequest? seen;
  int plain = 0;
  @override
  Future<bool> check(CelmGateRequest request) async {
    seen = request;
    return answer;
  }

  @override
  Future<bool> satisfied(CelmAction action, CelmObservation state) async {
    plain++;
    return answer;
  }
}

class _Silent implements CelmInterlockPort {
  @override
  Future<bool> satisfied(CelmAction action, CelmObservation state) =>
      Completer<bool>().future;
}

class _Caller implements McpToolCaller {
  _Caller(this.reply);
  Map<String, dynamic> reply;
  Map<String, dynamic>? args;
  @override
  Future<Map<String, dynamic>> call(
      String server, String tool, Map<String, dynamic> args) async {
    this.args = args;
    return reply;
  }
}

void main() {
  const path = {'path': '/tmp/x.txt'};

  CelmPortAdapter gated(CelmInterlockPort interlock, RecordingActuator hidA,
          {Map<String, dynamic>? policy, DateTime Function()? now}) =>
      build(
        manifest: manifestJson(policy: policy),
        actuators: {'hid': hidA, 'scpi': scpi()},
        interlock: interlock,
        now: now,
        perception: perceptionAfterActs(hidA,
            before: desktopOpen(),
            after: {...desktopOpen(), 'deleted': cell(true)}),
      );

  group('§13 gate time limit', () {
    test('an interlock that never answers escalates; actuator not called',
        () async {
      final a = hid();
      final port = gated(_Silent(), a, policy: {'gate_timeout_ms': 50});
      final o = await run(port, 'delete_document', params: path)
          .timeout(const Duration(seconds: 5));
      final e = o as CelmEscalated;
      expect(e.reason, CelmEscalationReason.irreversibleGate);
      expect(a.actions, isEmpty);
    });

    test('default is 60000 ms; zero or negative is rejected', () {
      expect(build().manifest.policy.gateTimeout,
          const Duration(milliseconds: 60000));
      for (final v in [0, -1]) {
        expect(
            () => build(manifest: manifestJson(policy: {'gate_timeout_ms': v})),
            throwsA(isA<AnalysisError>()
                .having((e) => e.code, 'code', 'manifest.bad_policy')));
      }
    });

    test('a plain interlock gates exactly as before', () async {
      final a = hid();
      final i = ScriptedInterlock(true);
      final o = await run(gated(i, a), 'delete_document', params: path);
      expect(o, isA<CelmCompleted>());
      expect(i.asked, 1);
    });
  });

  group('§13 gate context', () {
    test('a contextual interlock receives run, goal, step, skill, params',
        () async {
      final a = hid();
      final i = _Contextual(true);
      final t0 = DateTime.utc(2026, 10, 25, 9);
      final port = gated(i, a,
          policy: {'gate_timeout_ms': 5000}, now: () => t0);
      final o = await run(port, 'delete_document', params: path);
      expect(o, isA<CelmCompleted>());
      final r = i.seen!;
      expect(r.runId, startsWith('run-'));
      expect(r.goal, 'delete_document');
      expect(r.step, isNotEmpty);
      expect(r.skill, isNotEmpty);
      expect(r.params, isNotNull);
      expect(r.timeout, const Duration(milliseconds: 5000));
      expect(r.deadline, t0.add(const Duration(milliseconds: 5000)));
      expect(i.plain, 0);
    });

    test('the MCP adapter keeps its arguments and adds the new ones',
        () async {
      final caller = _Caller({'satisfied': true});
      final adapter =
          McpInterlockAdapter(caller: caller, server: 's', tool: 't');
      final state = obs(desktopOpen());
      final t = DateTime.utc(2026, 10, 25, 9, 0, 5);
      final ok = await adapter.check(CelmGateRequest(
        action: const CelmAction(
            actuator: 'hid', verb: 'key', args: {'combo': 'Del'}),
        state: state,
        runId: 'run-7',
        goal: 'g',
        step: 's1',
        skill: 'sk',
        params: const {'p': 1},
        timeout: const Duration(seconds: 5),
        deadline: t,
      ));
      expect(ok, isTrue);
      final a = caller.args!;
      expect(a['action'], {
        'port': 'hid.key',
        'args': {'combo': 'Del'}
      });
      expect(a['at'], state.at.toIso8601String());
      expect(a['context'], {
        'runId': 'run-7',
        'goal': 'g',
        'step': 's1',
        'skill': 'sk',
        'params': {'p': 1}
      });
      expect(a['timeoutMs'], 5000);
      expect(a['deadline'], t.toIso8601String());
    });

    test('only satisfied:true opens', () async {
      for (final reply in <Map<String, dynamic>>[
        {'satisfied': false},
        {'satisfied': 'true'},
        {},
      ]) {
        final adapter = McpInterlockAdapter(
            caller: _Caller(reply), server: 's', tool: 't');
        expect(
            await adapter.satisfied(
                const CelmAction(actuator: 'hid', verb: 'key'),
                obs(desktopOpen())),
            isFalse);
      }
    });
  });

  group('§7 validateObservationJson', () {
    Map<String, dynamic> good() => {
          'descriptor': {
            'a': {'value': 1, 'quality': 0.9}
          },
          'coverage': [
            {'scope': 'a', 'depth': 'atoms'}
          ],
          'at': '2026-10-25T09:00:00Z',
        };
    List<String> codes(Object? j) =>
        [for (final i in validateObservationJson(j)) i.code];

    test('a conforming answer has no issues', () {
      expect(validateObservationJson(good()), isEmpty);
    });

    test('each departure is named', () {
      expect(codes('x'), ['observation.not_object']);
      expect(codes({...good(), 'descriptor': 3}), ['descriptor.missing']);
      expect(codes({...good()}..remove('coverage')), ['coverage.missing']);
      expect(codes({...good(), 'coverage': <Object>[]}), ['coverage.empty']);
      expect(codes({...good(), 'coverage': [3]}), ['coverage.bad_entry']);
      expect(
          codes({
            ...good(),
            'coverage': [
              {'scope': 'a..b', 'depth': 'atoms'}
            ]
          }),
          ['coverage.bad_scope']);
      expect(
          codes({
            ...good(),
            'coverage': [
              {'scope': 'a', 'depth': 'atom'}
            ]
          }),
          ['coverage.bad_depth']);
      expect(codes({...good()}..remove('at')), ['at.missing']);
      expect(codes({...good(), 'at': 'yesterday'}), ['at.bad_instant']);
      expect(
          codes({
            ...good(),
            'descriptor': {
              'a': {'value': 1, 'quality': 1.5}
            }
          }),
          ['quality.out_of_range']);
      expect(
          codes({
            ...good(),
            'descriptor': {'a': 1}
          }),
          ['leaf.no_quality']);
    });

    test('issues carry a path and a severity, and encode to JSON', () {
      final i = validateObservationJson({
        ...good(),
        'coverage': [
          {'scope': 'a', 'depth': 'atom'}
        ]
      }).single;
      expect(i.path, 'coverage[0].depth');
      expect(i.severity, 'error');
      expect(i.toJson()['code'], 'coverage.bad_depth');
    });

    test('an answer that conforms is read by the adapter as given', () async {
      final adapter = McpPerceptionAdapter(
          caller: _Caller(good()), server: 's', tool: 't');
      final o = await adapter.observe(const CelmObserveRequest());
      expect(o.coverage.single.scope, 'a');
      expect(o.at, DateTime.utc(2026, 10, 25, 9));
    });
  });
}
