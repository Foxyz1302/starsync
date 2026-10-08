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
  const NowPlaying({required this.title, this.episode, this.posterHash = '', this.bannerHash = ''});

  @override
  bool operator ==(Object other) =>
      other is NowPlaying &&
      other.title == title &&
      other.episode == episode &&
      other.posterHash == posterHash &&
      other.bannerHash == bannerHash;

  @override
  int get hashCode => Object.hash(title, episode, posterHash, bannerHash);
}
