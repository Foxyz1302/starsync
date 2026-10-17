import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/platform/ports/player_host.dart';

// ffmpeg's lost stream (its HTTP context lost the file's size, every seek
// fails until a fresh open): the lines the coordinator reloads the video
// on, once per media.
void main() {
  test('a seek that failed for want of the size is a lost stream', () {
    expect(mpvStreamLost(const PlayerLogLine('ffmpeg', 'error', 'Seek failed (to 3417735, size -38)')), isTrue);
    expect(mpvStreamLost(const PlayerLogLine('ffmpeg', 'warn', 'Seek failed (to 11997, size -38)\n')), isTrue);
  });

  test('anything else is not', () {
    // A seek that failed with the size known, a reconnect, another prefix.
    expect(mpvStreamLost(const PlayerLogLine('ffmpeg', 'error', 'Seek failed (to 20851, size 1023081)')), isFalse);
    expect(mpvStreamLost(const PlayerLogLine('ffmpeg', 'warn', 'http: Will reconnect at 3407872 in 0 second(s)')),
        isFalse);
    expect(mpvStreamLost(const PlayerLogLine('lavf', 'warn', 'Seek failed (to 1, size -38)')), isFalse);
  });
}
