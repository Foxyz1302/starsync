import 'dart:math' as math;
import 'dart:typed_data';

// A tiny offline synthesizer for UI sounds. The current palette is
// spacious: FM star bells, bubble drops, slow pads, a sub that falls away,
// stardust and a long dark space tail. Older voices (plucked string, glass
// and bowl bells, wood) stay available. Renders to 16-bit mono WAV bytes.
// Pure Dart.

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
  /// FM bell: strikes glassy, settles to a pure hanging tone; [Note.bright]
  /// scales the strike, [Note.to] glides it.
  star,
  /// A bubble: the pitch rises into the note fast; [Note.to] flicks it on.
  drop,
  /// Slow detuned swell (in over a third of its length, then out);
  /// [Note.bright] adds overtones, [Note.to] glides it.
  pad,
  /// Deep round tone that falls from [Note.hz] to [Note.to].
  sub,
  /// A scatter of tiny pings on the scale above [Note.hz], drifting
  /// towards [Note.to].
  dust,
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
  /// Space tail mix (0..1).
  final double room;
  /// Space tail decay to -60 dB (s); the sound keeps about half of it.
  final double tail;
  const SoundSpec(this.notes,
      {this.cutoff = 6000, this.peakDb = -17, this.room = 0.14, this.tail = 1.4});

  double get length =>
      notes.fold<double>(0, (m, n) => math.max(m, n.at + n.len)) + (room > 0 ? tail * 0.55 : 0.02);
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
      Voice.star => _star(n),
      Voice.drop => _drop(n),
      Voice.pad => _pad(n, rnd),
      Voice.sub => _sub(n),
      Voice.dust => _dust(n, rnd),
    };
    for (var i = 0; i < s.length && start + i < total; i++) {
      out[start + i] += n.gain * s[i];
    }
  }
  _lowpass(out, spec.cutoff);
  if (spec.room > 0) _space(out, spec.room, spec.tail);
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

/// Space: four damped feedback combs and two allpasses (a dark, smooth
/// tail decaying to -60 dB in [tail] s) after a short pre-delay.
void _space(Float64List out, double mix, double tail) {
  const combs = [0.0297, 0.0371, 0.0411, 0.0437];
  const damp = 0.35;
  final len = out.length;
  final pre = _n(0.018);
  final dry = Float64List(len);
  for (var i = pre; i < len; i++) {
    dry[i] = out[i - pre];
  }
  final wet = Float64List(len);
  for (final d in combs) {
    final delay = _n(d);
    final g = math.pow(0.001, d / tail).toDouble();
    final y = Float64List(len);
    var lp = 0.0;
    for (var i = 0; i < len; i++) {
      final back = i >= delay ? y[i - delay] : 0.0;
      lp = back * (1 - damp) + lp * damp;
      y[i] = dry[i] + g * lp;
      wet[i] += y[i] / combs.length;
    }
  }
  for (final d in const [0.005, 0.0017]) {
    final delay = _n(d);
    final x = Float64List.fromList(wet);
    for (var i = 0; i < len; i++) {
      final xd = i >= delay ? x[i - delay] : 0.0;
      final yd = i >= delay ? wet[i - delay] : 0.0;
      wet[i] = -0.5 * x[i] + xd + 0.5 * yd;
    }
  }
  for (var i = 0; i < len; i++) {
    out[i] += mix * wet[i];
  }
}

/// [Note.hz] gliding to [Note.to] over the first ~60% of the note.
double _glide(Note n, double t) =>
    n.to == null ? n.hz : n.hz * math.pow(n.to! / n.hz, _smooth(math.min(1, t * 1.6))).toDouble();

Float64List _star(Note n) {
  final len = _n(n.len);
  final out = Float64List(len);
  final k = math.log(100) / len;
  final attack = _n(0.004);
  final index0 = 0.3 + 3.0 * n.bright;
  final idxTau = _n(0.09 + 0.12 * n.bright);
  const ratio = 3.5;
  var c1 = 0.0, c2 = 0.0, m1 = 0.0, m2 = 0.0;
  for (var i = 0; i < len; i++) {
    final hz = _glide(n, i / len);
    final w = 2 * math.pi * hz / sampleRate;
    c1 += w;
    c2 += w * 1.0017;
    m1 += w * ratio;
    m2 += w * ratio * 1.0017;
    final idx = index0 * math.exp(-i / idxTau);
    final env = math.exp(-k * i) * (i < attack ? _smooth(i / attack) : 1);
    out[i] = env * 0.5 * (math.sin(c1 + idx * math.sin(m1)) + math.sin(c2 + idx * math.sin(m2)));
  }
  return out;
}

Float64List _drop(Note n) {
  final len = _n(n.len);
  final out = Float64List(len);
  final k = math.log(100) / len;
  final attack = _n(0.002);
  final riseTau = _n(0.016);
  var ph = 0.0;
  for (var i = 0; i < len; i++) {
    final t = i / len;
    final base = n.to == null ? n.hz : n.hz * math.pow(n.to! / n.hz, _smooth(math.min(1, t * 2.5)));
    final hz = base * (0.62 + 0.38 * (1 - math.exp(-i / riseTau)));
    ph += 2 * math.pi * hz / sampleRate;
    final env = math.exp(-k * i) * (i < attack ? _smooth(i / attack) : 1);
    out[i] = env * (math.sin(ph) + 0.15 * math.sin(2 * ph));
  }
  return out;
}

Float64List _pad(Note n, math.Random rnd) {
  final len = _n(n.len);
  final out = Float64List(len);
  const detune = [-9.0, -3.0, 4.0, 10.0];
  final ph = [for (var j = 0; j < detune.length + 1; j++) rnd.nextDouble() * 2 * math.pi];
  final ratios = [for (final c in detune) math.pow(2, c / 1200).toDouble(), 0.5];
  final amps = [for (final _ in detune) 1.0, 0.45];
  const a = 0.33;
  for (var i = 0; i < len; i++) {
    final t = i / len;
    final env = t < a ? _smooth(t / a) : math.pow(1 - _smooth((t - a) / (1 - a)), 2).toDouble();
    final vib = 1 + 0.002 * math.sin(2 * math.pi * 0.3 * i / sampleRate);
    final hz = _glide(n, t) * vib;
    var v = 0.0;
    for (var j = 0; j < ratios.length; j++) {
      ph[j] += 2 * math.pi * hz * ratios[j] / sampleRate;
      v += amps[j] * (math.sin(ph[j]) + n.bright * (0.25 * math.sin(2 * ph[j]) + 0.1 * math.sin(3 * ph[j])));
    }
    out[i] = env * v / ratios.length;
  }
  return out;
}

Float64List _sub(Note n) {
  final len = _n(n.len);
  final out = Float64List(len);
  final k = math.log(100) / len;
  final attack = _n(0.025);
  var ph = 0.0;
  for (var i = 0; i < len; i++) {
    final t = i / len;
    final hz = n.to == null ? n.hz : n.hz * math.pow(n.to! / n.hz, _smooth(t));
    ph += 2 * math.pi * hz / sampleRate;
    final env = math.exp(-k * i) * (i < attack ? _smooth(i / attack) : 1);
    // Overtones so it still reads on small speakers.
    out[i] = env * (math.sin(ph) + 0.35 * math.sin(2 * ph) + 0.12 * math.sin(3 * ph));
  }
  return out;
}

Float64List _dust(Note n, math.Random rnd) {
  final len = _n(n.len);
  final out = Float64List(len);
  const steps = [0, 2, 4, 7, 9, 12, 14];
  final count = math.max(4, (n.len * 14).round());
  for (var g = 0; g < count; g++) {
    final tg = (g + rnd.nextDouble() * 0.6) / count * 0.75;
    final start = _n(tg * n.len);
    final centre = n.to == null ? n.hz : n.hz * math.pow(n.to! / n.hz, tg);
    final f = centre * math.pow(2, steps[rnd.nextInt(steps.length)] / 12);
    final glen = math.min(_n(0.1 + 0.15 * rnd.nextDouble()), len - start);
    if (glen <= 0) continue;
    final amp = (1 - tg) * (0.5 + 0.5 * rnd.nextDouble());
    final k = math.log(100) / glen;
    final w = 2 * math.pi * f / sampleRate;
    for (var i = 0; i < glen; i++) {
      out[start + i] += amp * math.exp(-k * i) * (i < 88 ? i / 88 : 1) * math.sin(w * i);
    }
  }
  return out;
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
