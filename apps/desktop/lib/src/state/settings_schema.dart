import 'package:hive_ce/hive.dart';

// The `settings` box's layout version and the ordered steps between
// versions. A step rewrites stored values for a new layout (renamed keys,
// changed formats); the restructure steps add theirs here.

/// The layout this build reads. 1: the layout of 1.2.x, where versioning
/// starts (a box without a version is at 1).
const settingsSchemaVersion = 1;

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

/// Every step in order of [SettingsMigration.to] (2, 3, ...); empty while
/// version 1 is current.
const settingsMigrations = <SettingsMigration>[];

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
