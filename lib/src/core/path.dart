/// Field paths, and what a coverage scope covers (SDD §3.3).
///
/// Every module addresses the descriptor the same way — the evaluator to
/// resolve a field, the digest to name what a check read, the fingerprint
/// to hash it, a reference to say what it is about. A path is a total
/// function from a descriptor to a value, a set of values, or absence;
/// nothing it does depends on the descriptor's content.
library;

import 'package:mcp_bundle/ports.dart';

/// One step along a path.
sealed class CelmPathSegment {
  const CelmPathSegment();
}

/// A key of the object at the current level.
class KeySegment extends CelmPathSegment {
  const KeySegment(this.key);
  final String key;

  @override
  bool operator ==(Object other) => other is KeySegment && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => key;
}

/// One element of a list.
class IndexSegment extends CelmPathSegment {
  const IndexSegment(this.index);
  final int index;

  @override
  bool operator ==(Object other) =>
      other is IndexSegment && other.index == index;

  @override
  int get hashCode => index.hashCode;

  @override
  String toString() => '[$index]';
}

/// Every element of a list.
class WildcardSegment extends CelmPathSegment {
  const WildcardSegment();

  @override
  bool operator ==(Object other) => other is WildcardSegment;

  @override
  int get hashCode => 0x2a;

  @override
  String toString() => '[*]';
}

/// A parsed field path.
class CelmPath {
  const CelmPath(this.segments);
  final List<CelmPathSegment> segments;

  /// The root scope — a prefix of every path.
  static const root = CelmPath([]);

  /// Parses the form of SDD §3.3: `a.b[2].c[*]`. `screen` and the empty
  /// string denote the root. Refuses anything outside the form.
  static CelmPath parse(String text) {
    final s = text.trim();
    if (s.isEmpty || s == 'screen') return root;
    final segments = <CelmPathSegment>[];
    var i = 0;
    var expectKey = true;
    while (i < s.length) {
      final c = s[i];
      if (c == '.') {
        if (expectKey || i + 1 >= s.length) _bad(text, 'empty segment');
        expectKey = true;
        i++;
        continue;
      }
      if (c == '[') {
        final close = s.indexOf(']', i);
        if (close < 0) _bad(text, 'unclosed [');
        final inner = s.substring(i + 1, close).trim();
        if (inner == '*') {
          segments.add(const WildcardSegment());
        } else {
          final n = int.tryParse(inner);
          if (n == null || n < 0 || inner.startsWith('+')) {
            _bad(text, 'bad index "$inner"');
          }
          segments.add(IndexSegment(n));
        }
        expectKey = false;
        i = close + 1;
        continue;
      }
      if (!expectKey) _bad(text, 'expected "." or "[" at $i');
      final start = i;
      while (i < s.length && _isKeyChar(s[i])) {
        i++;
      }
      if (i == start) _bad(text, 'unexpected "${s[i]}" at $i');
      segments.add(KeySegment(s.substring(start, i)));
      expectKey = false;
    }
    if (expectKey) _bad(text, 'trailing "."');
    return CelmPath(segments);
  }

  static bool _isKeyChar(String c) {
    final code = c.codeUnitAt(0);
    return (code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x5a) ||
        (code >= 0x61 && code <= 0x7a) ||
        c == '_' ||
        c == '-';
  }

  static Never _bad(String text, String why) => throw AnalysisError(
        code: 'celm.bad_path',
        message: 'Bad field path "$text": $why',
        details: {'path': text, 'why': why},
      );

  bool get isRoot => segments.isEmpty;

  bool get hasWildcard => segments.any((s) => s is WildcardSegment);

  /// True when [this] is a prefix of [other] — the coverage test. The
  /// root is a prefix of everything. A wildcard in the prefix matches an
  /// index or a wildcard in the other; an index in the prefix matches
  /// only that index.
  bool isPrefixOf(CelmPath other) {
    if (segments.length > other.segments.length) return false;
    for (var i = 0; i < segments.length; i++) {
      final a = segments[i];
      final b = other.segments[i];
      if (a is WildcardSegment) {
        if (b is! IndexSegment && b is! WildcardSegment) return false;
        continue;
      }
      if (a != b) return false;
    }
    return true;
  }

  CelmPath append(CelmPathSegment segment) => CelmPath([...segments, segment]);

  @override
  String toString() {
    if (segments.isEmpty) return 'screen';
    final b = StringBuffer();
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      if (s is KeySegment) {
        if (i > 0) b.write('.');
        b.write(s.key);
      } else {
        b.write(s.toString());
      }
    }
    return b.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is CelmPath && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;
}

/// What one path resolved to, and how well it was seen.
///
/// A leaf in a descriptor may be a raw value or a *cell* —
/// `{ "value": v, "quality": q }` — which is how the perception layer
/// attaches a quality to a field. A leaf without a quality has none, and
/// is below every non-zero floor.
class CelmFieldValue {
  const CelmFieldValue({
    required this.path,
    required this.present,
    this.value,
    this.quality,
  });
  final CelmPath path;
  final bool present;
  final Object? value;
  final double? quality;

  static const _absentValue = Object();

  /// Resolves [path] in [descriptor]. A wildcard yields a list of the
  /// elements' values (present when the list exists, even if empty).
  static CelmFieldValue resolve(
    Map<String, dynamic> descriptor,
    CelmPath path,
  ) {
    final r = _walk(descriptor, path.segments, 0);
    if (identical(r, _absentValue)) {
      return CelmFieldValue(path: path, present: false);
    }
    if (r is _Cell) {
      return CelmFieldValue(
        path: path,
        present: true,
        value: r.value,
        quality: r.quality,
      );
    }
    return CelmFieldValue(path: path, present: true, value: r);
  }

  static Object? _walk(Object? node, List<CelmPathSegment> segs, int i) {
    if (i == segs.length) {
      if (node is Map<String, dynamic> && _isCell(node)) {
        return _Cell(node['value'], (node['quality'] as num?)?.toDouble());
      }
      return node;
    }
    var cur = node;
    if (cur is Map<String, dynamic> && _isCell(cur)) cur = cur['value'];
    final seg = segs[i];
    switch (seg) {
      case KeySegment(:final key):
        if (cur is! Map<String, dynamic> || !cur.containsKey(key)) {
          return _absentValue;
        }
        return _walk(cur[key], segs, i + 1);
      case IndexSegment(:final index):
        if (cur is! List || index >= cur.length) return _absentValue;
        return _walk(cur[index], segs, i + 1);
      case WildcardSegment():
        if (cur is! List) return _absentValue;
        final out = <Object?>[];
        for (final e in cur) {
          final v = _walk(e, segs, i + 1);
          if (identical(v, _absentValue)) continue;
          out.add(v is _Cell ? v.value : v);
        }
        // A list none of whose elements has the field is absence of the
        // field, not presence of an empty set — unless the wildcard is the
        // last segment, where the list itself is what was asked for.
        if (out.isEmpty && cur.isNotEmpty && i + 1 < segs.length) {
          return _absentValue;
        }
        return out;
    }
  }

  static bool _isCell(Map<String, dynamic> m) =>
      m.containsKey('value') &&
      (m.length == 1 || (m.length == 2 && m['quality'] is num));

  /// The elements a wildcard path stands for, as concrete paths, so a
  /// coverage test can ask about each.
  static List<CelmPath> expand(Map<String, dynamic> descriptor, CelmPath path) {
    if (!path.hasWildcard) return [path];
    final out = <CelmPath>[];
    _expand(descriptor, path.segments, 0, CelmPath.root, out);
    return out;
  }

  static void _expand(
    Object? node,
    List<CelmPathSegment> segs,
    int i,
    CelmPath prefix,
    List<CelmPath> out,
  ) {
    if (i == segs.length) {
      out.add(prefix);
      return;
    }
    var cur = node;
    if (cur is Map<String, dynamic> && _isCell(cur)) cur = cur['value'];
    final seg = segs[i];
    switch (seg) {
      case WildcardSegment():
        if (cur is! List) {
          out.add(prefix.append(seg));
          return;
        }
        for (var k = 0; k < cur.length; k++) {
          _expand(cur[k], segs, i + 1, prefix.append(IndexSegment(k)), out);
        }
      case KeySegment(:final key):
        final next = cur is Map<String, dynamic> ? cur[key] : null;
        _expand(next, segs, i + 1, prefix.append(seg), out);
      case IndexSegment(:final index):
        final next = cur is List && index < cur.length ? cur[index] : null;
        _expand(next, segs, i + 1, prefix.append(seg), out);
    }
  }
}

class _Cell {
  const _Cell(this.value, this.quality);
  final Object? value;
  final double? quality;
}

/// Answers "did anyone look there, deeply enough" from a coverage
/// statement (SDD §3.1.1, §3.3).
class CelmCoverageMatcher {
  CelmCoverageMatcher(List<CelmCoverage> coverage)
      : _entries = [
          for (final c in coverage) (CelmPath.parse(c.scope), c.depth),
        ];
  final List<(CelmPath, CelmDepth)> _entries;

  /// True when some entry's scope is a prefix of [field] at a depth that
  /// satisfies [required]. A wildcard field is covered only when every
  /// element it stands for is.
  bool covers(
    Map<String, dynamic> descriptor,
    CelmPath field,
    CelmDepth required,
  ) {
    var concrete = CelmFieldValue.expand(descriptor, field);
    if (concrete.isEmpty) {
      // The list a wildcard ranges over is itself absent: ask whether the
      // place it would live was examined.
      final upTo = field.segments.indexWhere((s) => s is WildcardSegment);
      concrete = [CelmPath(field.segments.sublist(0, upTo < 0 ? 0 : upTo))];
    }
    return concrete.every((p) => _entries.any(
          (e) => e.$2.satisfies(required) && e.$1.isPrefixOf(p),
        ));
  }

  /// The entries that bear on [field] — what a digest carries.
  List<CelmCoverage> bearingOn(CelmPath field) => [
        for (final e in _entries)
          if (e.$1.isPrefixOf(field) || field.isPrefixOf(e.$1))
            CelmCoverage(scope: e.$1.toString(), depth: e.$2),
      ];
}
