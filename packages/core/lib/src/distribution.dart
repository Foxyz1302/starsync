// Who publishes this build of Starsync, and where it looks first: the
// one file a fork edits (DEVELOPMENT "Signing", "A fork"). Everything
// here is only a starting point: the signed config
// (`updates/starsync-config.json`, remote_config.dart) replaces the
// addresses once an app has read it, and can hand the key over to a
// new one (`nextKey`). The key itself never comes from anywhere but this
// file or a config it signed. ARCHITECTURE "Updater".

/// The public keys whose signatures this build trusts (base64 of the
/// 32-byte Ed25519 key), oldest first. `dart tool/keygen.dart` prints
/// one.
const trustedKeys = [
  '+uteUAH5TdDH7P3dFdf/hxw6IuSsB0aXIsBp9EcvmVk=',
];

/// Where the signed config is looked for when the app has no saved
/// copy (and after the saved copy's own `configUrls`), in order. Any
/// host is safe to list: a copy counts only when its signature does.
const builtInConfigUrls = [
  'https://raw.githubusercontent.com/Foxyz1302/starsync/main/starsync-config.json',
  'https://git.example.org/Foxyz/sync_replay_project/raw/branch/main/updates/starsync-config.json',
  'https://git.example.org/Foxyz/sync_replay_project/raw/branch/main/updates/starsync-config.json',
];

/// The releases' manifest until a config says otherwise, tried in order.
const builtInStableManifestUrls = [
  'https://git.example.org/Foxyz/sync_replay_project/raw/branch/main/updates/manifest.json',
  'https://git.example.org/Foxyz/sync_replay_project/raw/branch/main/updates/manifest.json',
];

/// The test builds' manifest (the `dev` prerelease, `tool/dev_release.sh`)
/// until a config says otherwise, tried in order.
const builtInDevManifestUrls = [
  'https://git.example.org/Foxyz/sync_replay_project/releases/download/dev/manifest.json',
  'https://git.example.org/Foxyz/sync_replay_project/releases/download/dev/manifest.json',
];
