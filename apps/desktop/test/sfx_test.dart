import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/src/sfx/sfx.dart';
import 'package:watch_together/src/sfx/sound_bank.dart';
import 'package:watch_together/src/sfx/synth.dart';

double _pitch(List<double> x, int from) {
  final c = <double>[];
  for (var l = 0; l < 700; l++) {
    var s = 0.0;
    for (var i = from; i < from + 2048; i++) {
      s += x[i] * x[i + l];
    }
    c.add(s);
  }
  var best = 0.0, lag = 0.0;
  for (var l = 30; l < 699; l++) {
    if (c[l] > best && c[l] >= c[l - 1] && c[l] >= c[l + 1]) {
      best = c[l];
      lag = l + (c[l - 1] - c[l + 1]) / (2 * (c[l - 1] - 2 * c[l] + c[l + 1]));
    }
  }
  return sampleRate / lag;
}

void main() {
  test('every sound is described, quiet, short and clean', () {
    for (final k in SfxKind.values) {
      expect(soundInfo[k], isNotNull, reason: k.name);
      final r = render(soundFor(k));
      final peak = r.fold<double>(0, (m, v) => math.max(m, v.abs()));
      expect(20 * math.log(peak) / math.ln10, lessThanOrEqualTo(-16.9), reason: '${k.name} peak');
      expect(r.length / sampleRate, lessThan(3), reason: '${k.name} length');
      expect(r.every((v) => v.isFinite), isTrue, reason: k.name);
      expect(r.first.abs() + r.last.abs(), lessThan(1e-3), reason: '${k.name} clicks');
    }
  });

  test('the ready ladder climbs and stays in range', () {
    expect(render(readySound(0)), render(readySound(1)));
    expect(render(readySound(99)), render(readySound(6)));
  });

  test('koto strings are in tune', () {
    for (final hz in [293.66, 587.33, 880.0, 1174.66]) {
      final r = render(SoundSpec([Note(0, hz, 1.0)], room: 0, cutoff: 20000));
      final cents = 1200 * math.log(_pitch(r, 2000) / hz) / math.ln2;
      expect(cents.abs(), lessThan(5), reason: '$hz');
    }
  });

  test('wav header and length', () {
    final b = wav(render(soundFor(SfxKind.chat)));
    expect(String.fromCharCodes(b.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(b.sublist(8, 12)), 'WAVE');
    expect(b.length, 44 + render(soundFor(SfxKind.chat)).length * 2);
  });
}
