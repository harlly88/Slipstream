import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:qingliu/services/ambient_generator.dart';
import 'package:qingliu/services/pomodoro_engine.dart';

void main() {
  test('海浪响度：软饱和后 RMS 占比高（听感不偏小）、无削波（v0.5）', () {
    final data = AmbientGenerator.generate(kind: AmbientNoise.wave, amplitude: 0.85);
    var sumSq = 0.0;
    var peak = 0;
    final n = (data.length - 44) ~/ 4;
    for (var i = 0; i < n; i++) {
      final off = 44 + i * 4;
      for (var c = 0; c < 2; c++) {
        final v = data[off + c * 2] | (data[off + c * 2 + 1] << 8);
        final s = v > 32767 ? v - 65536 : v;
        sumSq += s * s;
        if (s.abs() > peak) peak = s.abs();
      }
    }
    final rms = math.sqrt(sumSq / (n * 2));
    expect(peak, lessThan(32768), reason: '无削波');
    expect(rms / peak, greaterThan(0.3),
        reason: '峰值因子低 → 感知响度足（旧版约 0.15）');
  });

  test('闹铃 WAV：mono 22.05kHz，8s 无缝循环（v0.5）', () {
    final data = AlarmToneGenerator.generate();
    String str(int off, int len) =>
        String.fromCharCodes(data.sublist(off, off + len));
    int u16(int off) => data[off] | (data[off + 1] << 8);
    expect(str(0, 4), 'RIFF');
    expect(str(8, 4), 'WAVE');
    expect(u16(22), 1, reason: 'mono');
    expect(u16(32), 2, reason: '块对齐');
    expect(data.length, 44 + AlarmToneGenerator.sampleRate * 8 * 2);

    // 8s = 10 个 0.8s 周期，边界位于静音段 → 首尾采样均为 0
    int sample16(int frame) {
      final off = 44 + frame * 2;
      final v = data[off] | (data[off + 1] << 8);
      return v > 32767 ? v - 65536 : v;
    }

    expect(sample16(0), 0);
    expect(sample16(AlarmToneGenerator.sampleRate * 8 - 1), 0);
  });
}
