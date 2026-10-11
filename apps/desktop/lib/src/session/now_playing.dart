/// What the player shows about the current media: a title, an episode line
/// and art. Art is by content hash (`state.media.art`), fetched by everyone
/// (guests included) from the server they dialled; '' when there is none.
class NowPlaying {
  /// Series name for episodes, else the movie, file or link name.
  final String title;
  /// "S2 E4 · Episode title", "E12", or null (movies, links).
  final String? episode;
  /// Portrait cover (2:3) and wide banner; '' when none.
  final String posterHash;
  final String bannerHash;
  /// A web video: its art is its thumbnail (the same picture as cover and
  /// banner, or none yet), shown wide, under the video's own name.
  final bool thumbnail;
  const NowPlaying(
      {required this.title, this.episode, this.posterHash = '', this.bannerHash = '', this.thumbnail = false});

  @override
  bool operator ==(Object other) =>
      other is NowPlaying &&
      other.title == title &&
      other.episode == episode &&
      other.posterHash == posterHash &&
      other.bannerHash == bannerHash &&
      other.thumbnail == thumbnail;

  @override
  int get hashCode => Object.hash(title, episode, posterHash, bannerHash, thumbnail);
}
