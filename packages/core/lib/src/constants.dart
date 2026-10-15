abstract class RelayConstants {
  /// The wire version this build speaks best (`hello.proto`,
  /// `welcome.proto`); always [protoMax].
  static const int protoVersion = protoMax;
  /// The range of wire versions this build accepts (`hello.protoMin` ..
  /// `hello.proto` on a client, `/health.protoMin` .. `protoMax` on a
  /// server). Additions within a version family raise [protoMax] only.
  static const int protoMin = 16;
  static const int protoMax = 16;

  // Relay (`/r/...`): a member's bytes through the server's buffer.
  static const int relaySliceBytes = 1 << 20;
  static const int relayFrameBytes = 64 * 1024;
  /// Defaults for the buffer; they mirror a viewer's mpv buffer (150 s /
  /// 256 MiB ahead, 64 MiB back), so whatever a viewer may seek to soon is
  /// already on the server.
  static const int relayAheadBytes = 256 << 20;
  static const int relayBackBytes = 64 << 20;
  /// Kept regardless of position: containers keep their index at the start
  /// or the end, and players read both on open and on seeks.
  static const int relayPinBytes = 2 << 20;
  /// A relayed media of several tracks splits the buffer by bitrate; no
  /// track gets less than this ahead or behind.
  static const int relayTrackFloorBytes = 8 << 20;
  /// Upstream GETs are split into ranges of at most this (yt-dlp's
  /// `http_chunk_size` when it gives one): YouTube throttles longer ones to
  /// about twice the bitrate.
  static const int relayUpstreamChunkBytes = 10 << 20;
  static const int relayMinWindowBytes = 256 * 1024;
  static const int relayMaxWindowBytes = 8 << 20;
  /// A viewer request waits this long for its bytes (source away) before
  /// the server gives up on it.
  static const int relayWaitSecs = 60;
  /// The warm relay (Up next's first relayed item, before it goes up)
  /// keeps this much ahead of and behind its viewers' preloads, besides
  /// the pins: about what a preload player reads ahead (48 MiB), never the
  /// whole media.
  static const int relayWarmAheadBytes = 32 << 20;
  static const int relayWarmBackBytes = 8 << 20;

  static const int seekDebounceMs = 300;
  static const double driftSeekThresholdSecs = 5.0;
  static const double slowDownThresholdSecs = 1.5;
  static const double slowDownRate = 0.95;
  static const double minBufferSecs = 4.0;
  /// Near the end the buffer requirement is what is left minus this, so a
  /// client slightly ahead of the clock (or whose last packet ends a bit
  /// early) still passes.
  static const double endSlackSecs = 2.0;
  static const double resumeHysteresisSecs = 4.0;

  static const int stateHeartbeatSecs = 1;
  static const int pingIntervalSecs = 5;
  /// Server liveness defaults ([Liveness], PROTOCOL.md "Presence"): a
  /// socket without a frame for [silenceSecs] is closed and its member is
  /// `gone`; a `gone` member is kept [graceSecs] (`welcome.grace`), then
  /// it leaves; the feed says `gone` only after [goneNoticeSecs] (a quick
  /// return says nothing). A joiner holds a HELD gate at most
  /// [joinerHoldSecs] (D2) and stays `joining` at most [joiningTimeoutSecs].
  static const int silenceSecs = 15;
  static const int graceSecs = 600;
  static const int goneNoticeSecs = 10;
  static const int joinerHoldSecs = 15;
  static const int joiningTimeoutSecs = 60;
  /// Feed lines the server keeps for `hello.feedAfter` (the replay in
  /// `welcome.feed`).
  static const int feedReplayLines = 50;
  /// `hello.client`: an opaque per-install id, base64url, this long.
  static const int minClientIdLength = 16;
  static const int maxClientIdLength = 64;
  /// `media.ref` ([MediaRef]) as JSON: at most this many bytes.
  static const int maxMediaRefBytes = 2048;

  // Base64-char count of the avatar string, enforced at hello and
  // profile. 256 KiB leaves wide headroom over any 128x128 pipeline PNG
  // (raw bitmap <= 64 KiB, worst-case base64 ~95 KiB chars) — deliberate
  // over-size for private-server use. PNG keeps transparency; JPEG did
  // not. Only the hash rides in `state`; the bytes are fetched once.
  static const int maxAvatarBytes = 256 * 1024;
  /// Decoded-byte caps of the current media's art (`art` message).
  static const int maxPosterBytes = 256 * 1024;
  static const int maxBannerBytes = 768 * 1024;
  static const int maxNameLength = 32;
  static const int maxChatLength = 500;
  /// Characters of `report.error` the server keeps.
  static const int maxMemberErrorLength = 120;
  /// Nudges one member may send: at most this many per second and per
  /// minute; the server drops the rest silently.
  static const int nudgesPerSec = 3;
  static const int nudgesPerMin = 20;

  /// Up next (`queue`): at most this many items; a title or second line
  /// is cut to [maxQueueTextLength] characters; an item's picture is
  /// capped like a poster ([maxPosterBytes]). A play request nobody acts on
  /// ends after [queuePlayTimeoutSecs].
  static const int maxQueueItems = 100;
  static const int maxQueueTextLength = 200;
  static const int queuePlayTimeoutSecs = 30;

  /// Diagnostics sharing (`/l/...`, ARCHITECTURE "Logging"): a member's
  /// batch carries at most [diagBatchBytes] of lines (gzip on the wire, at
  /// most [diagBatchBytes] compressed and [diagDecodedBytes] unpacked); it
  /// keeps up to [diagBufferBytes] while it cannot send (oldest dropped)
  /// and sends every [diagIntervalSecs]. The server takes at most
  /// [diagPostsPerMin] posts and [diagBytesPerMin] unpacked bytes per member
  /// and minute (429 beyond). A "Mark a problem" note is cut to
  /// [maxProblemNoteLength] characters.
  static const int diagBatchBytes = 256 * 1024;
  static const int diagDecodedBytes = 1 << 20;
  static const int diagBufferBytes = 2 << 20;
  static const int diagIntervalSecs = 10;
  static const int diagPostsPerMin = 30;
  static const int diagBytesPerMin = 4 << 20;
  static const int maxProblemNoteLength = 200;
}
