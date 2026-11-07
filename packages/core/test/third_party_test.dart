import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

void main() {
  Future<String?> asset(String path) async => 'text of $path';

  test('Windows: mpv with its licenses and the source link, ANGLE and its companions', () async {
    final n = await starsyncNotices(windows: true, asset: asset, libmpvLicenses: 'LGPL TEXT');
    expect(n.map((e) => e.packages.join('+')),
        ['mpv+FFmpeg', 'ANGLE', 'SwiftShader', 'Vulkan Loader', 'd3dcompiler_47', 'Anime4K', 'uosc']);
    expect(n.first.text, allOf(contains(libmpvSourcesUrl), endsWith('LGPL TEXT')));
    expect(n[1].text, 'text of assets/licenses/angle.txt');
    expect(n.last.text, startsWith(uoscCredit));
  });

  test('Linux: the system libmpv, nothing of Windows', () async {
    final n = await starsyncNotices(windows: false, asset: asset);
    expect(n.map((e) => e.packages.join('+')), ['mpv+FFmpeg', 'Anime4K', 'uosc']);
    expect(n.first.text, libmpvLinuxNote);
    expect(n[1].text, endsWith('text of $anime4kLicenseAsset'));
  });

  test('a missing file is said, a missing asset left out', () async {
    final n = await starsyncNotices(windows: true, asset: (_) async => null);
    expect(n.map((e) => e.packages.join('+')), ['mpv+FFmpeg', 'uosc']);
    expect(n.first.text, contains('libmpv-licenses.txt is missing'));
  });

  test('the source link is a release asset of the public repo', () {
    expect(libmpvSourcesUrl,
        matches(RegExp(r'^https://github\.com/Foxyz1302/starsync/releases/download/[^/]+/libmpv-windows-20261021-1-sources\.tar\.xz$')));
  });
}
