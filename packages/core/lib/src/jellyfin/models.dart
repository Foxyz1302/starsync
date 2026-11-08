/// Typed views of Jellyfin API JSON. Only the fields a client UI and the
/// player need; everything is parsed leniently (missing fields become null,
/// false or 0) because Jellyfin omits fields freely.
library;

/// Jellyfin positions and durations are in ticks: 10,000,000 per second.
const int jellyfinTicksPerSecond = 10000000;

int durationToTicks(Duration d) => d.inMicroseconds * 10;
Duration ticksToDuration(int ticks) => Duration(microseconds: ticks ~/ 10);

typedef JellyfinJson = Map<String, dynamic>;

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
int? _int(Object? v) => v is num ? v.toInt() : null;
double? _double(Object? v) => v is num ? v.toDouble() : null;
bool _bool(Object? v) => v == true;
DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;
List<JellyfinJson> _list(Object? v) =>
    v is List ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() : const [];

/// /System/Info/Public. [id] is the ServerId: the stable key for a linked
/// server (URLs may change, the id does not).
class JellyfinServerInfo {
  final String id;
  final String name;
  final String version;
  const JellyfinServerInfo({required this.id, required this.name, required this.version});

  factory JellyfinServerInfo.fromJson(JellyfinJson j) => JellyfinServerInfo(
        id: _str(j['Id']) ?? '',
        name: _str(j['ServerName']) ?? '',
        version: _str(j['Version']) ?? '',
      );
}

class JellyfinUser {
  final String id;
  final String name;
  final String? serverId;
  final String? primaryImageTag;
  final bool isAdministrator;
  const JellyfinUser({
    required this.id,
    required this.name,
    this.serverId,
    this.primaryImageTag,
    this.isAdministrator = false,
  });

  factory JellyfinUser.fromJson(JellyfinJson j) => JellyfinUser(
        id: _str(j['Id']) ?? '',
        name: _str(j['Name']) ?? '',
        serverId: _str(j['ServerId']),
        primaryImageTag: _str(j['PrimaryImageTag']),
        isAdministrator: _bool((j['Policy'] as Map?)?['IsAdministrator']),
      );
}

/// Result of a sign-in. Persist [accessToken], [user].id and [serverId]
/// (keyed by ServerId); the token stays valid until logout or revocation.
class JellyfinAuthResult {
  final String accessToken;
  final JellyfinUser user;
  final String serverId;
  const JellyfinAuthResult({required this.accessToken, required this.user, required this.serverId});

  factory JellyfinAuthResult.fromJson(JellyfinJson j) {
    final user = JellyfinUser.fromJson((j['User'] as Map? ?? const {}).cast<String, dynamic>());
    return JellyfinAuthResult(
      accessToken: _str(j['AccessToken']) ?? '',
      user: user,
      serverId: _str(j['ServerId']) ?? user.serverId ?? '',
    );
  }
}

/// A pending Quick Connect request. Show [code] to the user (they enter it
/// in Jellyfin: user menu > Quick Connect); keep [secret] private, it is
/// what the app polls and signs in with.
class QuickConnectSession {
  final String code;
  final String secret;
  final bool authenticated;
  const QuickConnectSession({required this.code, required this.secret, this.authenticated = false});

  factory QuickConnectSession.fromJson(JellyfinJson j) => QuickConnectSession(
        code: _str(j['Code']) ?? '',
        secret: _str(j['Secret']) ?? '',
        authenticated: _bool(j['Authenticated']),
      );
}

/// Per-user state of an item.
class JellyfinUserData {
  final bool played;
  final int playbackPositionTicks;
  final int playCount;
  final bool isFavorite;
  /// Folders (series, seasons) only: episodes left to watch.
  final int? unplayedItemCount;
  final double? playedPercentage;
  final DateTime? lastPlayedDate;
  const JellyfinUserData({
    this.played = false,
    this.playbackPositionTicks = 0,
    this.playCount = 0,
    this.isFavorite = false,
    this.unplayedItemCount,
    this.playedPercentage,
    this.lastPlayedDate,
  });

  factory JellyfinUserData.fromJson(JellyfinJson j) => JellyfinUserData(
        played: _bool(j['Played']),
        playbackPositionTicks: _int(j['PlaybackPositionTicks']) ?? 0,
        playCount: _int(j['PlayCount']) ?? 0,
        isFavorite: _bool(j['IsFavorite']),
        unplayedItemCount: _int(j['UnplayedItemCount']),
        playedPercentage: _double(j['PlayedPercentage']),
        lastPlayedDate: _date(j['LastPlayedDate']),
      );

  Duration get position => ticksToDuration(playbackPositionTicks);

  /// Has a resume point (Continue Watching).
  bool get isResumable => playbackPositionTicks > 0;
}

/// Image kinds a UI uses. Backdrop can have several (index), the rest one.
enum JellyfinImageType {
  primary('Primary'),
  backdrop('Backdrop'),
  thumb('Thumb'),
  logo('Logo'),
  banner('Banner');

  final String apiName;
  const JellyfinImageType(this.apiName);
}

/// A concrete image: which item owns it and its tag. The tag changes when
/// the image changes, so `(itemId, type, index, tag, maxWidth)` is a safe
/// cache key. Build the URL with `JellyfinClient.imageUrl`.
class JellyfinImageRef {
  final String itemId;
  final JellyfinImageType type;
  final String tag;
  final int index;
  const JellyfinImageRef(this.itemId, this.type, this.tag, {this.index = 0});

  @override
  bool operator ==(Object other) =>
      other is JellyfinImageRef &&
      other.itemId == itemId &&
      other.type == type &&
      other.tag == tag &&
      other.index == index;

  @override
  int get hashCode => Object.hash(itemId, type, tag, index);
}

/// Item types the app distinguishes; anything else is [other].
enum JellyfinItemKind {
  movie,
  series,
  season,
  episode,
  folder,
  collectionFolder,
  boxSet,
  video,
  other;

  static JellyfinItemKind parse(String? type) => switch (type) {
        'Movie' => movie,
        'Series' => series,
        'Season' => season,
        'Episode' => episode,
        'Folder' => folder,
        'CollectionFolder' || 'UserView' => collectionFolder,
        'BoxSet' => boxSet,
        'Video' || 'MusicVideo' => video,
        _ => other,
      };
}

/// One library item (view, series, season, episode, movie, folder...).
class JellyfinItem {
  final String id;
  final String name;
  /// Raw Jellyfin type ("Episode", "Series", ...); see [kind].
  final String type;
  final String? serverId;
  final bool isFolder;
  /// Libraries only: "movies", "tvshows", "homevideos", ...
  final String? collectionType;
  final String? overview;
  /// The title in its own language (a Japanese show's Japanese title);
  /// needs `OriginalTitle` in `fields` ([JellyfinClient.allSeries]).
  final String? originalTitle;
  final int? productionYear;
  final DateTime? premiereDate;
  /// When the item was added to the library (needs `DateCreated` in
  /// `fields`; [JellyfinClient.listFields] has it).
  final DateTime? dateCreated;
  final double? communityRating;
  final String? officialRating;
  final int? runTimeTicks;
  final String? container;
  final String? mediaType;

  // Episodes / seasons.
  final String? seriesId;
  final String? seriesName;
  final String? seasonId;
  final String? seasonName;
  /// Episode number, or season number for a season.
  final int? indexNumber;
  /// Season number of an episode.
  final int? parentIndexNumber;
  final int? childCount;
  final int? recursiveItemCount;

  final JellyfinUserData userData;
  final double? primaryImageAspectRatio;
  final Map<String, String> imageTags;
  final List<String> backdropImageTags;
  final String? seriesPrimaryImageTag;
  final String? parentBackdropItemId;
  final List<String> parentBackdropImageTags;
  final String? parentThumbItemId;
  final String? parentThumbImageTag;
  final String? parentLogoItemId;
  final String? parentLogoImageTag;

  /// Ids on other databases (`AniList`, `Tvdb`, `Imdb`...), as Jellyfin's
  /// metadata plugins set them; empty when none or not requested.
  final Map<String, String> providerIds;

  /// Present on full item responses (`getItem`) for playable items.
  final List<JellyfinMediaSource> mediaSources;
  /// Streams of the default source; present on `getItem` and when
  /// MediaStreams was requested in `fields`.
  final List<JellyfinMediaStream> mediaStreams;

  const JellyfinItem({
    required this.id,
    required this.name,
    required this.type,
    this.serverId,
    this.isFolder = false,
    this.collectionType,
    this.overview,
    this.originalTitle,
    this.productionYear,
    this.premiereDate,
    this.dateCreated,
    this.communityRating,
    this.officialRating,
    this.runTimeTicks,
    this.container,
    this.mediaType,
    this.seriesId,
    this.seriesName,
    this.seasonId,
    this.seasonName,
    this.indexNumber,
    this.parentIndexNumber,
    this.childCount,
    this.recursiveItemCount,
    this.userData = const JellyfinUserData(),
    this.primaryImageAspectRatio,
    this.imageTags = const {},
    this.backdropImageTags = const [],
    this.seriesPrimaryImageTag,
    this.parentBackdropItemId,
    this.parentBackdropImageTags = const [],
    this.parentThumbItemId,
    this.parentThumbImageTag,
    this.parentLogoItemId,
    this.parentLogoImageTag,
    this.providerIds = const {},
    this.mediaSources = const [],
    this.mediaStreams = const [],
  });

  factory JellyfinItem.fromJson(JellyfinJson j) => JellyfinItem(
        id: _str(j['Id']) ?? '',
        name: _str(j['Name']) ?? '',
        type: _str(j['Type']) ?? '',
        serverId: _str(j['ServerId']),
        isFolder: _bool(j['IsFolder']),
        collectionType: _str(j['CollectionType']),
        overview: _str(j['Overview']),
        originalTitle: _str(j['OriginalTitle']),
        productionYear: _int(j['ProductionYear']),
        premiereDate: _date(j['PremiereDate']),
        dateCreated: _date(j['DateCreated']),
        communityRating: _double(j['CommunityRating']),
        officialRating: _str(j['OfficialRating']),
        runTimeTicks: _int(j['RunTimeTicks']),
        container: _str(j['Container']),
        mediaType: _str(j['MediaType']),
        seriesId: _str(j['SeriesId']),
        seriesName: _str(j['SeriesName']),
        seasonId: _str(j['SeasonId']),
        seasonName: _str(j['SeasonName']),
        indexNumber: _int(j['IndexNumber']),
        parentIndexNumber: _int(j['ParentIndexNumber']),
        childCount: _int(j['ChildCount']),
        recursiveItemCount: _int(j['RecursiveItemCount']),
        userData: JellyfinUserData.fromJson(
            (j['UserData'] as Map? ?? const {}).cast<String, dynamic>()),
        primaryImageAspectRatio: _double(j['PrimaryImageAspectRatio']),
        imageTags: (j['ImageTags'] as Map? ?? const {})
            .map((k, v) => MapEntry(k.toString(), v.toString())),
        backdropImageTags: _strings(j['BackdropImageTags']),
        seriesPrimaryImageTag: _str(j['SeriesPrimaryImageTag']),
        parentBackdropItemId: _str(j['ParentBackdropItemId']),
        parentBackdropImageTags: _strings(j['ParentBackdropImageTags']),
        parentThumbItemId: _str(j['ParentThumbItemId']),
        parentThumbImageTag: _str(j['ParentThumbImageTag']),
        parentLogoItemId: _str(j['ParentLogoItemId']),
        parentLogoImageTag: _str(j['ParentLogoImageTag']),
        providerIds: {
          for (final e in (j['ProviderIds'] as Map? ?? const {}).entries)
            if (e.value is String && (e.value as String).isNotEmpty) e.key.toString(): e.value as String,
        },
        mediaSources: _list(j['MediaSources']).map(JellyfinMediaSource.fromJson).toList(),
        mediaStreams: _list(j['MediaStreams']).map(JellyfinMediaStream.fromJson).toList(),
      );

  JellyfinItemKind get kind => JellyfinItemKind.parse(type);

  /// The same item with [userData] instead (a watched mark shown before
  /// the lists that hold it are fetched again).
  JellyfinItem withUserData(JellyfinUserData userData) => JellyfinItem(
        id: id,
        name: name,
        type: type,
        serverId: serverId,
        isFolder: isFolder,
        collectionType: collectionType,
        overview: overview,
        originalTitle: originalTitle,
        productionYear: productionYear,
        premiereDate: premiereDate,
        dateCreated: dateCreated,
        communityRating: communityRating,
        officialRating: officialRating,
        runTimeTicks: runTimeTicks,
        container: container,
        mediaType: mediaType,
        seriesId: seriesId,
        seriesName: seriesName,
        seasonId: seasonId,
        seasonName: seasonName,
        indexNumber: indexNumber,
        parentIndexNumber: parentIndexNumber,
        childCount: childCount,
        recursiveItemCount: recursiveItemCount,
        userData: userData,
        primaryImageAspectRatio: primaryImageAspectRatio,
        imageTags: imageTags,
        backdropImageTags: backdropImageTags,
        seriesPrimaryImageTag: seriesPrimaryImageTag,
        parentBackdropItemId: parentBackdropItemId,
        parentBackdropImageTags: parentBackdropImageTags,
        parentThumbItemId: parentThumbItemId,
        parentThumbImageTag: parentThumbImageTag,
        parentLogoItemId: parentLogoItemId,
        parentLogoImageTag: parentLogoImageTag,
        providerIds: providerIds,
        mediaSources: mediaSources,
        mediaStreams: mediaStreams,
      );

  /// A provider id as a number (`providerId('AniList')`), case-insensitive
  /// on the provider's name; null when absent or not a number.
  int? providerId(String provider) {
    final p = provider.toLowerCase();
    for (final e in providerIds.entries) {
      if (e.key.toLowerCase() == p) return int.tryParse(e.value.trim());
    }
    return null;
  }

  Duration? get runTime => runTimeTicks == null ? null : ticksToDuration(runTimeTicks!);

  /// "S2E12" for episodes with both numbers, else null.
  String? get episodeLabel => parentIndexNumber != null && indexNumber != null
      ? 'S${parentIndexNumber}E$indexNumber'
      : null;

  /// The item's own image of [type], if it has one.
  JellyfinImageRef? ownImage(JellyfinImageType type, {int index = 0}) {
    if (type == JellyfinImageType.backdrop) {
      return index < backdropImageTags.length
          ? JellyfinImageRef(id, type, backdropImageTags[index], index: index)
          : null;
    }
    final tag = imageTags[type.apiName];
    return tag == null ? null : JellyfinImageRef(id, type, tag);
  }

  /// Best image of [type] for display: the item's own, else the parent's
  /// (series/season art that Jellyfin inlines on episodes and seasons). For
  /// [JellyfinImageType.primary] on an episode or season without its own
  /// image this falls back to the series poster.
  JellyfinImageRef? image(JellyfinImageType type) {
    final own = ownImage(type);
    if (own != null) return own;
    switch (type) {
      case JellyfinImageType.primary:
        if (seriesId != null && seriesPrimaryImageTag != null) {
          return JellyfinImageRef(seriesId!, type, seriesPrimaryImageTag!);
        }
      case JellyfinImageType.backdrop:
        if (parentBackdropItemId != null && parentBackdropImageTags.isNotEmpty) {
          return JellyfinImageRef(parentBackdropItemId!, type, parentBackdropImageTags.first);
        }
      case JellyfinImageType.thumb:
        if (parentThumbItemId != null && parentThumbImageTag != null) {
          return JellyfinImageRef(parentThumbItemId!, type, parentThumbImageTag!);
        }
      case JellyfinImageType.logo:
        if (parentLogoItemId != null && parentLogoImageTag != null) {
          return JellyfinImageRef(parentLogoItemId!, type, parentLogoImageTag!);
        }
      case JellyfinImageType.banner:
        break;
    }
    return null;
  }
}

List<String> _strings(Object? v) =>
    v is List ? v.map((e) => e.toString()).toList() : const [];

/// A page of items. [startIndex] + items.length < [totalRecordCount] means
/// there is more.
class JellyfinItemPage {
  final List<JellyfinItem> items;
  final int totalRecordCount;
  final int startIndex;
  const JellyfinItemPage(this.items, {required this.totalRecordCount, this.startIndex = 0});

  factory JellyfinItemPage.fromJson(JellyfinJson j) {
    final items = _list(j['Items']).map(JellyfinItem.fromJson).toList();
    return JellyfinItemPage(
      items,
      totalRecordCount: _int(j['TotalRecordCount']) ?? items.length,
      startIndex: _int(j['StartIndex']) ?? 0,
    );
  }

  bool get hasMore => startIndex + items.length < totalRecordCount;
}

enum JellyfinStreamType {
  video,
  audio,
  subtitle,
  other;

  static JellyfinStreamType parse(String? s) => switch (s) {
        'Video' => video,
        'Audio' => audio,
        'Subtitle' => subtitle,
        _ => other,
      };
}

/// One track of a media source. [index] is Jellyfin's stream index: the
/// value for AudioStreamIndex / SubtitleStreamIndex in progress reports.
/// For embedded streams in an mkv it equals the ffprobe stream index, so
/// mpv's track id is the position among streams of the same type (mpv
/// counts audio and subtitle ids separately, from 1); see
/// [JellyfinMediaSource.mpvTrackId].
class JellyfinMediaStream {
  final int index;
  final JellyfinStreamType type;
  final String? codec;
  final String? language;
  final String? title;
  final String? displayTitle;
  final int? channels;
  final String? channelLayout;
  final bool isDefault;
  final bool isForced;
  final bool isExternal;
  final bool isHearingImpaired;
  final bool isTextSubtitleStream;
  /// External subtitles only: path on the server, not reachable by clients.
  final String? deliveryUrl;
  const JellyfinMediaStream({
    required this.index,
    required this.type,
    this.codec,
    this.language,
    this.title,
    this.displayTitle,
    this.channels,
    this.channelLayout,
    this.isDefault = false,
    this.isForced = false,
    this.isExternal = false,
    this.isHearingImpaired = false,
    this.isTextSubtitleStream = false,
    this.deliveryUrl,
  });

  factory JellyfinMediaStream.fromJson(JellyfinJson j) => JellyfinMediaStream(
        index: _int(j['Index']) ?? -1,
        type: JellyfinStreamType.parse(_str(j['Type'])),
        codec: _str(j['Codec']),
        language: _str(j['Language']),
        title: _str(j['Title']),
        displayTitle: _str(j['DisplayTitle']),
        channels: _int(j['Channels']),
        channelLayout: _str(j['ChannelLayout']),
        isDefault: _bool(j['IsDefault']),
        isForced: _bool(j['IsForced']),
        isExternal: _bool(j['IsExternal']),
        isHearingImpaired: _bool(j['IsHearingImpaired']),
        isTextSubtitleStream: _bool(j['IsTextSubtitleStream']),
        deliveryUrl: _str(j['DeliveryUrl']),
      );

  @override
  String toString() =>
      'JellyfinMediaStream($index ${type.name} $language "$title" $codec ${channels ?? ''})';
}

/// One playable version of an item (usually exactly one: the file).
class JellyfinMediaSource {
  final String id;
  final String? name;
  final String? container;
  final int? size;
  final int? bitrate;
  final int? runTimeTicks;
  final bool supportsDirectPlay;
  final bool supportsDirectStream;
  final int? defaultAudioStreamIndex;
  final int? defaultSubtitleStreamIndex;
  final List<JellyfinMediaStream> mediaStreams;
  const JellyfinMediaSource({
    required this.id,
    this.name,
    this.container,
    this.size,
    this.bitrate,
    this.runTimeTicks,
    this.supportsDirectPlay = false,
    this.supportsDirectStream = false,
    this.defaultAudioStreamIndex,
    this.defaultSubtitleStreamIndex,
    this.mediaStreams = const [],
  });

  factory JellyfinMediaSource.fromJson(JellyfinJson j) => JellyfinMediaSource(
        id: _str(j['Id']) ?? '',
        name: _str(j['Name']),
        container: _str(j['Container']),
        size: _int(j['Size']),
        bitrate: _int(j['Bitrate']),
        runTimeTicks: _int(j['RunTimeTicks']),
        supportsDirectPlay: _bool(j['SupportsDirectPlay']),
        supportsDirectStream: _bool(j['SupportsDirectStream']),
        defaultAudioStreamIndex: _int(j['DefaultAudioStreamIndex']),
        defaultSubtitleStreamIndex: _int(j['DefaultSubtitleStreamIndex']),
        mediaStreams: _list(j['MediaStreams']).map(JellyfinMediaStream.fromJson).toList(),
      );

  List<JellyfinMediaStream> streamsOf(JellyfinStreamType type) =>
      mediaStreams.where((s) => s.type == type).toList();

  JellyfinMediaStream? streamAt(int index) {
    for (final s in mediaStreams) {
      if (s.index == index) return s;
    }
    return null;
  }

  /// mpv track id (`aid` / `sid`, 1-based per type) of the embedded stream
  /// with Jellyfin [index], or null if it is external or unknown. Assumes
  /// mpv sees the same embedded streams in the same order as Jellyfin's
  /// probe (true for direct-played mkv/mp4).
  int? mpvTrackId(int index) {
    final s = streamAt(index);
    if (s == null || s.isExternal) return null;
    final sameType = mediaStreams
        .where((m) => m.type == s.type && !m.isExternal)
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final pos = sameType.indexWhere((m) => m.index == index);
    return pos < 0 ? null : pos + 1;
  }

  /// Inverse of [mpvTrackId].
  int? jellyfinIndexForMpvTrack(JellyfinStreamType type, int mpvId) {
    final sameType = mediaStreams
        .where((m) => m.type == type && !m.isExternal)
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    return mpvId >= 1 && mpvId <= sameType.length ? sameType[mpvId - 1].index : null;
  }
}

/// Result of PlaybackInfo. Report progress with [playSessionId] and the
/// chosen source's id.
class JellyfinPlaybackInfo {
  final String playSessionId;
  final List<JellyfinMediaSource> mediaSources;
  const JellyfinPlaybackInfo({required this.playSessionId, required this.mediaSources});

  factory JellyfinPlaybackInfo.fromJson(JellyfinJson j) => JellyfinPlaybackInfo(
        playSessionId: _str(j['PlaySessionId']) ?? '',
        mediaSources: _list(j['MediaSources']).map(JellyfinMediaSource.fromJson).toList(),
      );

  /// The source to direct-play: the first that supports it, else the first.
  JellyfinMediaSource? get primarySource {
    for (final s in mediaSources) {
      if (s.supportsDirectPlay) return s;
    }
    return mediaSources.isEmpty ? null : mediaSources.first;
  }
}

/// Kind of a [JellyfinMediaSegment] (Jellyfin `MediaSegmentType`).
enum JellyfinSegmentType {
  unknown,
  commercial,
  preview,
  recap,
  outro,
  intro;

  static JellyfinSegmentType parse(String? v) => switch (v) {
        'Commercial' => commercial,
        'Preview' => preview,
        'Recap' => recap,
        'Outro' => outro,
        'Intro' => intro,
        _ => unknown,
      };
}

/// A marked range of an item (`GET /MediaSegments/{itemId}`, Jellyfin
/// 10.10+): intro, outro, recap, preview or commercial. Filled by segment
/// provider plugins; without one the list is empty.
class JellyfinMediaSegment {
  final String id;
  final String itemId;
  final JellyfinSegmentType type;
  final int startTicks;
  final int endTicks;
  const JellyfinMediaSegment({
    required this.id,
    required this.itemId,
    required this.type,
    required this.startTicks,
    required this.endTicks,
  });

  Duration get start => ticksToDuration(startTicks);
  Duration get end => ticksToDuration(endTicks);

  factory JellyfinMediaSegment.fromJson(JellyfinJson j) => JellyfinMediaSegment(
        id: _str(j['Id']) ?? '',
        itemId: _str(j['ItemId']) ?? '',
        type: JellyfinSegmentType.parse(_str(j['Type'])),
        startTicks: _int(j['StartTicks']) ?? 0,
        endTicks: _int(j['EndTicks']) ?? 0,
      );

  @override
  String toString() => 'JellyfinMediaSegment(${type.name} $start-$end)';
}
