/// The open-source notices Starsync adds to Flutter's own (`NOTICES`):
/// the app's license page (Settings → Help & about) and each archive's
/// `THIRD_PARTY_LICENSES.txt` (`tool/third_party_licenses.dart`) list the
/// same entries.
library;

/// One entry: the software it covers and its license text.
typedef ThirdPartyNotice = ({List<String> packages, String text});

/// The corresponding source of the libmpv the Windows build ships (mpv
/// and FFmpeg, GNU LGPL version 3 or later as built), mirrored from
/// freeKC/libmpv-builds release 20261021-1 so it stays up as long as the
/// builds that ship it (DEVELOPMENT "Third-party licenses").
const libmpvSourcesUrl = 'https://github.com/Foxyz1302/starsync/releases/download/'
    'libmpv-20261021-1/libmpv-windows-20261021-1-sources.tar.xz';

/// The Minimal player skin's credit (About shows it too).
const uoscCredit = 'Player timeline and controls inspired by uosc by tomasklaen, LGPL-2.1 '
    '(github.com/tomasklaen/uosc).';

/// What the Linux build says about mpv: it brings none of its own.
const libmpvLinuxNote = 'Starsync on Linux plays video with the libmpv (mpv and FFmpeg) installed '
    'on your system; neither is included in Starsync. Their licenses come with your '
    "system's packages.";

/// The head of the Windows mpv entry, before `libmpv-licenses.txt`.
const libmpvWindowsNote = 'libmpv-2.dll: mpv and FFmpeg, GNU LGPL version 3 or later as built. '
    'You may replace this DLL with your own build of libmpv. The corresponding source is at '
    '$libmpvSourcesUrl (a copy of the release the DLL comes from, '
    'https://github.com/freeKC/libmpv-builds/releases/tag/20261021-1). '
    'The licenses of everything in it follow (libmpv-licenses.txt beside starsync.exe).';

/// The Flutter assets with the licenses of the graphics libraries the
/// Windows build ships (ANGLE and what comes with it), by name.
const windowsGraphicsLicenseAssets = {
  'ANGLE': 'assets/licenses/angle.txt',
  'SwiftShader': 'assets/licenses/swiftshader.txt',
  'Vulkan Loader': 'assets/licenses/vulkan_loader.txt',
  'd3dcompiler_47': 'assets/licenses/d3dcompiler.txt',
};

/// Anime4K's license, a Flutter asset beside its shaders.
const anime4kLicenseAsset = 'assets/shaders/anime4k/LICENSE';

/// Starsync's own notices for one platform. [asset] reads a bundled
/// Flutter asset by its path (null when missing); [libmpvLicenses] is the
/// `libmpv-licenses.txt` beside the Windows exe (null when missing).
Future<List<ThirdPartyNotice>> starsyncNotices({
  required bool windows,
  required Future<String?> Function(String path) asset,
  String? libmpvLicenses,
}) async {
  final out = <ThirdPartyNotice>[];
  if (windows) {
    out.add((
      packages: const ['mpv', 'FFmpeg'],
      text: '$libmpvWindowsNote\n\n'
          '${libmpvLicenses ?? 'libmpv-licenses.txt is missing from this install.'}',
    ));
    for (final MapEntry(key: name, value: path) in windowsGraphicsLicenseAssets.entries) {
      final text = await asset(path);
      if (text != null) out.add((packages: [name], text: text));
    }
  } else {
    out.add((packages: const ['mpv', 'FFmpeg'], text: libmpvLinuxNote));
  }
  final anime4k = await asset(anime4kLicenseAsset);
  if (anime4k != null) {
    out.add((packages: const ['Anime4K'], text: 'The Anime4K upscaling shaders, from '
        'https://github.com/bloc97/Anime4K.\n\n$anime4k'));
  }
  out.add((packages: const ['uosc'], text: '$uoscCredit No uosc code is included in Starsync.'));
  return out;
}
