/// The postcondition expression language (SDD §3.3, `core-evaluator` §4).
///
/// Small on purpose, and total: it evaluates without executing arbitrary
/// code — a pack is data — and no expression can fail at run time. A type
/// mismatch is `false`; an absent field is absence, which the evaluator
/// turns into `observed(false)` or `unobservable` by the coverage rules.
///
/// ```
/// expr       := or
/// or         := and ('or' and)*
/// and        := unary ('and' unary)*
/// unary      := 'not' unary | comparison
/// comparison := operand (cmpop operand)?
/// cmpop      := '==' | '!=' | '<' | '<=' | '>' | '>=' | 'contains' | 'in'
/// operand    := literal | param | call | pathexpr | '(' expr ')'
/// literal    := number | string | true | false | null
/// param      := '$' ident ('.' key | '[' index ']')*
/// call       := ('basename' | 'abs' | 'len' | 'has') '(' expr ')'
/// pathexpr   := path ('.count' | '.all(' expr ')' | '.any(' expr ')')?
/// path       := key ( '.' key | '[' (int | '*') ']' )*
/// ```
///
/// Inside `all(...)` / `any(...)` the expression is evaluated with each
/// element as the root, so `panel.indicators.all(has(state))` reads
/// `state` of every indicator.
library;

import 'package:mcp_bundle/ports.dart';

import 'path.dart';

/// One field the expression read while evaluating.
class CelmRead {
  const CelmRead(this.path, this.value);
  final CelmPath path;
  final CelmFieldValue value;
}

/// A parsed expression.
class CelmExpr {
  const CelmExpr._(this._root, this.reads);
  final _Node _root;

  /// Every field path the expression can read, statically — for the
  /// digest, the fingerprint and reference attachment. Paths under a
  /// quantifier are reported relative to the quantified list.
  final List<CelmPath> reads;

  /// Parses [source]. Refuses anything outside the grammar with
  /// `celm.bad_expression`.
  static CelmExpr parse(String source) {
    final p = _Parser(_tokenize(source), source);
    final node = p.parseExpr();
    if (!p.atEnd) p.fail('unexpected "${p.peek.text}"');
    final reads = <CelmPath>[];
    node.collectReads(CelmPath.root, reads);
    return CelmExpr._(node, reads);
  }

  /// Evaluates over [descriptor] with [params]. Total: never throws.
  CelmExprResult evaluate(
    Map<String, dynamic> descriptor,
    Map<String, dynamic> params,
  ) {
    final ctx = _Ctx(descriptor, params, CelmPath.root, []);
    final v = _root.eval(ctx);
    return CelmExprResult(v, ctx.reads);
  }
}

/// A value and the fields read to produce it.
class CelmExprResult {
  const CelmExprResult(this.value, this.reads);
  final Object? value;
  final List<CelmRead> reads;

  /// The expression as a predicate: `true` only for the boolean true.
  bool get holds => value == true;
}

// ---------------------------------------------------------------------------
// Lexer
// ---------------------------------------------------------------------------

enum _T { ident, number, string, op, lparen, rparen, dollar, dot, end }

class _Tok {
  const _Tok(this.type, this.text, this.at);
  final _T type;
  final String text;
  final int at;
}

const _ops = ['==', '!=', '<=', '>=', '<', '>', '[', ']'];

List<_Tok> _tokenize(String s) {
  final out = <_Tok>[];
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      i++;
      continue;
    }
    if (c == '(') {
      out.add(_Tok(_T.lparen, c, i++));
      continue;
    }
    if (c == ')') {
      out.add(_Tok(_T.rparen, c, i++));
      continue;
    }
    if (c == r'$') {
      out.add(_Tok(_T.dollar, c, i++));
      continue;
    }
    if (c == '.') {
      out.add(_Tok(_T.dot, c, i++));
      continue;
    }
    if (c == '"' || c == "'") {
      final close = s.indexOf(c, i + 1);
      if (close < 0) _lexFail(s, i, 'unterminated string');
      out.add(_Tok(_T.string, s.substring(i + 1, close), i));
      i = close + 1;
      continue;
    }
    if (_isDigit(c) || (c == '-' && i + 1 < s.length && _isDigit(s[i + 1]))) {
      final start = i;
      i++;
      while (i < s.length && (_isDigit(s[i]) || s[i] == '.')) {
        i++;
      }
      out.add(_Tok(_T.number, s.substring(start, i), start));
      continue;
    }
    if (_isIdentStart(c)) {
      final start = i;
      while (i < s.length && _isIdentChar(s[i])) {
        i++;
      }
      out.add(_Tok(_T.ident, s.substring(start, i), start));
      continue;
    }
    var matched = false;
    for (final op in _ops) {
      if (s.startsWith(op, i)) {
        out.add(_Tok(_T.op, op, i));
        i += op.length;
        matched = true;
        break;
      }
    }
    if (!matched) _lexFail(s, i, 'unexpected "$c"');
  }
  out.add(_Tok(_T.end, '', s.length));
  return out;
}

bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;
bool _isIdentStart(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 0x41 && u <= 0x5a) || (u >= 0x61 && u <= 0x7a) || c == '_';
}

bool _isIdentChar(String c) => _isIdentStart(c) || _isDigit(c) || c == '-';

Never _lexFail(String s, int at, String why) => throw AnalysisError(
      code: 'celm.bad_expression',
      message: 'Bad expression at $at: $why',
      details: {'expression': s, 'at': at, 'why': why},
    );

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

const _keywords = {
  'and',
  'or',
  'not',
  'contains',
  'in',
  'true',
  'false',
  'null',
};
const _calls = {'basename', 'abs', 'len', 'has'};

class _Parser {
  _Parser(this.toks, this.source);
  final List<_Tok> toks;
  final String source;
  int pos = 0;

  _Tok get peek => toks[pos];
  bool get atEnd => peek.type == _T.end;
  _Tok next() => toks[pos++];

  Never fail(String why) => throw AnalysisError(
        code: 'celm.bad_expression',
        message: 'Bad expression at ${peek.at}: $why',
        details: {'expression': source, 'at': peek.at, 'why': why},
      );

  bool isIdent(String word) => peek.type == _T.ident && peek.text == word;

  void expect(_T t, String text) {
    if (peek.type != t || peek.text != text) fail('expected "$text"');
    next();
  }

  _Node parseExpr() {
    var left = parseAnd();
    while (isIdent('or')) {
      next();
      left = _Or(left, parseAnd());
    }
    return left;
  }

  _Node parseAnd() {
    var left = parseUnary();
    while (isIdent('and')) {
      next();
      left = _And(left, parseUnary());
    }
    return left;
  }

  _Node parseUnary() {
    if (isIdent('not')) {
      next();
      return _Not(parseUnary());
    }
    return parseComparison();
  }

  _Node parseComparison() {
    final left = parseOperand();
    if (peek.type == _T.op && !['[', ']'].contains(peek.text)) {
      final op = next().text;
      return _Cmp(op, left, parseOperand());
    }
    if (isIdent('contains') || isIdent('in')) {
      final op = next().text;
      return _Cmp(op, left, parseOperand());
    }
    return left;
  }

  _Node parseOperand() {
    final t = peek;
    switch (t.type) {
      case _T.lparen:
        next();
        final e = parseExpr();
        expect(_T.rparen, ')');
        return e;
      case _T.number:
        next();
        final n = num.tryParse(t.text);
        if (n == null) fail('bad number "${t.text}"');
        return _Lit(n);
      case _T.string:
        next();
        return _Lit(t.text);
      case _T.dollar:
        next();
        if (peek.type != _T.ident) fail(r'expected a name after $');
        final name = next().text;
        return _Param(name, parseTrailingPath());
      case _T.ident:
        if (t.text == 'true' || t.text == 'false') {
          next();
          return _Lit(t.text == 'true');
        }
        if (t.text == 'null') {
          next();
          return const _Lit(null);
        }
        if (_calls.contains(t.text) &&
            pos + 1 < toks.length &&
            toks[pos + 1].type == _T.lparen) {
          next();
          next();
          final arg = t.text == 'has' ? _PathNode(parsePath()) : parseExpr();
          expect(_T.rparen, ')');
          return _Call(t.text, arg);
        }
        if (_keywords.contains(t.text)) fail('unexpected "${t.text}"');
        return parsePathExpr();
      default:
        fail('unexpected "${t.text}"');
    }
  }

  /// `.key` and `[i]` after a parameter.
  List<CelmPathSegment> parseTrailingPath() {
    final segs = <CelmPathSegment>[];
    while (true) {
      if (peek.type == _T.dot &&
          pos + 1 < toks.length &&
          toks[pos + 1].type == _T.ident &&
          !_isQuantifier(toks[pos + 1].text)) {
        next();
        segs.add(KeySegment(next().text));
        continue;
      }
      if (peek.type == _T.op && peek.text == '[') {
        segs.add(parseIndex());
        continue;
      }
      return segs;
    }
  }

  bool _isQuantifier(String word) =>
      (word == 'count' || word == 'all' || word == 'any') &&
      pos + 2 < toks.length &&
      (word == 'count' || toks[pos + 2].type == _T.lparen);

  CelmPathSegment parseIndex() {
    expect(_T.op, '[');
    if (peek.type == _T.op && peek.text != ']') fail('bad index');
    final t = next();
    CelmPathSegment seg;
    if (t.text == '*') {
      seg = const WildcardSegment();
    } else if (t.type == _T.ident && t.text == '*') {
      seg = const WildcardSegment();
    } else {
      final n = int.tryParse(t.text);
      if (n == null || n < 0) fail('bad index "${t.text}"');
      seg = IndexSegment(n);
    }
    expect(_T.op, ']');
    return seg;
  }

  CelmPath parsePath() {
    if (peek.type != _T.ident || _keywords.contains(peek.text)) {
      fail('expected a field');
    }
    final segs = <CelmPathSegment>[KeySegment(next().text)];
    segs.addAll(parseTrailingPath());
    return CelmPath(segs);
  }

  _Node parsePathExpr() {
    final path = parsePath();
    if (peek.type == _T.dot && pos + 1 < toks.length) {
      final word = toks[pos + 1].text;
      if (word == 'count') {
        next();
        next();
        return _Count(path);
      }
      if ((word == 'all' || word == 'any') &&
          pos + 2 < toks.length &&
          toks[pos + 2].type == _T.lparen) {
        next();
        next();
        next();
        final body = parseExpr();
        expect(_T.rparen, ')');
        return _Quant(path, word == 'all', body);
      }
    }
    return _PathNode(path);
  }
}

// ---------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------

class _Ctx {
  const _Ctx(this.descriptor, this.params, this.base, this.reads,
      [this.element]);
  final Map<String, dynamic> descriptor;
  final Map<String, dynamic> params;
  final CelmPath base;
  final List<CelmRead> reads;
  final Object? element;

  CelmFieldValue read(CelmPath rel) {
    final full = CelmPath([...base.segments, ...rel.segments]);
    final v = element == null
        ? CelmFieldValue.resolve(descriptor, full)
        : _resolveIn(element, rel, full);
    reads.add(CelmRead(full, v));
    return v;
  }

  static CelmFieldValue _resolveIn(Object? el, CelmPath rel, CelmPath full) {
    if (el is Map<String, dynamic>) {
      final v = CelmFieldValue.resolve(el, rel);
      return CelmFieldValue(
        path: full,
        present: v.present,
        value: v.value,
        quality: v.quality,
      );
    }
    return CelmFieldValue(path: full, present: false);
  }
}

abstract class _Node {
  const _Node();
  Object? eval(_Ctx c);
  void collectReads(CelmPath base, List<CelmPath> out) {}
}

class _Lit extends _Node {
  const _Lit(this.value);
  final Object? value;
  @override
  Object? eval(_Ctx c) => value;
}

class _Param extends _Node {
  const _Param(this.name, this.path);
  final String name;
  final List<CelmPathSegment> path;
  @override
  Object? eval(_Ctx c) {
    if (!c.params.containsKey(name)) return null;
    if (path.isEmpty) return c.params[name];
    final v = CelmFieldValue.resolve(
        {name: c.params[name]}, CelmPath([KeySegment(name), ...path]));
    return v.present ? v.value : null;
  }
}

class _PathNode extends _Node {
  const _PathNode(this.path);
  final CelmPath path;
  @override
  Object? eval(_Ctx c) {
    final v = c.read(path);
    return v.present ? v.value : null;
  }

  @override
  void collectReads(CelmPath base, List<CelmPath> out) =>
      out.add(CelmPath([...base.segments, ...path.segments]));
}

class _Count extends _Node {
  const _Count(this.path);
  final CelmPath path;
  @override
  Object? eval(_Ctx c) {
    final v = c.read(path);
    if (!v.present) return null;
    final x = v.value;
    if (x is List) return x.length;
    if (x is Map) return x.length;
    if (x is String) return x.length;
    return null;
  }

  @override
  void collectReads(CelmPath base, List<CelmPath> out) =>
      out.add(CelmPath([...base.segments, ...path.segments]));
}

class _Quant extends _Node {
  const _Quant(this.path, this.all, this.body);
  final CelmPath path;
  final bool all;
  final _Node body;
  @override
  Object? eval(_Ctx c) {
    final v = c.read(path);
    if (!v.present || v.value is! List) return false;
    final list = v.value as List;
    final listPath = CelmPath([...c.base.segments, ...path.segments]);
    for (var i = 0; i < list.length; i++) {
      final sub = _Ctx(
        c.descriptor,
        c.params,
        listPath.append(IndexSegment(i)),
        c.reads,
        list[i] is Map<String, dynamic> ? list[i] : <String, dynamic>{},
      );
      final r = body.eval(sub) == true;
      if (all && !r) return false;
      if (!all && r) return true;
    }
    return all;
  }

  @override
  void collectReads(CelmPath base, List<CelmPath> out) {
    final listPath = CelmPath([...base.segments, ...path.segments]);
    out.add(listPath);
    body.collectReads(listPath.append(const WildcardSegment()), out);
  }
}

class _Call extends _Node {
  const _Call(this.fn, this.arg);
  final String fn;
  final _Node arg;
  @override
  Object? eval(_Ctx c) {
    switch (fn) {
      case 'has':
        final p = (arg as _PathNode).path;
        return c.read(p).present;
      case 'basename':
        final v = arg.eval(c);
        if (v is! String) return null;
        final i = v.lastIndexOf('/');
        return i < 0 ? v : v.substring(i + 1);
      case 'abs':
        final v = arg.eval(c);
        return v is num ? v.abs() : null;
      case 'len':
        final v = arg.eval(c);
        if (v is String) return v.length;
        if (v is List) return v.length;
        if (v is Map) return v.length;
        return null;
    }
    return null;
  }

  @override
  void collectReads(CelmPath base, List<CelmPath> out) =>
      arg.collectReads(base, out);
}

class _Not extends _Node {
  const _Not(this.inner);
  final _Node inner;
  @override
  Object? eval(_Ctx c) => inner.eval(c) != true;
  @override
  void collectReads(CelmPath base, List<CelmPath> out) =>
      inner.collectReads(base, out);
}

class _And extends _Node {
  const _And(this.l, this.r);
  final _Node l, r;
  @override
  Object? eval(_Ctx c) => l.eval(c) == true && r.eval(c) == true;
  @override
  void collectReads(CelmPath base, List<CelmPath> out) {
    l.collectReads(base, out);
    r.collectReads(base, out);
  }
}

class _Or extends _Node {
  const _Or(this.l, this.r);
  final _Node l, r;
  @override
  Object? eval(_Ctx c) {
    final a = l.eval(c) == true;
    final b = r.eval(c) == true;
    return a || b;
  }

  @override
  void collectReads(CelmPath base, List<CelmPath> out) {
    l.collectReads(base, out);
    r.collectReads(base, out);
  }
}

class _Cmp extends _Node {
  const _Cmp(this.op, this.l, this.r);
  final String op;
  final _Node l, r;
  @override
  Object? eval(_Ctx c) {
    final a = l.eval(c);
    final b = r.eval(c);
    switch (op) {
      case '==':
        return _eq(a, b);
      case '!=':
        return !_eq(a, b);
      case 'contains':
        if (a is String && b is String) return a.contains(b);
        if (a is List) return a.any((e) => _eq(e, b));
        return false;
      case 'in':
        if (b is String && a is String) return b.contains(a);
        if (b is List) return b.any((e) => _eq(e, a));
        return false;
      default:
        if (a is! num || b is! num) return false;
        return switch (op) {
          '<' => a < b,
          '<=' => a <= b,
          '>' => a > b,
          '>=' => a >= b,
          _ => false,
        };
    }
  }

  static bool _eq(Object? a, Object? b) {
    if (a is num && b is num) return a == b;
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_eq(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  @override
  void collectReads(CelmPath base, List<CelmPath> out) {
    l.collectReads(base, out);
    r.collectReads(base, out);
  }
}
