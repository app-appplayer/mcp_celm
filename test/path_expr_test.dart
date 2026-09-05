import 'package:mcp_celm/mcp_celm.dart';
import 'package:test/test.dart';

import 'fixtures/fixtures.dart';

/// SDD §3.3 and core-evaluator §4: paths are total, coverage is a prefix
/// test, and the expression language evaluates without executing code.
void main() {
  group('paths (SDD §3.3)', () {
    test('parse every form', () {
      expect(CelmPath.parse('window.title').toString(), 'window.title');
      expect(CelmPath.parse('panel.indicators[2].color').toString(),
          'panel.indicators[2].color');
      expect(CelmPath.parse('panel.indicators[*].voltage').toString(),
          'panel.indicators[*].voltage');
      expect(CelmPath.parse('screen').isRoot, isTrue);
      expect(CelmPath.parse('').isRoot, isTrue);
    });

    test('refuse anything outside the form', () {
      for (final bad in [
        'a..b',
        'a[',
        'a[-1]',
        'a[x]',
        '.a',
        'a.',
        'a b',
        'a[1',
        'a[1]b'
      ]) {
        expect(
            () => CelmPath.parse(bad),
            throwsA(isA<AnalysisError>()
                .having((e) => e.code, 'code', 'celm.bad_path')),
            reason: bad);
      }
    });

    test('a path is total: resolves to absence, never an error', () {
      for (final p in ['a', 'a.b.c', 'a[3]', 'a[*].b', 'x[*]']) {
        final v = CelmFieldValue.resolve(const {}, CelmPath.parse(p));
        expect(v.present, isFalse, reason: p);
      }
    });

    test('cells carry quality; raw leaves have none', () {
      final d = {'a': cell(1, 0.7), 'b': 2};
      expect(CelmFieldValue.resolve(d, CelmPath.parse('a')).quality, 0.7);
      expect(CelmFieldValue.resolve(d, CelmPath.parse('b')).quality, isNull);
      expect(CelmFieldValue.resolve(d, CelmPath.parse('b')).value, 2);
    });

    test('wildcard yields the elements', () {
      final v = CelmFieldValue.resolve(
          panel(), CelmPath.parse('panel.indicators[*].color'));
      expect(v.value, ['green', 'green', 'green']);
    });

    test('coverage scope is a prefix', () {
      final m = CelmCoverageMatcher(
          const [CelmCoverage(scope: 'window[3]', depth: CelmDepth.atoms)]);
      final d = {
        'window': [
          <String, dynamic>{},
          <String, dynamic>{},
          <String, dynamic>{},
          <String, dynamic>{}
        ]
      };
      expect(
          m.covers(d, CelmPath.parse('window[3].title'), CelmDepth.structure),
          isTrue);
      expect(
          m.covers(d, CelmPath.parse('window[2].title'), CelmDepth.structure),
          isFalse);
    });

    test('depth must satisfy', () {
      final m = CelmCoverageMatcher(
          const [CelmCoverage(scope: 'screen', depth: CelmDepth.structure)]);
      expect(
          m.covers(const {}, CelmPath.parse('x'), CelmDepth.structure), isTrue);
      expect(m.covers(const {}, CelmPath.parse('x'), CelmDepth.atoms), isFalse);
    });

    test('wildcard needs every element covered', () {
      final m = CelmCoverageMatcher(const [
        CelmCoverage(scope: 'panel.indicators[2]', depth: CelmDepth.atoms)
      ]);
      expect(
          m.covers(panel(), CelmPath.parse('panel.indicators[*].state'),
              CelmDepth.atoms),
          isFalse);
      final all = CelmCoverageMatcher(const [
        CelmCoverage(scope: 'panel.indicators', depth: CelmDepth.atoms)
      ]);
      expect(
          all.covers(panel(), CelmPath.parse('panel.indicators[*].state'),
              CelmDepth.atoms),
          isTrue);
    });
  });

  group('expressions (core-evaluator §4)', () {
    Object? ev(String src, Map<String, dynamic> d,
            [Map<String, dynamic> p = const {}]) =>
        CelmExpr.parse(src).evaluate(d, p).value;

    test('the SDD examples', () {
      expect(ev("panel.mode == 'run'", panel()), isTrue);
      expect(ev('panel.indicators.count >= 1', panel()), isTrue);
      expect(ev('panel.indicators.all(has(state))', panel()), isTrue);
      expect(
          ev(r'window.frontmost.title contains basename($path)', desktopOpen(),
              {'path': '/tmp/notes.txt'}),
          isTrue);
      expect(ev('app.focused == true', desktopEmpty()), isFalse);
    });

    test('comparison, membership, boolean, helpers', () {
      final d = {
        'n': 3,
        's': 'hello',
        'l': [1, 2, 3],
        'm': cell(2.5)
      };
      expect(ev('n > 2 and n < 4', d), isTrue);
      expect(ev('n != 3 or s == "hello"', d), isTrue);
      expect(ev('not (n == 3)', d), isFalse);
      expect(ev("s contains 'ell'", d), isTrue);
      expect(ev('2 in l', d), isTrue);
      expect(ev('len(s) == 5', d), isTrue);
      expect(ev('abs(m) > 2', d), isTrue);
      expect(ev('l.any(true)', d), isTrue);
    });

    test('total: type mismatch is false, absence is null, never a throw', () {
      expect(ev("n > 'x'", {'n': 1}), isFalse);
      expect(ev('missing == null', const {}), isTrue);
      expect(ev('missing.count > 0', const {}), isFalse);
      expect(ev('missing.all(true)', const {}), isFalse);
      expect(ev('basename(n) == 1', {'n': 1}), isFalse);
    });

    test('reads are collected, quantified ones relative to the list', () {
      final e = CelmExpr.parse(
          'panel.indicators.all(state == "ok") and panel.mode == "run"');
      expect(
          e.reads.map((p) => p.toString()),
          containsAll(
              ['panel.indicators', 'panel.indicators[*].state', 'panel.mode']));
      final r = e.evaluate(panel(), const {});
      expect(r.reads.map((x) => x.path.toString()),
          contains('panel.indicators[0].state'));
    });

    test('rejects what the grammar does not have', () {
      for (final bad in [
        'a +',
        'a == ',
        'foo(a)',
        'a.b(',
        '(a',
        'a and',
        'a = 1',
        '"unterminated'
      ]) {
        expect(
            () => CelmExpr.parse(bad),
            throwsA(isA<AnalysisError>()
                .having((e) => e.code, 'code', 'celm.bad_expression')),
            reason: bad);
      }
    });
  });
}
