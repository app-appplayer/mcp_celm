/// The manifest — the complete load specification (D6, `core-manifest`).
///
/// Every runtime dependency is sourced from it. Sourced is not the same
/// as spelled out: a policy value has a documented default because
/// absence has a safe meaning there; a port, a pack, a reasoner or a
/// regime has none, because there is no conservative guess for which.
library;

import 'package:mcp_bundle/ports.dart';

import '../feat/pack.dart';
import '../feat/reasoner.dart';
import '../infra/ports.dart';

Never _bad(String code, String message, [Map<String, dynamic>? details]) =>
    throw AnalysisError(code: code, message: message, details: details);

/// Where CeLM sits in the control hierarchy (D7).
enum CelmRegime {
  discreteVerifyRetry,
  supervisory;

  static CelmRegime parse(Object? raw) {
    if (raw == 'discrete-verify-retry') return CelmRegime.discreteVerifyRetry;
    if (raw == 'supervisory') return CelmRegime.supervisory;
    if (raw == null) {
      _bad('manifest.unsourced_regime', 'The manifest names no regime');
    }
    _bad('manifest.unknown_regime', 'Unknown regime "$raw"', {'regime': raw});
  }

  bool permits(CelmActionKind kind) => switch (this) {
        CelmRegime.discreteVerifyRetry => true,
        CelmRegime.supervisory => kind == CelmActionKind.setpoint,
      };
}

class CelmInputBinding {
  const CelmInputBinding({
    required this.channel,
    required this.port,
    required this.schema,
    this.qualityFloor = 0,
  });
  final String channel;
  final String port;
  final String schema;
  final double qualityFloor;
}

enum CelmWrites { none, allowList }

class CelmOutputBinding {
  const CelmOutputBinding({
    required this.actuator,
    required this.port,
    required this.vocabulary,
    this.writes = CelmWrites.none,
    this.allowed = const {},
  });
  final String actuator;
  final String port;
  final Set<String> vocabulary;
  final CelmWrites writes;
  final Set<String> allowed;
}

class CelmReasonerSpec {
  const CelmReasonerSpec({required this.kind, this.model});
  final String kind;
  final String? model;

  static const kinds = {'rules', 'distilled', 'llm'};
}

class CelmBudgetSpec {
  const CelmBudgetSpec({
    this.attempts = 6,
    this.maxEscalations = 3,
    this.wall = const Duration(seconds: 60),
  });
  final int attempts;
  final int maxEscalations;
  final Duration wall;
}

class CelmPolicy {
  const CelmPolicy({
    this.thetaPass = 0.85,
    this.thetaEscalate = 0.60,
    this.budget = const CelmBudgetSpec(),
    this.gateTimeout = const Duration(seconds: 60),
  });
  final double thetaPass;
  final double thetaEscalate;
  final CelmBudgetSpec budget;

  /// How long the interlock may take to answer before the gate treats it as
  /// not satisfied.
  final Duration gateTimeout;
}

/// A fully resolved manifest: nothing on it can fail to resolve later.
class CelmManifest {
  const CelmManifest._({
    required this.instance,
    required this.inputs,
    required this.outputs,
    required this.surface,
    required this.domain,
    required this.reasonerSpec,
    required this.reasoner,
    required this.policy,
    required this.regime,
  });

  /// Loads and validates. [surfacePacks] and [domainPacks] resolve the
  /// names the manifest gives; [actuators] resolves output bindings so
  /// vocabularies and kinds can be checked at load; [reasoner] is
  /// required for `llm` and `distilled` (the host supplies the model) and
  /// ignored for `rules` (the pack supplies them).
  factory CelmManifest.load(
    Map<String, dynamic> json, {
    required Map<String, CelmSurfacePack> surfacePacks,
    required Map<String, CelmDomainPack> domainPacks,
    required Map<String, CelmActuatorPort> actuators,
    required Set<CelmDepth> perceptionDepths,
    CelmReasoner? reasoner,
  }) {
    if (json['manifest'] != schema) {
      _bad('manifest.unknown_schema',
          'Expected "$schema", got "${json['manifest']}"');
    }
    final instance = json['instance'] as String? ?? '';

    // Inputs.
    final inputs = <CelmInputBinding>[];
    final rawInputs = (json['inputs'] as List<dynamic>?) ?? const [];
    if (rawInputs.isEmpty) {
      _bad(
          'manifest.unsourced_input', 'The manifest names no perception input');
    }
    for (final e in rawInputs) {
      final m = e as Map<String, dynamic>;
      final port = m['port'];
      final schema = m['schema'];
      if (port is! String ||
          port.isEmpty ||
          schema is! String ||
          schema.isEmpty) {
        _bad('manifest.unsourced_input',
            'Input "${m['channel']}" names no port or no schema');
      }
      final depth = m['depth'];
      if (depth != null) {
        final d = CelmDepth.fromString(depth as String);
        if (!perceptionDepths.contains(d)) {
          _bad('manifest.unsupported_depth',
              'Input "${m['channel']}" asks for depth "${d.name}", which the perception port does not support');
        }
      }
      inputs.add(CelmInputBinding(
        channel: m['channel'] as String? ?? '',
        port: port,
        schema: schema,
        qualityFloor: (m['quality_floor'] as num?)?.toDouble() ?? 0,
      ));
    }

    // Outputs.
    final outputs = <String, CelmOutputBinding>{};
    for (final e in (json['outputs'] as List<dynamic>?) ?? const []) {
      final m = e as Map<String, dynamic>;
      final actuator = m['actuator'];
      final port = m['port'];
      final vocab = (m['vocab'] as List<dynamic>?)?.cast<String>();
      if (actuator is! String ||
          port is! String ||
          vocab == null ||
          vocab.isEmpty) {
        _bad('manifest.unsourced_output',
            'Output "${m['actuator']}" names no port or no vocabulary');
      }
      final bound = actuators[actuator];
      if (bound == null) {
        _bad('manifest.unsourced_output',
            'Output "$actuator" is not bound to an actuator port');
      }
      for (final v in vocab) {
        if (!bound.vocabulary.contains(v)) {
          _bad('manifest.unknown_verb',
              'Output "$actuator" declares verb "$v", which its port does not accept');
        }
      }
      final writes = switch (m['writes']) {
        null || 'none' => CelmWrites.none,
        'allow_list' => CelmWrites.allowList,
        final other => _bad('manifest.unknown_value', 'Unknown writes "$other"',
            {'field': 'writes', 'value': other}),
      };
      final allowed =
          (m['allowed'] as List<dynamic>?)?.cast<String>().toSet() ?? {};
      if (writes == CelmWrites.none && allowed.isNotEmpty) {
        _bad('manifest.bad_policy',
            'Output "$actuator" lists allowed verbs but writes is none');
      }
      for (final v in allowed) {
        if (!vocab.contains(v)) {
          _bad('manifest.unknown_verb',
              'Output "$actuator" allows "$v", which is not in its vocabulary');
        }
      }
      outputs[actuator] = CelmOutputBinding(
        actuator: actuator,
        port: port,
        vocabulary: vocab.toSet(),
        writes: writes,
        allowed: allowed,
      );
    }

    // Packs.
    final surfaceName = json['surface_pack'];
    if (surfaceName is! String) {
      _bad('manifest.unsourced_pack', 'The manifest names no surface pack');
    }
    final surface = surfacePacks[surfaceName];
    if (surface == null) {
      _bad('manifest.pack_not_found', 'Surface pack "$surfaceName" not found');
    }
    final domainName = json['domain_pack'];
    if (domainName is! String) {
      _bad('manifest.unsourced_pack', 'The manifest names no domain pack');
    }
    final domain = domainPacks[domainName];
    if (domain == null) {
      _bad('manifest.pack_not_found', 'Domain pack "$domainName" not found');
    }

    // Reasoner.
    final rr = json['reasoner'];
    if (rr is! Map<String, dynamic> || rr['kind'] is! String) {
      _bad('manifest.unsourced_reasoner', 'The manifest names no reasoner');
    }
    final kind = rr['kind'] as String;
    if (!CelmReasonerSpec.kinds.contains(kind)) {
      _bad('manifest.unknown_value', 'Unknown reasoner kind "$kind"',
          {'field': 'reasoner.kind', 'value': kind});
    }
    final spec = CelmReasonerSpec(kind: kind, model: rr['model'] as String?);
    final CelmReasoner resolved;
    if (kind == 'rules') {
      final def = domain.reasoner;
      if (def == null || def.kind != 'rules') {
        _bad('manifest.reasoner_not_found',
            'Reasoner kind "rules" but domain pack "${domain.id}" carries no rules');
      }
      resolved = RulesReasoner(
          id: spec.model ?? 'rules:${domain.id}', rules: def.rules);
    } else {
      if (reasoner == null) {
        _bad('manifest.reasoner_not_found',
            'Reasoner kind "$kind" needs a host-supplied reasoner');
      }
      if (kind == 'distilled' && reasoner.remote) {
        _bad('manifest.reasoner_not_found',
            'A distilled reasoner must be local; the supplied one is remote');
      }
      resolved = reasoner;
    }

    // Policy.
    final pr = (json['policy'] as Map<String, dynamic>?) ?? const {};
    final br = (pr['budget'] as Map<String, dynamic>?) ?? const {};
    final policy = CelmPolicy(
      thetaPass: (pr['theta_pass'] as num?)?.toDouble() ?? 0.85,
      thetaEscalate: (pr['theta_escalate'] as num?)?.toDouble() ?? 0.60,
      budget: CelmBudgetSpec(
        attempts: (br['attempts'] as num?)?.toInt() ?? 6,
        maxEscalations: (br['max_escalations'] as num?)?.toInt() ?? 3,
        wall: Duration(milliseconds: (br['wall_ms'] as num?)?.toInt() ?? 60000),
      ),
      gateTimeout: Duration(
          milliseconds: (pr['gate_timeout_ms'] as num?)?.toInt() ?? 60000),
    );
    if (policy.thetaPass < 0 ||
        policy.thetaPass > 1 ||
        policy.thetaEscalate < 0 ||
        policy.thetaEscalate > policy.thetaPass ||
        policy.budget.attempts < 0 ||
        policy.budget.maxEscalations < 0 ||
        policy.budget.wall <= Duration.zero ||
        policy.gateTimeout <= Duration.zero) {
      _bad('manifest.bad_policy', 'Policy values out of range');
    }

    final regime = CelmRegime.parse(json['regime']);

    // Cross-checks between the packs and the bindings, and the regime.
    final bound = bindPacks(
      surface: surface,
      domain: domain,
      verbKnown: (a, v) => outputs[a]?.vocabulary.contains(v) ?? false,
      writePermitted: (a, v) {
        final o = outputs[a];
        return o != null &&
            o.writes == CelmWrites.allowList &&
            o.allowed.contains(v);
      },
      regimePermits: (a, v) {
        final port = actuators[a];
        final kind = port?.kinds[v] ?? CelmActionKind.effector;
        return regime.permits(kind);
      },
      supervisory: regime == CelmRegime.supervisory,
    );

    return CelmManifest._(
      instance: instance,
      inputs: inputs,
      outputs: outputs,
      surface: bound,
      domain: domain,
      reasonerSpec: spec,
      reasoner: resolved,
      policy: policy,
      regime: regime,
    );
  }
  final String instance;
  final List<CelmInputBinding> inputs;
  final Map<String, CelmOutputBinding> outputs;
  final CelmSurfacePack surface;
  final CelmDomainPack domain;
  final CelmReasonerSpec reasonerSpec;
  final CelmReasoner reasoner;
  final CelmPolicy policy;
  final CelmRegime regime;

  static const schema = 'celm/manifest@0.1';

  bool get hasIrreversibleSkill =>
      surface.skills.values.any((s) => s.irreversible);
}
