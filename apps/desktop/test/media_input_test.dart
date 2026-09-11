import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/src/widgets/media_input.dart';

void main() {
  test('http url routes to linkUrl', () {
    expect(parseMediaInput('http://example.com/v.mp4'),
        (mediaPath: '', linkUrl: 'http://example.com/v.mp4'));
  });

  test('https url routes to linkUrl', () {
    expect(parseMediaInput('https://example.com/v.mp4'),
        (mediaPath: '', linkUrl: 'https://example.com/v.mp4'));
  });

  test('scheme match is case-insensitive and trimmed', () {
    expect(parseMediaInput('  HTTPS://example.com/v.mp4  '),
        (mediaPath: '', linkUrl: 'HTTPS://example.com/v.mp4'));
  });

  test('file path routes to mediaPath', () {
    expect(parseMediaInput('/home/u/Videos/chiyo.mp4'),
        (mediaPath: '/home/u/Videos/chiyo.mp4', linkUrl: ''));
  });

  test('empty input stays empty', () {
    expect(parseMediaInput('   '), (mediaPath: '', linkUrl: ''));
  });

  test('non-http scheme stays a path', () {
    expect(parseMediaInput('ftp://example.com/v.mp4'),
        (mediaPath: 'ftp://example.com/v.mp4', linkUrl: ''));
  });
}
