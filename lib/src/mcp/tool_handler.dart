/// The upward side of MCP: seven tools, each one port method, with the
/// contract types' JSON forms as arguments and results (SDD §2.4).
///
/// Transport-agnostic. A host's MCP server registers [tools] and routes
/// each call to [call].
library;

import 'package:mcp_bundle/ports.dart';

class CelmToolHandler {
  const CelmToolHandler(this.port);
  final CelmPort port;

  static const tools = [
    'celm.execute',
    'celm.cancel',
    'celm.observe',
    'celm.progress',
    'celm.explain',
    'celm.resume',
    'celm.standalone',
  ];

  /// JSON schemas for the seven tools' arguments. `celm.execute` has no
  /// slot for steps, skills or completion — a caller names a goal.
  static const schemas = <String, Map<String, dynamic>>{
    'celm.execute': {
      'type': 'object',
      'required': ['goal'],
      'properties': {
        'goal': {
          'type': 'object',
          'required': ['id'],
          'properties': {
            'id': {'type': 'string'},
            'params': {'type': 'object'},
          },
          'additionalProperties': false,
        },
        'constraints': {
          'type': 'object',
          'properties': {
            'readOnly': {'type': 'boolean'},
            'deadlineMs': {'type': 'integer'},
          },
          'additionalProperties': false,
        },
        'actor': {'type': 'object'},
      },
      'additionalProperties': false,
    },
    'celm.cancel': {
      'type': 'object',
      'required': ['runId'],
      'properties': {
        'runId': {'type': 'string'},
        'actor': {'type': 'object'}
      },
    },
    'celm.observe': {
      'type': 'object',
      'properties': {
        'request': {
          'type': 'object',
          'properties': {
            'scope': {'type': 'string'},
            'depth': {
              'enum': ['coarse', 'structure', 'atoms']
            },
          },
        },
        'actor': {'type': 'object'},
      },
    },
    'celm.progress': {
      'type': 'object',
      'required': ['runId'],
      'properties': {
        'runId': {'type': 'string'},
        'actor': {'type': 'object'}
      },
    },
    'celm.explain': {
      'type': 'object',
      'required': ['conclusionId'],
      'properties': {
        'conclusionId': {'type': 'string'},
        'actor': {'type': 'object'}
      },
    },
    'celm.resume': {
      'type': 'object',
      'required': ['runId', 'resumption'],
      'properties': {
        'runId': {'type': 'string'},
        'resumption': {
          'type': 'object',
          'required': ['kind'],
          'properties': {
            'kind': {
              'enum': ['resumeAt', 'resumeWith', 'abandon']
            },
            'step': {'type': 'string'},
            'params': {'type': 'object'},
            'why': {'type': 'string'},
          },
        },
        'actor': {'type': 'object'},
      },
    },
    'celm.standalone': {
      'type': 'object',
      'required': ['runId'],
      'properties': {
        'runId': {'type': 'string'},
        'actor': {'type': 'object'}
      },
    },
  };

  Future<Map<String, dynamic>> call(
      String tool, Map<String, dynamic> args) async {
    final actor = args['actor'] == null
        ? null
        : AnalysisActor.fromJson(args['actor'] as Map<String, dynamic>);
    switch (tool) {
      case 'celm.execute':
        final handle = await port.execute(
          CelmGoalRef.fromJson(_map(args, 'goal')),
          constraints: args['constraints'] == null
              ? null
              : CelmConstraints.fromJson(
                  args['constraints'] as Map<String, dynamic>),
          actor: actor,
        );
        return {'runId': handle.runId};
      case 'celm.cancel':
        return (await port.cancel(_str(args, 'runId'), actor: actor)).toJson();
      case 'celm.observe':
        final o = await port.observe(
          request: args['request'] == null
              ? null
              : CelmObserveRequest.fromJson(
                  args['request'] as Map<String, dynamic>),
          actor: actor,
        );
        return o.toJson();
      case 'celm.progress':
        return (await port.progress(_str(args, 'runId'), actor: actor))
            .toJson();
      case 'celm.explain':
        return (await port.explain(_str(args, 'conclusionId'), actor: actor))
            .toJson();
      case 'celm.resume':
        final o = await port.resume(
          _str(args, 'runId'),
          CelmResumption.fromJson(_map(args, 'resumption')),
          actor: actor,
        );
        return o.toJson();
      case 'celm.standalone':
        final list = await port.standalone(_str(args, 'runId'), actor: actor);
        return {'conclusions': list.map((c) => c.toJson()).toList()};
      default:
        throw AnalysisError(
          code: 'celm.unknown_tool',
          message: 'No tool "$tool"',
          details: {'tool': tool},
        );
    }
  }

  static String _str(Map<String, dynamic> args, String key) {
    final v = args[key];
    if (v is String) return v;
    throw AnalysisError(
      code: 'celm.missing_field',
      message: 'Tool argument "$key" is required',
      details: {'field': key},
    );
  }

  static Map<String, dynamic> _map(Map<String, dynamic> args, String key) {
    final v = args[key];
    if (v is Map<String, dynamic>) return v;
    throw AnalysisError(
      code: 'celm.missing_field',
      message: 'Tool argument "$key" is required',
      details: {'field': key},
    );
  }
}
