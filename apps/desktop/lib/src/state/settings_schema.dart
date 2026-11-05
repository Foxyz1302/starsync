import 'package:hive_ce/hive.dart';

// The `settings` box's layout version and the ordered steps between
// versions. A step rewrites stored values for a new layout (renamed keys,
// changed formats); the restructure steps add theirs here.

/// The layout this build reads. 1: the layout of 1.2.x, where versioning
/// starts (a box without a version is at 1). 2: auto sit-out replaces the
/// idle switch. 3: the video volume is kept (`playerVolume`). 4: the
/// settings cleanup drops three choices for their defaults. 5: BRB, AFK
/// and Out replace the ready system: auto sit-out goes.
const settingsSchemaVersion = 5;

/// The box key holding the stored version.
const settingsSchemaKey = 'schemaVersion';

/// One step: brings a box at `to - 1` to [to].
class SettingsMigration {
  final int to;
  /// For the log ("settings schema 2: ...").
  final String what;
  final Future<void> Function(Box box) apply;
  const SettingsMigration(this.to, this.what, this.apply);
}

/// Every step in order of [SettingsMigration.to] (2, 3, ...).
const settingsMigrations = <SettingsMigration>[
  SettingsMigration(2, 'auto sit-out replaces "when idle, sit out instead of just unready"', _autoSitOut),
  SettingsMigration(3, 'the video volume is kept across starts', _playerVolume),
  SettingsMigration(4, 'the controls hide after 3 s, the ready flag stays on a swap, updates are always checked',
      _droppedChoices),
  SettingsMigration(5, 'AFK replaces auto sit-out (no switch)', _noAutoSitOut),
];

/// 5: AFK is always on (it never holds anyone back), so the auto sit-out
/// switch goes.
Future<void> _noAutoSitOut(Box box) async {
  await box.delete('autoSitOut');
}

/// The keys step 4 removes: their choices went for the defaults (the
/// controls hide after 3 s, ready stays when the video changes, updates
/// are checked automatically).
const droppedSettingKeys = ['controlsHideSecs', 'unreadyOnSwap', 'autoCheckUpdates'];

/// 4: the choices themselves are gone; whatever was stored goes with
/// them, so the defaults hold (a build before 4 reading the box finds them
/// missing and uses the same defaults).
Future<void> _droppedChoices(Box box) async {
  await box.deleteAll(droppedSettingKeys);
}

/// 3: `playerVolume` is new. Nothing to carry over (every start was at
/// 100 %, which a missing key still means); a value that is not a number
/// goes.
Future<void> _playerVolume(Box box) async {
  final v = box.get('playerVolume');
  if (v != null && v is! num) await box.delete('playerVolume');
}

/// 2: `idleSitsOut` only chose between two automatic steps after 10 idle
/// minutes (unready, or sit out); both are auto sit-out now, on unless
/// switched off (`autoSitOut`).
Future<void> _autoSitOut(Box box) async {
  if (!box.containsKey('idleSitsOut')) return;
  await box.delete('idleSitsOut');
  if (!box.containsKey('autoSitOut')) await box.put('autoSitOut', true);
}

/// Runs the [steps] past the box's stored version up to [current], in
/// order, storing the version after each, then stores [current]. A box
/// from a newer build (a downgrade) is left as it is. Returns a log line
/// per step run.
Future<List<String>> migrateSettings(Box box,
    {List<SettingsMigration> steps = settingsMigrations, int current = settingsSchemaVersion}) async {
  final stored = box.get(settingsSchemaKey);
  var at = stored is int ? stored : 1;
  if (at > current) return ['settings schema $at is newer than this build ($current): left as is'];
  final ran = <String>[];
  for (final step in [...steps]..sort((a, b) => a.to.compareTo(b.to))) {
    if (step.to <= at || step.to > current) continue;
    await step.apply(box);
    at = step.to;
    await box.put(settingsSchemaKey, at);
    ran.add('settings schema ${step.to}: ${step.what}');
  }
  if (stored != current) await box.put(settingsSchemaKey, current);
  return ran;
}
