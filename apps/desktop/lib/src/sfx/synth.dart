import 'dart:math' as math;
import 'dart:typed_data';

// A tiny offline synthesizer for UI sounds: notes with soft attacks and
// exponential decays, a low-pass to take the edge off and a short room
// tail. Everything renders to 16-bit mono WAV bytes. Pure Dart, no Flutter.

const sampleRate = 44100;

/// Timbre of a note.
enum Voice {
  /// Sine with a touch of octave: round, flute-like.
  soft,
  /// Glass/marimba: a few partials, the upper ones die first.
  bell,
  /// Short and dry, for ticks.
  pluck,
}

class Note {
  /// Start (s) and pitch (Hz); [to] glides there over the note.
  final double at;
  final double hz;
  final double? to;
  /// Length (s) of the decay to about -40 dB.
  final double len;
  final double gain;
  final Voice voice;
  /// Vibrato depth in semitones (0 = none), ~5.5 Hz.
  final double wobble;
  const Note(this.at, this.hz, this.len,
      {this.to, this.gain = 1, this.voice = Voice.bell, this.wobble = 0});
}

class SoundSpec {
  final List<Note> notes;
  /// One-pole low-pass cutoff (Hz): lower = softer, darker.
  final double cutoff;
  /// Peak level after normalising, in dBFS (quiet by design).
  final double peakDb;
  /// Room tail mix (0..1).
  final double room;
  const SoundSpec(this.notes, {this.cutoff = 5200, this.peakDb = -16, this.room = 0.16});

  double get length =>
      notes.fold<double>(0, (m, n) => math.max(m, n.at + n.len)) + (room > 0 ? 0.25 : 0.02);
}

/// Note frequency by name-free index: semitones from A4 (440 Hz).
double semi(num n) => 440 * math.pow(2, n / 12).toDouble();

Float64List render(SoundSpec spec) {
  final total = (spec.length * sampleRate).ceil();
  final out = Float64List(total);
  for (final n in spec.notes) {
    _addNote(out, n);
  }
  // Low-pass: one pole, run twice for a gentler 12 dB/oct slope.
  final a = math.exp(-2 * math.pi * spec.cutoff / sampleRate);
  for (var pass = 0; pass < 2; pass++) {
    var y = 0.0;
    for (var i = 0; i < total; i++) {
      y = (1 - a) * out[i] + a * y;
      out[i] = y;
    }
  }
  if (spec.room > 0) _room(out, spec.room);
  // Fade the last 10 ms so nothing clicks, then normalise to the peak.
  final fade = (0.01 * sampleRate).round();
  for (var i = 0; i < fade && i < total; i++) {
    out[total - 1 - i] *= i / fade;
  }
  var peak = 0.0;
  for (final s in out) {
    peak = math.max(peak, s.abs());
  }
  if (peak > 0) {
    final g = math.pow(10, spec.peakDb / 20) / peak;
    for (var i = 0; i < total; i++) {
      out[i] *= g;
    }
  }
  return out;
}

void _addNote(Float64List out, Note n) {
  final start = (n.at * sampleRate).round();
  final len = (n.len * sampleRate).round();
  final attack = switch (n.voice) {
    Voice.soft => 0.012,
    Voice.bell => 0.004,
    Voice.pluck => 0.002,
  } * sampleRate;
  // exp(-k * len) = 0.01 (-40 dB).
  final k = math.log(100) / len;
  final partials = switch (n.voice) {
    Voice.soft => const [(1.0, 1.0, 1.0), (2.0, 0.12, 1.6)],
    Voice.bell => const [(1.0, 1.0, 1.0), (2.0, 0.28, 1.8), (3.01, 0.08, 2.6), (4.2, 0.05, 3.5)],
    Voice.pluck => const [(1.0, 1.0, 1.0), (2.0, 0.35, 2.0), (3.0, 0.15, 3.0)],
  };
  final phases = List<double>.filled(partials.length, 0);
  for (var i = 0; i < len && start + i < out.length; i++) {
    final t = i / len;
    var hz = n.to == null ? n.hz : n.hz * math.pow(n.to! / n.hz, _smooth(t));
    if (n.wobble > 0) {
      hz *= math.pow(2, n.wobble / 12 * math.sin(2 * math.pi * 5.5 * i / sampleRate));
    }
    final env = (i < attack ? _smooth(i / attack) : 1.0) * math.exp(-k * i);
    var s = 0.0;
    for (var p = 0; p < partials.length; p++) {
      final (mult, amp, decay) = partials[p];
      phases[p] += 2 * math.pi * hz * mult / sampleRate;
      // Upper partials fade faster: the attack has shimmer, the tail is round.
      s += amp * math.sin(phases[p]) * math.exp(-k * (decay - 1) * i);
    }
    out[start + i] += n.gain * env * s;
  }
}

double _smooth(double t) => t * t * (3 - 2 * t);

/// A few feedback delays (a small room): a soft tail instead of a dry stop.
void _room(Float64List out, double mix) {
  const taps = [0.031, 0.047, 0.067];
  final dry = Float64List.fromList(out);
  for (final d in taps) {
    final delay = (d * sampleRate).round();
    final buf = Float64List(out.length);
    for (var i = delay; i < out.length; i++) {
      buf[i] = dry[i - delay] + 0.45 * buf[i - delay];
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
