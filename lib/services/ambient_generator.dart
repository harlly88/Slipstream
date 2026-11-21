import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'pomodoro_engine.dart';

/// 环境音 WAV 合成器：雨声 / 海浪，纯代码生成（无音频资源文件）
/// 8 秒循环、44.1kHz 立体声 16bit；调制频率均整除 8s 保证无缝循环。
class AmbientGenerator {
  static const sampleRate = 44100;
  static const durationSeconds = 8;

  static Uint8List generate({required AmbientNoise kind, double amplitude = 0.5}) =>
      kind == AmbientNoise.rain ? _rain(amplitude) : _wave(amplitude);

  static Future<File> writeWav(AudioPreset preset, {double amplitude = 0.5}) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/ambient_${preset.noise!.name}.wav');
    // v0.5：海浪峰值因子大、听感偏小 → 提高合成幅度（雨声保持默认）
    final amp = preset.noise == AmbientNoise.wave ? 0.85 : amplitude;
    await file.writeAsBytes(generate(kind: preset.noise!, amplitude: amp),
        flush: true);
    return file;
  }

  // ---------- WAV 头 ----------

  static Uint8List _wav(Uint8List pcm) {
    final dataSize = pcm.length;
    final bytes = ByteData(44 + dataSize);
    void writeStr(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        bytes.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    writeStr(0, 'RIFF');
    bytes.setUint32(4, 36 + dataSize, Endian.little);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little); // PCM
    bytes.setUint16(22, 2, Endian.little); // 立体声
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 4, Endian.little);
    bytes.setUint16(32, 4, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    writeStr(36, 'data');
    bytes.setUint32(40, dataSize, Endian.little);
    final out = bytes.buffer.asUint8List();
    out.setAll(44, pcm);
    return out;
  }

  /// 立体声 PCM 打包（左右声道独立 float [-1,1]）
  static Uint8List _pack(List<double> left, List<double> right, double amplitude) {
    final n = math.min(left.length, right.length);
    // 峰值归一化后乘幅度
    var peak = 0.0;
    for (var i = 0; i < n; i++) {
      peak = math.max(peak, left[i].abs());
      peak = math.max(peak, right[i].abs());
    }
    final scale = peak > 0 ? amplitude / peak : 0.0;
    final pcm = ByteData(n * 4);
    for (var i = 0; i < n; i++) {
      final l = (left[i] * scale * 32767).round().clamp(-32768, 32767);
      final r = (right[i] * scale * 32767).round().clamp(-32768, 32767);
      pcm.setInt16(i * 4, l, Endian.little);
      pcm.setInt16(i * 4 + 2, r, Endian.little);
    }
    return _wav(pcm.buffer.asUint8List());
  }

  // ---------- 确定性随机（固定种子 → 循环边界天然连续） ----------

  static int _xorshift32(int state) {
    var x = state;
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    return x & 0xFFFFFFFF;
  }

  /// 白噪声序列（种子 20261115）
  static List<double> _whiteNoise(int n, {int seed = 20261115}) {
    final out = List<double>.filled(n, 0);
    var s = seed;
    for (var i = 0; i < n; i++) {
      s = _xorshift32(s == 0 ? 1 : s);
      out[i] = (s / 2147483648.0) - 1.0;
    }
    return out;
  }

  // ---------- 雨声 ----------

  static Uint8List _rain(double amplitude) {
    final n = sampleRate * durationSeconds;
    final white = _whiteNoise(n);

    // 一阶低通（截止 ~4kHz）+ 一阶高通（~300Hz 去隆隆声）
    final alphaLp = 1.0 - math.exp(-2 * math.pi * 4000 / sampleRate);
    final alphaHp = 1.0 - math.exp(-2 * math.pi * 300 / sampleRate);
    var lp = 0.0, lpLow = 0.0;
    final base = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      lp += alphaLp * (white[i] - lp); // 低通 4k
      lpLow += alphaHp * (lp - lpLow); // 再低通 300
      base[i] = lp - lpLow; // 带通 300~4k
    }

    // 雨滴点缀：随机间隔（平均 ~80ms）短促衰减正弦脉冲
    final rnd = _xorshift32;
    var s = 987654321;
    final left = List<double>.filled(n, 0);
    final right = List<double>.filled(n, 0);
    final pingMaxSamples = (sampleRate * 0.02).round(); // 最长 20ms
    var next = (sampleRate * 0.05).round();
    while (next < n - pingMaxSamples) {
      s = rnd(s);
      final freq = 2000 + (s / 0xFFFFFFFF) * 3000; // 2~5kHz
      s = rnd(s);
      final tau = (0.005 + (s / 0xFFFFFFFF) * 0.010); // 5~15ms 衰减
      s = rnd(s);
      final gain = 0.15 + (s / 0xFFFFFFFF) * 0.6;
      s = rnd(s);
      final pan = (s / 0xFFFFFFFF); // 0=左 1=右
      final len = (tau * 6 * sampleRate).round().clamp(1, pingMaxSamples);
      final w = 2 * math.pi * freq / sampleRate;
      for (var k = 0; k < len; k++) {
        final env = math.exp(-k / (tau * sampleRate));
        final v = math.sin(w * k) * env * gain;
        final i = next + k;
        left[i] += v * (1.0 - pan * 0.7);
        right[i] += v * (0.3 + pan * 0.7);
      }
      s = rnd(s);
      next += (sampleRate * 0.02).round() +
          ((s / 0xFFFFFFFF) * sampleRate * 0.13).round(); // 平均 ~80ms
    }

    for (var i = 0; i < n; i++) {
      left[i] = left[i] * 0.5 + base[i];
      right[i] = right[i] * 0.5 + base[i];
    }
    return _pack(left, right, amplitude);
  }

  // ---------- 海浪 ----------

  static Uint8List _wave(double amplitude) {
    final n = sampleRate * durationSeconds;
    final white = _whiteNoise(n);

    // 布朗噪声（白噪声积分）+ 线性去趋势 → 首尾归零，循环无跳变
    final brown = List<double>.filled(n, 0);
    var acc = 0.0;
    for (var i = 0; i < n; i++) {
      acc += white[i] * 0.02;
      brown[i] = acc;
    }
    final trend = brown[n - 1] - brown[0];
    for (var i = 0; i < n; i++) {
      brown[i] -= brown[0] + trend * i / (n - 1);
    }

    // 低通 ~800Hz
    final alphaLp = 1.0 - math.exp(-2 * math.pi * 800 / sampleRate);
    final left = List<double>.filled(n, 0);
    final right = List<double>.filled(n, 0);
    var lpL = 0.0, lpR = 0.0;
    // 浪涌包络：4s + 8s 两个 LFO（整除 8s 循环）；右声道相位错开 0.5s
    const w1 = 2 * math.pi / 4; // 0.25Hz
    const w2 = 2 * math.pi / 8; // 0.125Hz
    const phaseR = 2 * math.pi * 0.5 / 8; // 0.5s 对 8s 周期
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      lpL += alphaLp * (brown[i] - lpL);
      lpR += alphaLp * (brown[i] - lpR);
      final envL = 0.5 + 0.3 * math.sin(w1 * t) + 0.2 * math.sin(w2 * t);
      final envR = 0.5 +
          0.3 * math.sin(w1 * t - phaseR * 2) +
          0.2 * math.sin(w2 * t - phaseR);
      // v0.5 软饱和：压低峰值因子、抬高 RMS → 感知响度显著提升（无削波）
      left[i] = _tanh(lpL * envL * 1.8);
      right[i] = _tanh(lpR * envR * 1.8);
    }
    return _pack(left, right, amplitude);
  }

  /// 双曲正切（dart:math 无 tanh）：软限幅，|x| 大时趋近 ±1
  static double _tanh(double x) {
    if (x > 20) return 1;
    if (x < -20) return -1;
    final e = math.exp(2 * x);
    return (e - 1) / (e + 1);
  }
}

/// 闹铃 WAV 合成器：双音"哔-嘟"（880/660Hz，0.8s 周期），纯代码合成、无资源文件。
/// 全屏响铃页循环播放用 8s（10 个整周期 → 无缝循环）；与 res/raw/alarm.wav 同音色。
class AlarmToneGenerator {
  static const sampleRate = 22050;

  /// 生成 mono 16bit WAV。[durationSeconds] 须为 0.8s 的整数倍（如 8 / 30）。
  static Uint8List generate({int durationSeconds = 8, double amplitude = 0.85}) {
    final n = sampleRate * durationSeconds;
    final dataSize = n * 2;
    final bytes = ByteData(44 + dataSize);

    void writeStr(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        bytes.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    writeStr(0, 'RIFF');
    bytes.setUint32(4, 36 + dataSize, Endian.little);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little); // PCM
    bytes.setUint16(22, 1, Endian.little); // mono
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little); // byte rate
    bytes.setUint16(32, 2, Endian.little); // block align
    bytes.setUint16(34, 16, Endian.little); // bits per sample
    writeStr(36, 'data');
    bytes.setUint32(40, dataSize, Endian.little);

    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      final phase = t % 0.8; // 0.8s 周期：880Hz 0.25s + 50ms 静音 + 660Hz 0.25s + 250ms 静音
      double v = 0;
      if (phase < 0.25) {
        v = math.sin(2 * math.pi * 880 * t) * _fade(phase, 0.25);
      } else if (phase >= 0.30 && phase < 0.55) {
        v = math.sin(2 * math.pi * 660 * t) * _fade(phase - 0.30, 0.25);
      }
      bytes.setInt16(44 + i * 2,
          (v * amplitude * 32767).round().clamp(-32768, 32767), Endian.little);
    }
    return bytes.buffer.asUint8List();
  }

  /// 音符首尾 10ms 线性淡入淡出（消除咔哒声）
  static double _fade(double x, double len, {double edge = 0.01}) {
    if (x < edge) return x / edge;
    if (x > len - edge) return (len - x) / edge;
    return 1.0;
  }
}
