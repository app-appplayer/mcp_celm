import 'package:mcp_celm/mcp_celm.dart';
import 'package:test/test.dart';

import 'fixtures/fixtures.dart';

/// feat-pack §6 and core-manifest §2: everything that can be refused at
/// load is refused at load.
void main() {
  Matcher refused(String code) =>
      throwsA(isA<AnalysisError>().having((e) => e.code, 'code', code));

  group('surface pack', () {
    test('loads the fixture', () {
      final p = CelmSurfacePack.fromJson(desktopSurface());
      expect(p.skills.keys, contains('open_file'));
      expect(
          p.goals['open_document']!.terminalSteps.map((s) => s.id), ['open']);
    });

    test('dangling target is rejected at load', () {
      final s = desktopSurface(extraGoals: [
        {
          'id': 'bad',
          'observe': {'scope': 'screen', 'depth': 'structure'},
          'entry': 'a',
          'steps': {
            'a': {'skill': 'look', 'on_pass': null, 'on_fail': 'nowhere'},
          },
        },
      ]);
      expect(() => CelmSurfacePack.fromJson(s), refused('pack.unknown_step'));
    });

    test('unknown entry, unknown skill', () {
      expect(
          () => CelmSurfacePack.fromJson(desktopSurface(extraGoals: [
                {
                  'id': 'g',
                  'observe': {'scope': 'screen', 'depth': 'structure'},
                  'entry': 'zz',
                  'steps': {
                    'a': {'skill': 'look', 'on_pass': null},
                  },
                },
              ])),
          refused('pack.unknown_entry'));
      expect(
          () => CelmSurfacePack.fromJson(desktopSurface(extraGoals: [
                {
                  'id': 'g',
                  'observe': {'scope': 'screen', 'depth': 'structure'},
                  'entry': 'a',
                  'steps': {
                    'a': {'skill': 'nope', 'on_pass': null},
                  },
                },
              ])),
          refused('pack.unknown_skill'));
    });

    test('a skill declaring sequencing is rejected', () {
      expect(
          () => CelmSurfacePack.fromJson(desktopSurface(extraSkills: [
                {
                  'name': 'x',
                  'action': {'sequence': <Object>[]},
                  'next': 'y'
                },
              ])),
          refused('pack.sequencing_in_skill'));
    });

    test('a check carrying a policy value is rejected', () {
      expect(
          () => CelmSurfacePack.fromJson(desktopSurface(extraSkills: [
                {
                  'name': 'x',
                  'action': {'sequence': <Object>[]},
                  'postconditions': [
                    {'kind': 'observe', 'expr': 'a == 1', 'theta_pass': 0.5},
                  ],
                },
              ])),
          refused('pack.policy_in_pack'));
    });

    test('a judge reading nothing is rejected', () {
      expect(
          () => CelmSurfacePack.fromJson(desktopSurface(extraSkills: [
                {
                  'name': 'x',
                  'action': {'sequence': <Object>[]},
                  'postconditions': [
                    {'kind': 'judge', 'ask': 'well?'},
                  ],
                },
              ])),
          refused('pack.judge_reads_nothing'));
    });

    test('unknown enum values are refused, not coerced', () {
      expect(
          () => CelmSurfacePack.fromJson(desktopSurface(extraSkills: [
                {
                  'name': 'x',
                  'action': {'sequence': <Object>[]},
                  'postconditions': [observeCheck('a == 1', depth: 'atom')],
                },
              ])),
          refused('celm.unknown_value'));
      expect(
          () => CelmSurfacePack.fromJson(desktopSurface(extraSkills: [
                {
                  'name': 'x',
                  'action': {'sequence': <Object>[]},
                  'reversibility': 'sometimes'
                },
              ])),
          refused('pack.unknown_value'));
    });

    test('a bad expression is rejected at load', () {
      expect(
          () => CelmSurfacePack.fromJson(desktopSurface(extraSkills: [
                {
                  'name': 'x',
                  'action': {'sequence': <Object>[]},
                  'postconditions': [observeCheck('a ==')],
                },
              ])),
          refused('celm.bad_expression'));
    });
  });

  group('domain pack', () {
    test('loads, and attaches references by field overlap', () {
      final d = CelmDomainPack.fromJson(labPanelDomain());
      final attached = d.attachedTo([CelmPath.parse('panel.indicators[*]')]);
      expect(attached.map((r) => r.id), ['panel_supply_nominal']);
      expect(d.attachedTo([CelmPath.parse('window')]), isEmpty);
    });

    test('naming a skill or goal is rejected', () {
      expect(
          () => CelmDomainPack.fromJson(
              {...labPanelDomain(), 'skills': <Object>[]}),
          refused('pack.domain_names_surface'));
      expect(
          () => CelmDomainPack.fromJson({
                ...labPanelDomain(),
                'references': [
                  {'id': 'r', 'field': 'a', 'skill': 'click'},
                ],
              }),
          refused('pack.domain_names_surface'));
    });

    test('prose without a field is rejected', () {
      expect(
          () => CelmDomainPack.fromJson({
                ...labPanelDomain(),
                'references': [
                  {'id': 'r', 'note': 'the supply should be about 3.3 volts'},
                ],
              }),
          refused('pack.reference_without_field'));
    });

    test('a surface pack cannot be loaded as a domain pack, or vice versa', () {
      expect(() => CelmDomainPack.fromJson(desktopSurface()),
          refused('pack.wrong_kind'));
      expect(() => CelmSurfacePack.fromJson(labPanelDomain()),
          refused('pack.wrong_kind'));
    });
  });

  group('manifest', () {
    test('loads the fixture with defaults applied', () {
      final port = build(manifest: manifestJson(policy: {}));
      expect(port.manifest.policy.thetaPass, 0.85);
      expect(port.manifest.policy.thetaEscalate, 0.60);
      expect(port.manifest.policy.budget.attempts, 6);
      expect(port.manifest.outputs['scpi']!.writes, CelmWrites.none);
    });

    test('unsourced perception port is rejected at construction', () {
      expect(() => build(manifest: manifestJson(inputs: [])),
          refused('manifest.unsourced_input'));
      expect(
          () => build(
                  manifest: manifestJson(inputs: [
                {'channel': 'vision', 'schema': 'descriptor@0.3'},
              ])),
          refused('manifest.unsourced_input'));
    });

    test('unsourced pack, reasoner, regime', () {
      expect(() => build(manifest: manifestJson()..remove('surface_pack')),
          refused('manifest.unsourced_pack'));
      expect(() => build(manifest: manifestJson()..remove('domain_pack')),
          refused('manifest.unsourced_pack'));
      expect(() => build(manifest: manifestJson(surface: 'nope')),
          refused('manifest.pack_not_found'));
      expect(() => build(manifest: manifestJson()..remove('reasoner')),
          refused('manifest.unsourced_reasoner'));
      expect(() => build(manifest: manifestJson()..remove('regime')),
          refused('manifest.unsourced_regime'));
    });

    test('unknown regime, unknown enum value', () {
      expect(() => build(manifest: manifestJson(regime: 'supervised')),
          refused('manifest.unknown_regime'));
      expect(
          () => build(
                  manifest: manifestJson(outputs: [
                {
                  'actuator': 'hid',
                  'port': 'mcp:hid',
                  'vocab': ['click'],
                  'writes': 'maybe'
                },
              ])),
          refused('manifest.unknown_value'));
      expect(() => build(manifest: manifestJson(reasoner: {'kind': 'oracle'})),
          refused('manifest.unknown_value'));
    });

    test('a manifest asking for a depth the port cannot honour', () {
      expect(
          () => build(
                manifest: manifestJson(inputs: [
                  {
                    'channel': 'vision',
                    'port': 'mcp:vision.read',
                    'schema': 'd',
                    'depth': 'atoms'
                  },
                ]),
                perception: ScriptedPerception((r, i) => obs(desktopOpen()),
                    depths: {CelmDepth.coarse}),
              ),
          refused('manifest.unsupported_depth'));
    });

    test('write default is none: a writing skill cannot load', () {
      expect(
          () => build(
                  manifest: manifestJson(outputs: [
                {
                  'actuator': 'hid',
                  'port': 'mcp:hid',
                  'vocab': ['click', 'type', 'key']
                },
                {
                  'actuator': 'scpi',
                  'port': 'mcp:scpi',
                  'vocab': ['query']
                },
              ])),
          refused('manifest.write_not_permitted'));
    });

    test('a verb no output declares', () {
      expect(
          () => build(
                surface: desktopSurface(extraSkills: [
                  {
                    'name': 'x',
                    'action': {
                      'sequence': [
                        {'port': 'hid.launch', 'args': <String, Object>{}},
                      ]
                    },
                  },
                ]),
              ),
          refused('pack.unknown_verb'));
    });

    test('bad policy: theta_escalate above theta_pass', () {
      expect(
          () => build(
              manifest: manifestJson(
                  policy: {'theta_pass': 0.5, 'theta_escalate': 0.7})),
          refused('manifest.bad_policy'));
    });

    test('llm and distilled need a host reasoner; distilled must be local', () {
      expect(() => build(manifest: manifestJson(reasoner: {'kind': 'llm'})),
          refused('manifest.reasoner_not_found'));
      expect(
          () => build(
                manifest:
                    manifestJson(reasoner: {'kind': 'distilled', 'model': 'm'}),
                reasoner: constantReasoner(true, 0.9, remote: true),
              ),
          refused('manifest.reasoner_not_found'));
      final ok = build(
        manifest: manifestJson(reasoner: {'kind': 'distilled', 'model': 'm'}),
        reasoner: constantReasoner(true, 0.9),
      );
      expect(ok.manifest.reasoner.remote, isFalse);
    });

    test('rules kind needs rules in the domain pack', () {
      expect(
          () => build(domain: {
                ...labPanelDomain(),
                'reasoner': {'kind': 'distilled', 'model': 'x'},
              }),
          refused('manifest.reasoner_not_found'));
    });
  });

  group('regime (D7)', () {
    test('supervisory rejects an effector write at load', () {
      expect(() => build(manifest: manifestJson(regime: 'supervisory')),
          refused('manifest.regime_violation'));
    });

    test('supervisory permits a setpoint', () {
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
      );
      expect(port.manifest.regime, CelmRegime.supervisory);
    });
  });

  group('depth never requested (pack.depth_never_requested)', () {
    test('a check over atoms in a goal that only asks for structure', () {
      expect(
          () => build(
                surface: desktopSurface(extraGoals: [
                  {
                    'id': 'g',
                    'observe': {'scope': 'screen', 'depth': 'structure'},
                    'entry': 'a',
                    'steps': {
                      'a': {'skill': 'read_indicators', 'on_pass': null},
                    },
                  },
                ]),
              ),
          refused('pack.depth_never_requested'));
    });

    test('no terminal step under discrete-verify-retry', () {
      expect(
          () => build(
                surface: desktopSurface(extraGoals: [
                  {
                    'id': 'g',
                    'observe': {'scope': 'screen', 'depth': 'structure'},
                    'entry': 'a',
                    'steps': {
                      'a': {'skill': 'look', 'on_pass': 'a'},
                    },
                  },
                ]),
              ),
          refused('pack.no_terminal_step'));
    });
  });
}
