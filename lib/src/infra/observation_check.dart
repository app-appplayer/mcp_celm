/// A check of a perception tool's answer against the contract of
/// `infra-ports` §2, for the tool's author to run on their own answers.
library;

import 'package:mcp_bundle/ports.dart';

import '../core/path.dart';

/// One departure from the perception contract.
class CelmObservationIssue {
  const CelmObservationIssue({
    required this.path,
    required this.code,
    required this.message,
    required this.severity,
  });

  /// Where in the answer, e.g. `coverage[1].depth` or `descriptor.a.b`.
  final String path;
  final String code;
  final String message;

  /// `error` — the answer breaks the contract; `warning` — it is readable
  /// but loses something.
  final String severity;

  Map<String, dynamic> toJson() => {
        'path': path,
        'code': code,
        'message': message,
        'severity': severity,
      };
}

/// Lists every way [json] departs from what the runtime expects of an
/// observation. Pure: it reads nothing but [json] and never throws. An
/// empty list means the answer conforms.
List<CelmObservationIssue> validateObservationJson(Object? json) {
  final issues = <CelmObservationIssue>[];
  void add(String path, String code, String message,
          [String severity = 'error']) =>
      issues.add(CelmObservationIssue(
          path: path, code: code, message: message, severity: severity));

  if (json is! Map) {
    add('', 'observation.not_object', 'The answer is not a JSON object');
    return issues;
  }

  final descriptor = json['descriptor'];
  if (descriptor is! Map) {
    add('descriptor', 'descriptor.missing',
        'descriptor is absent or not an object');
  } else {
    _walkLeaves(descriptor, 'descriptor', add);
  }

  final coverage = json['coverage'];
  if (coverage is! List) {
    add('coverage', 'coverage.missing', 'coverage is absent or not a list');
  } else {
    if (coverage.isEmpty) {
      add('coverage', 'coverage.empty',
          'coverage is empty: every absence will be unobservable', 'warning');
    }
    for (var i = 0; i < coverage.length; i++) {
      final e = coverage[i];
      final at = 'coverage[$i]';
      if (e is! Map || e['scope'] is! String || e['depth'] is! String) {
        add(at, 'coverage.bad_entry',
            'An entry needs a string "scope" and a string "depth"');
        continue;
      }
      try {
        CelmPath.parse(e['scope'] as String);
      } on Object {
        add('$at.scope', 'coverage.bad_scope',
            '"${e['scope']}" is outside the path form');
      }
      try {
        CelmDepth.fromString(e['depth'] as String);
      } on Object {
        add('$at.depth', 'coverage.bad_depth',
            '"${e['depth']}" is not coarse, structure or atoms');
      }
    }
  }

  final at = json['at'];
  if (at == null) {
    add('at', 'at.missing',
        'at is absent: the read time will be used instead', 'warning');
  } else if (at is! String || DateTime.tryParse(at) == null) {
    add('at', 'at.bad_instant', 'at is not an ISO-8601 instant');
  }
  return issues;
}

/// Same notion of a cell as the runtime's reading of a descriptor.
bool _isCell(Map<dynamic, dynamic> m) =>
    m.containsKey('value') &&
    (m.length == 1 || (m.length == 2 && m.containsKey('quality')));

void _walkLeaves(Object? node, String path,
    void Function(String, String, String, [String]) add) {
  if (node is Map) {
    if (_isCell(node)) {
      final q = node['quality'];
      if (node.containsKey('quality') && (q is! num || q < 0 || q > 1)) {
        add('$path.quality', 'quality.out_of_range',
            'quality must be a number in [0, 1]');
      }
      if (!node.containsKey('quality')) {
        add(path, 'leaf.no_quality',
            'A cell without quality is below every non-zero floor', 'warning');
      }
      return;
    }
    for (final e in node.entries) {
      _walkLeaves(e.value, '$path.${e.key}', add);
    }
  } else if (node is List) {
    for (var i = 0; i < node.length; i++) {
      _walkLeaves(node[i], '$path[$i]', add);
    }
  } else {
    add(path, 'leaf.no_quality',
        'A bare value has no quality: it is below every non-zero floor',
        'warning');
  }
}
