/// Packs — what is supplied to the runtime, and nothing else (D5, D5b).
///
/// A pack is data. It contains no control flow. Two packs, because two
/// things vary independently: skills and goals belong to an I/O surface,
/// references and the reasoner belong to a subject.
library;

import 'package:mcp_bundle/ports.dart';

import '../core/expr.dart';
import '../core/path.dart';

Never _packError(String code, String message, [Map<String, dynamic>? d]) =>
    throw AnalysisError(code: code, message: message, details: d);

T _enum<T extends Enum>(List<T> values, String kind, Object? raw, T? dflt) {
  if (raw == null && dflt != null) return dflt;
  if (raw is String) {
    for (final v in values) {
      if (v.name == raw || _snake(v.name) == raw) return v;
    }
  }
  _packError('pack.unknown_value', 'Unknown $kind "$raw"',
      {'kind': kind, 'value': raw});
}

String? _version(Object? raw) {
  if (raw == null) return null;
  if (raw is String && raw.isNotEmpty) return raw;
  _packError('pack.bad_pack', 'A pack version must be a non-empty string',
      {'version': raw});
}

String _snake(String s) =>
    s.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m.group(0)!.toLowerCase()}');

/// Whether a check is a fact or a judgment (D3).
enum CelmCheckKind { observe, judge }

enum CelmReversibility { reversible, irreversible }

/// One precondition, postcondition, completion clause or branch question.
class CelmCheck {
  const CelmCheck({
    required this.kind,
    this.expr,
    this.exprSource,
    this.ask,
    this.reads = const [],
    this.references = const [],
    this.attached = const [],
    this.requiresQuality = 0,
    this.requiresDepth = CelmDepth.structure,
  });

  factory CelmCheck.fromJson(Map<String, dynamic> json, {String where = ''}) {
    for (final k in json.keys) {
      if (_policyKeys.contains(k)) {
        _packError('pack.policy_in_pack',
            'A check may not carry a policy value ("$k") at $where');
      }
    }
    final kind = _enum<CelmCheckKind>(
        CelmCheckKind.values, 'check kind', json['kind'], null);
    final depth = json['requires_depth'] == null
        ? CelmDepth.structure
        : CelmDepth.fromString(json['requires_depth'] as String);
    final quality = (json['requires_quality'] as num?)?.toDouble() ?? 0;
    switch (kind) {
      case CelmCheckKind.observe:
        final src = json['expr'];
        if (src is! String || src.trim().isEmpty) {
          _packError('pack.bad_expression',
              'An observe check needs an expr at $where');
        }
        final expr = CelmExpr.parse(src);
        return CelmCheck(
          kind: kind,
          expr: expr,
          exprSource: src,
          reads: expr.reads,
          requiresQuality: quality,
          requiresDepth: depth,
        );
      case CelmCheckKind.judge:
        final ask = json['ask'];
        if (ask is! String || ask.trim().isEmpty) {
          _packError(
              'pack.bad_expression', 'A judge check needs an ask at $where');
        }
        final reads = (json['reads'] as List<dynamic>?)
                ?.map((e) => CelmPath.parse(e as String))
                .toList() ??
            const <CelmPath>[];
        if (reads.isEmpty) {
          _packError('pack.judge_reads_nothing',
              'A judge check must declare what it reads at $where');
        }
        return CelmCheck(
          kind: kind,
          ask: ask,
          reads: reads,
          references: (json['references'] as List<dynamic>?)?.cast<String>() ??
              const [],
          requiresQuality: quality,
          requiresDepth: depth,
        );
    }
  }
  final CelmCheckKind kind;

  /// `observe`: the expression. Parsed once, at load.
  final CelmExpr? expr;
  final String? exprSource;

  /// `judge`: the question.
  final String? ask;

  /// `judge`: the fields the reasoner is shown. An `observe` reads what
  /// its expression references.
  final List<CelmPath> reads;

  /// `judge`: references named explicitly. Resolved at load into
  /// [attached].
  final List<String> references;

  /// The references attached to this check, fixed at load.
  final List<CelmReferenceRef> attached;

  final double requiresQuality;
  final CelmDepth requiresDepth;

  static const _policyKeys = {
    'theta_pass',
    'theta_escalate',
    'on_low_confidence',
    'budget',
    'attempts',
  };

  CelmCheck withAttached(List<CelmReferenceRef> refs) => CelmCheck(
        kind: kind,
        expr: expr,
        exprSource: exprSource,
        ask: ask,
        reads: reads,
        references: references,
        attached: refs,
        requiresQuality: requiresQuality,
        requiresDepth: requiresDepth,
      );

  String get statement => kind == CelmCheckKind.observe ? exprSource! : ask!;
}

/// One call in a skill's action sequence.
class CelmActionCall {
  const CelmActionCall({
    required this.actuator,
    required this.verb,
    this.args = const {},
  });

  factory CelmActionCall.fromJson(Map<String, dynamic> json, String where) {
    final port = json['port'];
    if (port is! String || !port.contains('.')) {
      _packError('pack.bad_action',
          'Action port must be "<actuator>.<verb>" at $where');
    }
    final i = port.indexOf('.');
    return CelmActionCall(
      actuator: port.substring(0, i),
      verb: port.substring(i + 1),
      args: (json['args'] as Map<String, dynamic>?) ?? const {},
    );
  }
  final String actuator;
  final String verb;
  final Map<String, dynamic> args;

  String get port => '$actuator.$verb';
}

class CelmSkill {
  const CelmSkill({
    required this.name,
    this.params = const {},
    this.preconditions = const [],
    this.action = const [],
    this.postconditions = const [],
    this.writes = false,
    this.reversibility = CelmReversibility.reversible,
    this.timeout = const Duration(seconds: 4),
  });

  factory CelmSkill.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.isEmpty) {
      _packError('pack.bad_skill', 'A skill needs a name');
    }
    for (final k in json.keys) {
      if (_sequencing.contains(k)) {
        _packError('pack.sequencing_in_skill',
            'Skill "$name" declares "$k"; sequencing belongs to the goal');
      }
    }
    final action = json['action'];
    final seq = action is Map<String, dynamic> ? action['sequence'] : null;
    return CelmSkill(
      name: name,
      params: ((json['params'] as Map<String, dynamic>?) ?? const {})
          .map((k, v) => MapEntry(k, '$v')),
      preconditions: _checks(json['preconditions'], 'skill $name pre'),
      action: [
        for (final (i, e) in ((seq as List<dynamic>?) ?? const []).indexed)
          CelmActionCall.fromJson(
              e as Map<String, dynamic>, 'skill $name action[$i]'),
      ],
      postconditions: _checks(json['postconditions'], 'skill $name post'),
      writes: json['writes'] as bool? ?? false,
      reversibility: _enum<CelmReversibility>(CelmReversibility.values,
          'reversibility', json['reversibility'], CelmReversibility.reversible),
      timeout:
          Duration(milliseconds: (json['timeout_ms'] as num?)?.toInt() ?? 4000),
    );
  }
  final String name;
  final Map<String, String> params;
  final List<CelmCheck> preconditions;
  final List<CelmActionCall> action;
  final List<CelmCheck> postconditions;
  final bool writes;
  final CelmReversibility reversibility;
  final Duration timeout;

  static const _sequencing = {'next', 'then', 'on_pass', 'on_fail', 'goto'};

  bool get irreversible => reversibility == CelmReversibility.irreversible;

  CelmSkill withChecks(List<CelmCheck> pre, List<CelmCheck> post) => CelmSkill(
        name: name,
        params: params,
        preconditions: pre,
        action: action,
        postconditions: post,
        writes: writes,
        reversibility: reversibility,
        timeout: timeout,
      );
}

List<CelmCheck> _checks(Object? raw, String where) => [
      for (final (i, e) in ((raw as List<dynamic>?) ?? const []).indexed)
        CelmCheck.fromJson(e as Map<String, dynamic>, where: '$where[$i]'),
    ];

/// A declared judgment fork (D4a).
class CelmBranch {
  const CelmBranch({required this.check, this.onTrue, this.onFalse});
  final CelmCheck check;
  final String? onTrue;
  final String? onFalse;

  CelmBranch withCheck(CelmCheck c) =>
      CelmBranch(check: c, onTrue: onTrue, onFalse: onFalse);
}

class CelmStep {
  const CelmStep({
    required this.id,
    required this.skill,
    this.params = const {},
    this.observe,
    this.onPass,
    this.onFail,
    this.branch,
  });

  factory CelmStep.fromJson(String id, Map<String, dynamic> json) {
    final skill = json['skill'];
    if (skill is! String || skill.isEmpty) {
      _packError('pack.unknown_skill', 'Step "$id" names no skill');
    }
    CelmBranch? branch;
    final b = json['branch'];
    if (b is Map<String, dynamic>) {
      final check = CelmCheck.fromJson(
          {...b}
            ..remove('on_true')
            ..remove('on_false'),
          where: 'step $id branch');
      if (check.kind != CelmCheckKind.judge) {
        _packError('pack.bad_branch', 'A branch is a judgment at step $id');
      }
      branch = CelmBranch(
        check: check,
        onTrue: b['on_true'] as String?,
        onFalse: b['on_false'] as String?,
      );
    }
    return CelmStep(
      id: id,
      skill: skill,
      params: (json['params'] as Map<String, dynamic>?) ?? const {},
      observe: json['observe'] == null
          ? null
          : CelmObserveRequest.fromJson(
              json['observe'] as Map<String, dynamic>),
      onPass: json['on_pass'] as String?,
      onFail: json['on_fail'] as String?,
      branch: branch,
    );
  }
  final String id;
  final String skill;
  final Map<String, dynamic> params;
  final CelmObserveRequest? observe;
  final String? onPass;
  final String? onFail;
  final CelmBranch? branch;

  /// A step from which some arm goes nowhere: completion is asked there.
  bool get isTerminal => branch == null
      ? onPass == null
      : (branch!.onTrue == null || branch!.onFalse == null);

  CelmStep withBranch(CelmBranch? b) => CelmStep(
        id: id,
        skill: skill,
        params: params,
        observe: observe,
        onPass: onPass,
        onFail: onFail,
        branch: b,
      );
}

class CelmGoal {
  const CelmGoal({
    required this.id,
    this.params = const {},
    required this.observe,
    required this.entry,
    required this.steps,
    this.completion = const [],
    this.readOnly = false,
  });

  factory CelmGoal.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      _packError('pack.bad_goal', 'A goal needs an id');
    }
    final observe = json['observe'];
    if (observe is! Map<String, dynamic>) {
      _packError('pack.bad_goal', 'Goal "$id" declares no observe request');
    }
    final entry = json['entry'];
    if (entry is! String) {
      _packError('pack.unknown_entry', 'Goal "$id" has no entry');
    }
    final rawSteps = json['steps'];
    if (rawSteps is! Map<String, dynamic> || rawSteps.isEmpty) {
      _packError('pack.bad_goal', 'Goal "$id" declares no steps');
    }
    final constraints =
        (json['constraints'] as Map<String, dynamic>?) ?? const {};
    return CelmGoal(
      id: id,
      params: ((json['params'] as Map<String, dynamic>?) ?? const {})
          .map((k, v) => MapEntry(k, '$v')),
      observe: CelmObserveRequest.fromJson(observe),
      entry: entry,
      steps: rawSteps.map((k, v) =>
          MapEntry(k, CelmStep.fromJson(k, v as Map<String, dynamic>))),
      completion: _checks(json['completion'], 'goal $id completion'),
      readOnly: constraints['read_only'] as bool? ?? false,
    );
  }
  final String id;
  final Map<String, String> params;
  final CelmObserveRequest observe;
  final String entry;
  final Map<String, CelmStep> steps;
  final List<CelmCheck> completion;
  final bool readOnly;

  Iterable<CelmStep> get terminalSteps =>
      steps.values.where((s) => s.isTerminal);

  CelmGoal withSteps(Map<String, CelmStep> s, List<CelmCheck> c) => CelmGoal(
        id: id,
        params: params,
        observe: observe,
        entry: entry,
        steps: s,
        completion: c,
        readOnly: readOnly,
      );
}

/// A golden reference, in the descriptor's vocabulary (D4b).
class CelmReference {
  const CelmReference({
    required this.id,
    required this.field,
    this.expected = const {},
    this.tolerance = const {},
    this.conditions = const [],
  });

  factory CelmReference.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      _packError('pack.bad_reference', 'A reference needs an id');
    }
    final field = json['field'];
    if (field is! String || field.trim().isEmpty) {
      _packError('pack.reference_without_field',
          'Reference "$id" names no descriptor field; prose is not knowledge');
    }
    return CelmReference(
      id: id,
      field: CelmPath.parse(field),
      expected: (json['expected'] as Map<String, dynamic>?) ?? const {},
      tolerance: (json['tolerance'] as Map<String, dynamic>?) ?? const {},
      conditions: _checks(json['conditions'], 'reference $id'),
    );
  }
  final String id;
  final CelmPath field;
  final Map<String, dynamic> expected;
  final Map<String, dynamic> tolerance;
  final List<CelmCheck> conditions;

  CelmReferenceRef get ref => CelmReferenceRef(
        id: id,
        field: field.toString(),
        expected: {
          ...expected,
          if (tolerance.isNotEmpty) 'tolerance': tolerance,
        },
      );
}

/// A reasoner definition the domain pack carries (rules for the `rules`
/// backend, a model reference for `distilled`).
class CelmReasonerDef {
  const CelmReasonerDef(
      {required this.kind, this.model, this.rules = const []});
  final String kind;
  final String? model;
  final List<Map<String, dynamic>> rules;
}

/// Skills, goals, intent map (D5b).
class CelmSurfacePack {
  const CelmSurfacePack({
    required this.id,
    this.version,
    required this.skills,
    required this.goals,
    this.intents = const {},
  });

  factory CelmSurfacePack.fromJson(Map<String, dynamic> json) {
    if (json['pack'] != schema) {
      _packError('pack.wrong_kind',
          'Expected a surface pack ("$schema"), got "${json['pack']}"');
    }
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      _packError('pack.bad_pack', 'A pack needs an id');
    }
    final version = _version(json['version']);
    final skills = <String, CelmSkill>{};
    for (final e in (json['skills'] as List<dynamic>?) ?? const []) {
      final s = CelmSkill.fromJson(e as Map<String, dynamic>);
      if (skills.containsKey(s.name)) {
        _packError('pack.duplicate_skill', 'Skill "${s.name}" declared twice');
      }
      skills[s.name] = s;
    }
    final goals = <String, CelmGoal>{};
    for (final e in (json['goals'] as List<dynamic>?) ?? const []) {
      final g = CelmGoal.fromJson(e as Map<String, dynamic>);
      if (goals.containsKey(g.id)) {
        _packError('pack.duplicate_goal', 'Goal "${g.id}" declared twice');
      }
      goals[g.id] = g;
    }
    final pack = CelmSurfacePack(
      id: id,
      version: version,
      skills: skills,
      goals: goals,
      intents: ((json['intents'] as Map<String, dynamic>?) ?? const {})
          .map((k, v) => MapEntry(k, '$v')),
    );
    pack._validateGraphs();
    return pack;
  }
  final String id;

  /// The version the author declared, or null. Recorded and reported,
  /// never compared.
  final String? version;
  final Map<String, CelmSkill> skills;
  final Map<String, CelmGoal> goals;
  final Map<String, String> intents;

  static const schema = 'celm/surface@0.1';

  void _validateGraphs() {
    for (final g in goals.values) {
      if (!g.steps.containsKey(g.entry)) {
        _packError('pack.unknown_entry',
            'Goal "${g.id}" entry "${g.entry}" is not a step');
      }
      for (final s in g.steps.values) {
        if (!skills.containsKey(s.skill)) {
          _packError('pack.unknown_skill',
              'Step "${s.id}" of goal "${g.id}" names unknown skill "${s.skill}"');
        }
        for (final t in [
          s.onPass,
          s.onFail,
          s.branch?.onTrue,
          s.branch?.onFalse
        ]) {
          if (t != null && !g.steps.containsKey(t)) {
            _packError('pack.unknown_step',
                'Step "${s.id}" of goal "${g.id}" targets unknown step "$t"');
          }
        }
      }
      for (final intent in intents.values) {
        if (!goals.containsKey(intent)) {
          _packError(
              'pack.unknown_goal', 'Intent maps to unknown goal "$intent"');
        }
      }
    }
  }

  CelmSurfacePack withGoals(
          Map<String, CelmGoal> g, Map<String, CelmSkill> s) =>
      CelmSurfacePack(
          id: id, version: version, skills: s, goals: g, intents: intents);
}

/// Golden references and the reasoner (D5b). Names descriptor fields
/// only — a domain pack naming a skill or a goal is rejected.
class CelmDomainPack {
  const CelmDomainPack({
    required this.id,
    this.version,
    required this.references,
    this.reasoner,
  });

  factory CelmDomainPack.fromJson(Map<String, dynamic> json) {
    if (json['pack'] != schema) {
      _packError('pack.wrong_kind',
          'Expected a domain pack ("$schema"), got "${json['pack']}"');
    }
    for (final k in json.keys) {
      if (_surfaceKeys.contains(k)) {
        _packError('pack.domain_names_surface',
            'A domain pack may not carry "$k"; knowledge names descriptor fields only');
      }
    }
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      _packError('pack.bad_pack', 'A pack needs an id');
    }
    final version = _version(json['version']);
    final refs = <String, CelmReference>{};
    for (final e in (json['references'] as List<dynamic>?) ?? const []) {
      final m = e as Map<String, dynamic>;
      for (final k in m.keys) {
        if (_surfaceKeys.contains(k)) {
          _packError('pack.domain_names_surface',
              'Reference "${m['id']}" names a "$k"');
        }
      }
      final r = CelmReference.fromJson(m);
      if (refs.containsKey(r.id)) {
        _packError(
            'pack.duplicate_reference', 'Reference "${r.id}" declared twice');
      }
      refs[r.id] = r;
    }
    CelmReasonerDef? reasoner;
    final rd = json['reasoner'];
    if (rd is Map<String, dynamic>) {
      final rules = (rd['rules'] as List<dynamic>?)
              ?.map((e) => e as Map<String, dynamic>)
              .toList() ??
          const [];
      for (final r in rules) {
        for (final k in r.keys) {
          if (_surfaceKeys.contains(k)) {
            _packError('pack.domain_names_surface', 'A rule names a "$k"');
          }
        }
        if (r['when'] is String) CelmExpr.parse(r['when'] as String);
      }
      reasoner = CelmReasonerDef(
        kind: '${rd['kind'] ?? ''}',
        model: rd['model'] as String?,
        rules: rules,
      );
    }
    return CelmDomainPack(
        id: id, version: version, references: refs, reasoner: reasoner);
  }
  final String id;

  /// The version the author declared, or null. Recorded and reported,
  /// never compared.
  final String? version;
  final Map<String, CelmReference> references;
  final CelmReasonerDef? reasoner;

  static const schema = 'celm/domain@0.1';
  static const _surfaceKeys = {'skills', 'goals', 'intents', 'skill', 'goal'};

  /// References that bear on one of [reads] (feat-pack §4.1): the
  /// reference's field lies under a read path, contains one, or names
  /// another field of the same object — knowledge about an indicator's
  /// supply reaches a check that reads that indicator's color.
  List<CelmReferenceRef> attachedTo(List<CelmPath> reads) => [
        for (final r in references.values)
          if (reads.any((p) =>
              p.isPrefixOf(r.field) ||
              r.field.isPrefixOf(p) ||
              _sameObject(p, r.field)))
            r.ref,
      ];

  static bool _sameObject(CelmPath a, CelmPath b) {
    if (a.segments.isEmpty || b.segments.isEmpty) return false;
    if (a.segments.last is! KeySegment || b.segments.last is! KeySegment) {
      return false;
    }
    final pa = CelmPath(a.segments.sublist(0, a.segments.length - 1));
    final pb = CelmPath(b.segments.sublist(0, b.segments.length - 1));
    return pa.segments.isNotEmpty && (pa.isPrefixOf(pb) && pb.isPrefixOf(pa));
  }
}

/// The load-time cross-check between the two packs and the manifest's
/// bindings (feat-pack §6). Returns the surface pack with every judge
/// check's references attached and every skill's verbs verified.
CelmSurfacePack bindPacks({
  required CelmSurfacePack surface,
  required CelmDomainPack domain,
  required bool Function(String actuator, String verb) verbKnown,
  required bool Function(String actuator, String verb) writePermitted,
  required bool Function(String actuator, String verb) regimePermits,
  required bool supervisory,
}) {
  CelmCheck attach(CelmCheck c, String where) {
    if (c.kind != CelmCheckKind.judge) return c;
    if (c.references.isEmpty) return c.withAttached(domain.attachedTo(c.reads));
    final refs = <CelmReferenceRef>[];
    for (final id in c.references) {
      final r = domain.references[id];
      if (r == null) {
        _packError('pack.unknown_reference',
            'Check at $where names unknown reference "$id"');
      }
      refs.add(r.ref);
    }
    return c.withAttached(refs);
  }

  final skills = <String, CelmSkill>{};
  for (final s in surface.skills.values) {
    for (final a in s.action) {
      if (!verbKnown(a.actuator, a.verb)) {
        _packError('pack.unknown_verb',
            'Skill "${s.name}" uses "${a.port}", which no output declares');
      }
      if (s.writes && !writePermitted(a.actuator, a.verb)) {
        _packError('manifest.write_not_permitted',
            'Skill "${s.name}" writes with "${a.port}", which is not allowed');
      }
      if (!regimePermits(a.actuator, a.verb)) {
        _packError('manifest.regime_violation',
            'Skill "${s.name}" action "${a.port}" is not permitted under the declared regime');
      }
    }
    skills[s.name] = s.withChecks(
      [for (final c in s.preconditions) attach(c, 'skill ${s.name} pre')],
      [for (final c in s.postconditions) attach(c, 'skill ${s.name} post')],
    );
  }

  final goals = <String, CelmGoal>{};
  for (final g in surface.goals.values) {
    if (!supervisory && g.terminalSteps.isEmpty) {
      _packError('pack.no_terminal_step',
          'Goal "${g.id}" has no terminal step; it can never finish');
    }
    final steps = <String, CelmStep>{};
    for (final s in g.steps.values) {
      final b = s.branch;
      steps[s.id] =
          s.withBranch(b?.withCheck(attach(b.check, 'step ${s.id} branch')));
    }
    final completion = [
      for (final c in g.completion) attach(c, 'goal ${g.id} completion')
    ];
    final bound = g.withSteps(steps, completion);
    _checkDepths(bound, skills);
    goals[g.id] = bound;
  }
  return surface.withGoals(goals, skills);
}

/// `pack.depth_never_requested`: a check's `requires_depth` must be
/// requested by the observation it is evaluated on. Postconditions and a
/// branch are evaluated on the step's own observation; preconditions on
/// whatever came before, so they are held to the deepest request in the
/// goal; completion on a terminal step's observation.
void _checkDepths(CelmGoal g, Map<String, CelmSkill> skills) {
  CelmDepth effective(CelmStep s) => (s.observe ?? g.observe).depth;
  final deepest = g.steps.values
      .map(effective)
      .fold(g.observe.depth, (a, b) => b.index > a.index ? b : a);

  void need(CelmCheck c, CelmDepth got, String where) {
    if (!got.satisfies(c.requiresDepth)) {
      _packError('pack.depth_never_requested',
          '$where requires ${c.requiresDepth.name} but the observation it is evaluated on asks for ${got.name}');
    }
  }

  for (final s in g.steps.values) {
    final sk = skills[s.skill]!;
    for (final c in sk.postconditions) {
      need(c, effective(s), 'Step "${s.id}" postcondition');
    }
    for (final c in sk.preconditions) {
      need(c, deepest, 'Step "${s.id}" precondition');
    }
    if (s.branch != null) {
      need(s.branch!.check, effective(s), 'Step "${s.id}" branch');
    }
  }
  final terminals = g.terminalSteps.toList();
  for (final c in g.completion) {
    if (terminals.isEmpty) {
      need(c, deepest, 'Goal "${g.id}" completion');
    }
    // Completion is asked after every terminal step, on that step's
    // observation; each of them has to have looked deeply enough.
    for (final t in terminals) {
      need(c, effective(t), 'Goal "${g.id}" completion (after step "${t.id}")');
    }
  }
}
