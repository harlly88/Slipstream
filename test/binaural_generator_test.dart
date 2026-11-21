import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:qingliu/services/audio_induction.dart';

void main() {
  test('WAV 头部结构正确（RIFF / PCM / 立体声 / 44.1kHz / 16bit）', () {
    final data = BinauralGenerator.generate(leftHz: 200, rightHz: 210);
    final expectedSize = BinauralGenerator.sampleRate *
        BinauralGenerator.durationSeconds *
        4;

    String str(int off, int len) =>
        String.fromCharCodes(data.sublist(off, off + len));
    int u32(int off) => data[off] | (data[off + 1] << 8) | (data[off + 2] << 16) | (data[off + 3] << 24);
    int u16(int off) => data[off] | (data[off + 1] << 8);

    expect(data.length, 44 + expectedSize);
    expect(str(0, 4), 'RIFF');
    expect(u32(4), 36 + expectedSize);
    expect(str(8, 4), 'WAVE');
    expect(str(12, 4), 'fmt ');
    expect(u16(20), 1, reason: 'PCM 格式');
    expect(u16(22), 2, reason: '立体声');
    expect(u32(24), BinauralGenerator.sampleRate);
    expect(u32(28), BinauralGenerator.sampleRate * 4, reason: '字节率');
    expect(u16(32), 4, reason: '块对齐');
    expect(u16(34), 16, reason: '16bit 采样');
    expect(str(36, 4), 'data');
    expect(u32(40), expectedSize);
  });

  test('左右声道频率不同（双耳节拍）且首尾连续（无缝循环）', () {
    const leftHz = 200, rightHz = 210;
    final data = BinauralGenerator.generate(leftHz: leftHz, rightHz: rightHz);
    const sr = BinauralGenerator.sampleRate;

    int sample16(int frame, int channel) {
      final off = 44 + frame * 4 + channel * 2;
      final v = data[off] | (data[off + 1] << 8);
      return v > 32767 ? v - 65536 : v;
    }

    // 左右声道不应全等
    var diffCount = 0;
    for (var i = 0; i < sr; i++) {
      if (sample16(i, 0) != sample16(i, 1)) diffCount++;
    }
    expect(diffCount, greaterThan(sr * 90 / 100));

    // 整数周期：循环边界处的相邻样本跳变应与缓冲内部相邻样本跳变一致（无缝循环）
    final lastFrame = sr * BinauralGenerator.durationSeconds - 1;
    final firstL = sample16(0, 0);
    final lastL = sample16(lastFrame, 0);
    final secondL = sample16(1, 0);
    final boundaryJump = (firstL - lastL).abs();
    final interiorJump = (secondL - firstL).abs();
    expect((boundaryJump - interiorJump).abs(), lessThan(50),
        reason: '循环边界跳变应与内部相邻采样跳变一致');
  });

  test('浪涌包络：音量随时间明显起伏（忽大忽小，v0.5）', () {
    final data = BinauralGenerator.generate(leftHz: 200, rightHz: 210);
    const sr = BinauralGenerator.sampleRate;

    // 每 0.5s 窗内左声道峰值（窗内含 100 个载波周期，峰值可代表该时刻包络）
    double peakAt(int halfIndex) {
      var peak = 0;
      final start = sr * halfIndex ~/ 2;
      final end = sr * (halfIndex + 1) ~/ 2;
      for (var i = start; i < end; i++) {
        final off = 44 + i * 4;
        final v = data[off] | (data[off + 1] << 8);
        final s = v > 32767 ? v - 65536 : v;
        if (s.abs() > peak) peak = s.abs();
      }
      return peak.toDouble();
    }

    final peaks = [for (var k = 0; k < 16; k++) peakAt(k)];
    final maxPeak = peaks.reduce(math.max);
    final minPeak = peaks.reduce(math.min);
    expect(maxPeak, greaterThan(minPeak * 1.5),
        reason: 'LFO 包络应产生明显的忽大忽小起伏');
  });
}
