import 'dart:math' as math;
import 'dart:typed_data';

// A tiny offline synthesizer for UI sounds, voiced as a Japanese house:
// koto strings (Karplus-Strong), a glass wind chime (furin), a singing
// bowl (rin), bamboo knocks, wooden clappers (hyoshigi) and the air of a
// sliding door (shoji). Renders to 16-bit mono WAV bytes. Pure Dart.

const sampleRate = 44100;

enum Voice {
  /// Plucked string; [Note.to] bends it (the delay line stretches).
  koto,
  /// Small glass bell: inharmonic partials, a slow shimmer.
  chime,
  /// Singing bowl: a soft strike and a long beating hum.
  rin,
  /// Hollow bamboo knock, pitched.
  bamboo,
  /// Two hardwood blocks struck together.
  clack,
  /// Breathy air sweeping up (a sliding door); [Note.hz]→[Note.to] is the
  /// sweep of its band.
  slide,
}

class Note {
  final double at;
  final double hz;
  final double? to;
  /// Length (s) to about -40 dB.
  final double len;
  final double gain;
  final Voice voice;
  /// Koto only: 0 = dark/muted pluck, 1 = bright.
  final double bright;
  const Note(this.at, this.hz, this.len,
      {this.to, this.gain = 1, this.voice = Voice.koto, this.bright = 0.6});
}

class SoundSpec {
  final List<Note> notes;
  /// Gentle low-pass cutoff (Hz) over the mix.
  final double cutoff;
  /// Peak level after normalising, dBFS (quiet by design).
  final double peakDb;
  /// Room tail mix (0..1): the veranda, not a hall.
  final double room;
  const SoundSpec(this.notes, {this.cutoff = 6000, this.peakDb = -17, this.room = 0.14});

  double get length =>
      notes.fold<double>(0, (m, n) => math.max(m, n.at + n.len)) + (room > 0 ? 0.25 : 0.02);
}

/// Semitones from A4 (440 Hz) to Hz.
double semi(num n) => 440 * math.pow(2, n / 12).toDouble();

Float64List render(SoundSpec spec, {int seed = 7}) {
  final total = (spec.length * sampleRate).ceil();
  final out = Float64List(total);
  final rnd = math.Random(seed);
  for (final n in spec.notes) {
    final start = (n.at * sampleRate).round();
    if (start >= total) continue;
    final s = switch (n.voice) {
      Voice.koto => _koto(n, rnd),
      Voice.chime => _bell(n, const [(1.0, 1.0, 1.0), (2.76, 0.45, 1.9), (5.40, 0.2, 3.2), (8.93, 0.08, 4.5)], 1.6, 0.003),
      Voice.rin => _bell(n, const [(1.0, 1.0, 1.0), (2.71, 0.35, 1.5), (5.15, 0.12, 2.4)], 2.4, 0.012),
      Voice.bamboo => _bamboo(n, rnd),
      Voice.clack => _clack(n, rnd),
      Voice.slide => _slide(n, rnd),
    };
    for (var i = 0; i < s.length && start + i < total; i++) {
      out[start + i] += n.gain * s[i];
    }
  }
  _lowpass(out, spec.cutoff);
  if (spec.room > 0) _room(out, spec.room);
  // 1 ms in, 10 ms out: no clicks at either end.
  final fadeIn = (0.001 * sampleRate).round();
  for (var i = 0; i < fadeIn && i < total; i++) {
    out[i] *= i / fadeIn;
  }
  final fade = (0.01 * sampleRate).round();
  for (var i = 0; i < fade && i < total; i++) {
    out[total - 1 - i] *= i / fade;
  }
  var peak = 0.0;
  for (final v in out) {
    peak = math.max(peak, v.abs());
  }
  if (peak > 0) {
    final g = math.pow(10, spec.peakDb / 20) / peak;
    for (var i = 0; i < total; i++) {
      out[i] *= g;
    }
  }
  return out;
}

int _n(double secs) => (secs * sampleRate).round();
double _smooth(double t) => t * t * (3 - 2 * t);

/// Karplus-Strong with a fractional, movable delay: a noise burst in a
/// loop that loses a little of its highs each pass.
Float64List _koto(Note n, math.Random rnd) {
  final len = _n(n.len);
  final out = Float64List(len);
  final maxPeriod = sampleRate / math.min(n.hz, n.to ?? n.hz) + 4;
  final buf = Float64List(maxPeriod.ceil() + 4);
  final size = buf.length;
  // Excitation: noise, smoothed more for a darker pluck.
  final period0 = sampleRate / n.hz;
  var prev = 0.0;
  final smooth = 1 - (0.25 + 0.7 * n.bright);
  for (var i = 0; i < period0.ceil(); i++) {
    final x = rnd.nextDouble() * 2 - 1;
    prev = smooth * prev + (1 - smooth) * x;
    buf[i % size] = prev;
  }
  // Loop gain so the note reaches -40 dB at len.
  final loss = math.pow(0.01, 1 / (n.len * n.hz)).toDouble();
  var w = period0.ceil();
  var last = 0.0;
  for (var i = 0; i < len; i++) {
    final t = i / len;
    final hz = n.to == null ? n.hz : n.hz * math.pow(n.to! / n.hz, _smooth(math.min(1, t * 1.6)));
    // The two-point average below delays half a sample: take it off.
    final period = sampleRate / hz - 0.5;
    final r = w - period;
    final ri = r.floor();
    final f = r - ri;
    final a = buf[(ri % size + size) % size];
    final b = buf[((ri + 1) % size + size) % size];
    final y = a + (b - a) * f;
    // Two-point average = the string's damping; the 0.5 mix keeps it bright.
    final v = loss * (0.5 * y + 0.5 * last);
    last = y;
    buf[w % size] = v;
    w++;
    // A 3 ms attack takes the click off the pluck.
    out[i] = v * (i < 132 ? i / 132 : 1);
  }
  return out;
}

/// Inharmonic partials (ratio, amplitude, decay multiplier), each doubled
/// with a slightly detuned twin so the tail shimmers.
Float64List _bell(Note n, List<(double, double, double)> partials, double beatHz, double attackSecs) {
  final len = _n(n.len);
  final out = Float64List(len);
  final k = math.log(100) / len;
  final attack = _n(attackSecs);
  for (final (ratio, amp, decay) in partials) {
    final f1 = n.hz * ratio, f2 = f1 + beatHz * ratio;
    for (var i = 0; i < len; i++) {
      final env = math.exp(-k * decay * i) * (i < attack ? _smooth(i / attack) : 1);
      final ph = 2 * math.pi * i / sampleRate;
      out[i] += amp * env * 0.5 * (math.sin(ph * f1) + math.sin(ph * f2));
    }
  }
  return out;
}

/// A hollow tube: a pitched thump that drops into its note, an overtone
/// that dies fast, and a short click of air.
Float64List _bamboo(Note n, math.Random rnd) {
  final len = _n(n.len);
  final out = Float64List(len);
  final k = math.log(100) / len;
  var ph = 0.0, ph2 = 0.0;
  for (var i = 0; i < len; i++) {
    final drop = math.exp(-i / _n(0.012));
    final hz = n.hz * (1 + 0.5 * drop);
    ph += 2 * math.pi * hz / sampleRate;
    ph2 += 2 * math.pi * hz * 2.31 / sampleRate;
    out[i] = math.exp(-k * i) * (math.sin(ph) + 0.35 * math.sin(ph2) * math.exp(-k * 3 * i));
  }
  final click = _bandNoise(_n(0.006), n.hz * 3, 2.0, rnd);
  for (var i = 0; i < click.length && i < len; i++) {
    out[i] += 0.5 * click[i] * (1 - i / click.length);
  }
  return out;
}

/// Hardwood: two resonances excited by a very short noise burst.
Float64List _clack(Note n, math.Random rnd) {
  final len = _n(n.len);
  final out = Float64List(len);
  final burst = Float64List(len);
  for (var i = 0; i < _n(0.002) && i < len; i++) {
    burst[i] = rnd.nextDouble() * 2 - 1;
  }
  for (final (f, q, g) in [(n.hz, 18.0, 1.0), (n.hz * 1.47, 14.0, 0.6), (n.hz * 2.6, 10.0, 0.25)]) {
    final r = _biquadBand(burst, f, q);
    for (var i = 0; i < len; i++) {
      out[i] += g * r[i];
    }
  }
  final k = math.log(100) / len;
  for (var i = 0; i < len; i++) {
    out[i] *= math.exp(-k * i);
  }
  return out;
}

/// Air through a band that sweeps from [Note.hz] to [Note.to], swelling in
/// and out (a paper door sliding along its track).
Float64List _slide(Note n, math.Random rnd) {
  final len = _n(n.len);
  final noise = Float64List(len);
  for (var i = 0; i < len; i++) {
    noise[i] = rnd.nextDouble() * 2 - 1;
  }
  final out = Float64List(len);
  // Sweep in short blocks (a fixed band per block is plenty).
  const block = 256;
  var z1 = 0.0, z2 = 0.0;
  for (var b0 = 0; b0 < len; b0 += block) {
    final t = b0 / len;
    final f = n.hz * math.pow((n.to ?? n.hz) / n.hz, t);
    final c = _bandCoeffs(f.toDouble(), 2.5);
    for (var i = b0; i < math.min(len, b0 + block); i++) {
      final y = c.$1 * noise[i] + z1;
      z1 = c.$2 * noise[i] - c.$4 * y + z2;
      z2 = c.$3 * noise[i] - c.$5 * y;
      final tt = i / len;
      // Rises, holds, eases off: sin^2 swell with a tail.
      final env = math.pow(math.sin(math.pi * math.min(1, tt * 1.25)), 2).toDouble();
      // The track's grain: a slow flutter.
      final grain = 1 + 0.25 * math.sin(2 * math.pi * 23 * i / sampleRate);
      out[i] = y * env * grain;
    }
  }
  return out;
}

Float64List _bandNoise(int len, double f, double q, math.Random rnd) {
  final x = Float64List(len);
  for (var i = 0; i < len; i++) {
    x[i] = rnd.nextDouble() * 2 - 1;
  }
  return _biquadBand(x, f, q);
}

/// RBJ band-pass (constant 0 dB peak): (b0, b1, b2, a1, a2), b1 = 0.
(double, double, double, double, double) _bandCoeffs(double f, double q) {
  final w = 2 * math.pi * math.min(f, sampleRate * 0.45) / sampleRate;
  final alpha = math.sin(w) / (2 * q);
  final a0 = 1 + alpha;
  return (alpha / a0, 0, -alpha / a0, -2 * math.cos(w) / a0, (1 - alpha) / a0);
}

Float64List _biquadBand(Float64List x, double f, double q) {
  final c = _bandCoeffs(f, q);
  final y = Float64List(x.length);
  var z1 = 0.0, z2 = 0.0;
  for (var i = 0; i < x.length; i++) {
    final v = c.$1 * x[i] + z1;
    z1 = c.$2 * x[i] - c.$4 * v + z2;
    z2 = c.$3 * x[i] - c.$5 * v;
    y[i] = v;
  }
  return y;
}

/// One pole, twice: a soft 12 dB/oct roll-off.
void _lowpass(Float64List out, double cutoff) {
  final a = math.exp(-2 * math.pi * cutoff / sampleRate);
  for (var pass = 0; pass < 2; pass++) {
    var y = 0.0;
    for (var i = 0; i < out.length; i++) {
      y = (1 - a) * out[i] + a * y;
      out[i] = y;
    }
  }
}

/// A few feedback delays: wood and paper walls, a short tail.
void _room(Float64List out, double mix) {
  const taps = [0.029, 0.041, 0.059];
  final dry = Float64List.fromList(out);
  for (final d in taps) {
    final delay = _n(d);
    final buf = Float64List(out.length);
    for (var i = delay; i < out.length; i++) {
      buf[i] = dry[i - delay] + 0.42 * buf[i - delay];
    }
    for (var i = 0; i < out.length; i++) {
      out[i] += mix / taps.length * buf[i];
    }
  }
}

/// 16-bit PCM mono WAV.
Uint8List wav(Float64List samples) {
  final data = samples.length * 2;
  final b = ByteData(44 + data);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + data, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, data, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    b.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}
