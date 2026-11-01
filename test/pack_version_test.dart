import 'package:mcp_celm/mcp_celm.dart';
import 'package:test/test.dart';

import 'fixtures/fixtures.dart';

/// TEST-PLAN §7 (pack version, listing) and §10 (judgment names its pack).
void main() {
  Matcher badPack() => throwsA(
      isA<AnalysisError>().having((e) => e.code, 'code', 'pack.bad_pack'));

  group('§7 pack version', () {
    test('a pack without a version loads as before', () {
      expect(CelmSurfacePack.fromJson(desktopSurface()).version, isNull);
      expect(CelmDomainPack.fromJson(labPanelDomain()).version, isNull);
    });

    test('a declared version is carried on both packs', () {
      expect(
          CelmSurfacePack.fromJson({...desktopSurface(), 'version': '1.2.0'})
              .version,
          '1.2.0');
      expect(
          CelmDomainPack.fromJson({...labPanelDomain(), 'version': '2026.10'})
              .version,
          '2026.10');
    });

    test('a version that is not a non-empty string is rejected', () {
      for (final v in <Object>['', 3, true]) {
        expect(
            () => CelmSurfacePack.fromJson({...desktopSurface(), 'version': v}),
            badPack());
        expect(
            () => CelmDomainPack.fromJson({...labPanelDomain(), 'version': v}),
            badPack());
      }
    });

    test('the version survives binding into the manifest', () {
      final port = build(
          surface: {...desktopSurface(), 'version': '1.2.0'},
          domain: {...labPanelDomain(), 'version': '2026.10'});
      expect(port.manifest.surface.version, '1.2.0');
      expect(port.manifest.domain.version, '2026.10');
    });
  });

  group('§7 listing', () {
    test('lists every supplied pack, ordered, with only the used two active',
        () {
      final port = build(domain: {...labPanelDomain(), 'version': '2026.10'});
      final list = port.packs();
      expect([
        for (final p in list) '${p.kind}:${p.id}'
      ], [
        'domain:lab-panel',
        'domain:oven',
        'surface:desktop-hid',
        'surface:scpi-bus',
      ]);
      expect([for (final p in list) p.active], [true, false, true, false]);
      expect(list.first.version, '2026.10');
      expect(list[1].version, isNull);
    });

    test('the JSON form omits an absent version', () {
      final j = build().packs().first.toJson();
      expect(j.containsKey('version'), isFalse);
      expect(j['kind'], 'domain');
    });
  });

  group('§10 judgment names its pack', () {
    test('a judged conclusion carries the domain pack id and version',
        () async {
      final port = build(
          perception: desktopWithPanel(color2: 'red'),
          domain: {...labPanelDomain(), 'version': '2026.10'});
      final o = await run(port, 'read_panel_status') as CelmCompleted;
      final j = o.conclusions.whereType<JudgedConclusion>().single;
      expect(j.pack, 'lab-panel');
      expect(j.packVersion, '2026.10');
    });

    test('an unversioned pack encodes with neither key beyond the id',
        () async {
      final port = build(perception: desktopWithPanel(color2: 'red'));
      final o = await run(port, 'read_panel_status') as CelmCompleted;
      final j = o.conclusions.whereType<JudgedConclusion>().single;
      final json = j.toJson();
      expect(json['pack'], 'lab-panel');
      expect(json.containsKey('packVersion'), isFalse);
    });

    test('a record written before the fields existed decodes', () {
      final back = CelmConclusion.fromJson({
        'id': 'c2',
        'runId': 'r1',
        'statement': 's',
        'provenance': 'judged',
        'confidence': 0.9,
        'reasoner': 'rules:x',
        'at': DateTime.utc(2026).toIso8601String(),
      }) as JudgedConclusion;
      expect(back.pack, isNull);
      expect(back.packVersion, isNull);
      expect(back.toJson().containsKey('pack'), isFalse);
    });
  });
}
