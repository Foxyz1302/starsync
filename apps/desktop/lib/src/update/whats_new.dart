import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sync_relay_core/core.dart';

import '../state/settings.dart';
import 'update_controller.dart';

// "What's new in X.Y.Z" once after an update. The notes come from the
// manifest: the one installed (kept before the restart) or, for an update
// made another way (1.3.x's updater, `--upgrade`, by hand), the manifest of
// the first check that finds this very version. A fresh install shows
// nothing; Settings → About opens the card again.

/// What the card shows for one version.
class ReleaseNotes {
  final String version;

  /// The one-line notes (all a manifest from before the changelog has).
  final String notes;
  final ReleaseChanges? changes;

  /// The few lines shown first (empty for a version from before them).
  final List<String> highlights;
  const ReleaseNotes({required this.version, this.notes = '', this.changes, this.highlights = const []});

  factory ReleaseNotes.of(UpdateManifest m) =>
      ReleaseNotes(version: m.version, notes: m.notes, changes: m.changes, highlights: m.highlights);

  /// Null for anything unreadable.
  static ReleaseNotes? fromJson(Object? json) {
    if (json is! Map) return null;
    final version = json['version'];
    if (version is! String || version.isEmpty) return null;
    final notes = json['notes'];
    return ReleaseNotes(
      version: version,
      notes: notes is String ? notes : '',
      changes: ReleaseChanges.fromJson(json['changes']),
      highlights: releaseHighlights(json['highlights']),
    );
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'notes': notes,
    if (changes != null) 'changes': changes!.toJson(),
    if (highlights.isNotEmpty) 'highlights': highlights,
  };

  bool get isEmpty => notes.trim().isEmpty && (changes?.isEmpty ?? true) && highlights.isEmpty;
}

/// Where [WhatsNew] keeps its two values (settings box; tests: memory).
abstract class WhatsNewStore {
  /// The version whose card was shown (or that was installed fresh).
  String? get seen;
  Future<void> setSeen(String version);

  /// The notes last known for an installed or current version.
  ReleaseNotes? get notes;
  Future<void> setNotes(ReleaseNotes notes);

  /// The settings box was empty at start: a fresh install.
  bool get fresh;
}

class SettingsWhatsNewStore implements WhatsNewStore {
  final AppSettings settings;
  SettingsWhatsNewStore(this.settings);
  @override
  String? get seen => settings.whatsNewSeen;
  @override
  Future<void> setSeen(String version) => settings.setWhatsNewSeen(version);
  @override
  ReleaseNotes? get notes => ReleaseNotes.fromJson(settings.whatsNewNotes);
  @override
  Future<void> setNotes(ReleaseNotes notes) => settings.setWhatsNewNotes(notes.toJson());
  @override
  bool get fresh => settings.freshInstall;
}

class MemoryWhatsNewStore implements WhatsNewStore {
  @override
  String? seen;
  @override
  ReleaseNotes? notes;
  @override
  bool fresh;
  MemoryWhatsNewStore({this.seen, this.notes, this.fresh = false});
  @override
  Future<void> setSeen(String version) async => seen = version;
  @override
  Future<void> setNotes(ReleaseNotes notes) async => this.notes = notes;
}

/// Made once by `AppGraph` (the shell and About read it from there).
class WhatsNew {

  final String currentVersion;

  final WhatsNewStore store;

  WhatsNew({this.currentVersion = appVersion, required this.store});

  /// The card to show now (once); null when there is none.
  final due = ValueNotifier<ReleaseNotes?>(null);
  UpdateController? _updates;

  /// At start, settings loaded: a pending card for this version, and
  /// [updates]' checks from now on.
  void start(UpdateController updates) {
    if (!identical(_updates, updates)) {
      _updates?.latest.removeListener(_onManifest);
      _updates = updates..latest.addListener(_onManifest);
    }
    final s = store;
    if (s.seen == currentVersion) return;
    if (s.seen == null && s.fresh) {
      // A new install: nothing changed for this person.
      unawaited(s.setSeen(currentVersion));
      return;
    }
    final known = s.notes;
    if (known != null && known.version == currentVersion && !known.isEmpty) due.value = known;
  }

  void _onManifest() {
    final m = _updates?.latest.value;
    if (m != null) offer(ReleaseNotes.of(m));
  }

  /// Notes for some version (an update check's manifest). Kept when they
  /// are this version's; due when its card was not shown yet.
  void offer(ReleaseNotes n) {
    if (n.version != currentVersion || n.isEmpty) return;
    final s = store;
    unawaited(s.setNotes(n));
    if (s.seen != currentVersion && !s.fresh) due.value = n;
  }

  /// Before the restart into [m]: its notes for the first start.
  Future<void> installing(UpdateManifest m) => store.setNotes(ReleaseNotes.of(m));

  /// The card was shown: never again for this version.
  void shown() {
    due.value = null;
    unawaited(store.setSeen(currentVersion));
  }

  /// This version's notes, when known (Settings → About).
  ReleaseNotes? get current {
    final n = store.notes;
    return n != null && n.version == currentVersion && !n.isEmpty ? n : null;
  }
}
