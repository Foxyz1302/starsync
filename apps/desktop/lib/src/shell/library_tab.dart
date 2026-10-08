import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart' show HelloMedia;

import '../jellyfin/accounts.dart';
import '../jellyfin/browse_scope.dart' show BrowseStart;
import '../jellyfin/session_media.dart';
import '../screens/home/media_picker.dart';
import '../screens/session/swap_panel.dart';

/// What putting up a Jellyfin pick sends: its ref (no URL, no token).
/// Throws [FormatException] with a user-facing message when the server is
/// not linked any more or its sign-in expired.
HelloMedia putUpJellyfinMedia(JellyfinAccounts accounts, JellyfinMedia media) {
  if (accounts.account(media.serverId) == null) {
    throw const FormatException('that Jellyfin server is not linked any more — pick again');
  }
  if (accounts.statusOf(media.serverId) == JellyfinAccountStatus.expired) {
    throw const FormatException('Jellyfin sign-in expired — reconnect it in Settings → Jellyfin & integrations');
  }
  return mediaForPick(media);
}

/// Brings back the last Jellyfin pick (kept in the Jellyfin box) once the
/// accounts are read, unless something else was picked meanwhile or
/// [alive] says the picker is gone.
Future<void> restoreLastPick(
    MediaPickerController c, JellyfinAccounts accounts, bool Function() alive) async {
  final hadMedia = c.selection != null;
  try {
    await accounts.ensureLoaded();
  } catch (_) {
    return;
  }
  final pick = accounts.lastPick;
  if (!alive() || pick == null || c.jellyfin != null) return;
  if (accounts.account(pick.serverId) == null) return;
  final source = c.source;
  c.pickJellyfin(pick);
  if (hadMedia) c.source = source;
}

/// Library (round 1): the media picker as the "put it up" view. Offline
/// it browses, with a hint that watching needs a server.
class LibraryTab extends StatelessWidget {
  final MediaPickerController controller;
  final JellyfinAccounts accounts;
  final bool online;
  final bool isHost;
  final BrowseStart? jellyfinStart;
  /// Puts the pick up; returns an error text, or null when sent.
  final Future<String?> Function(PickedMedia media) onPutUp;
  final VoidCallback? onPutUpDone;
  final VoidCallback? onOpenIntegrations;
  const LibraryTab({
    super.key,
    required this.controller,
    required this.accounts,
    required this.online,
    required this.isHost,
    required this.onPutUp,
    this.onPutUpDone,
    this.jellyfinStart,
    this.onOpenIntegrations,
  });

  @override
  Widget build(BuildContext context) {
    return SwapPanel(
      controller: controller,
      accounts: accounts,
      isHost: isHost,
      jellyfinStart: jellyfinStart,
      onSwap: onPutUp,
      onDone: onPutUpDone,
      onOpenIntegrations: onOpenIntegrations,
      disabledHint: online ? null : 'Join or host to watch together',
    );
  }
}
