import 'package:flutter_test/flutter_test.dart';
import 'package:qingliu/services/pomodoro_engine.dart';

void main() {
  group('PomodoroState 时间计算（v0.2 纯倒计时）', () {
    test('剩余时长随时间递减（时间戳真源）', () {
      final start = DateTime(2026, 1, 1, 10, 0, 0);
      final state = PomodoroState(
        phase: 'focus',
        startedAt: start,
        plannedMinutes: 25,
      );
      expect(state.remainingOf(start), const Duration(minutes: 25));
      expect(state.remainingOf(start.add(const Duration(minutes: 10))),
          const Duration(minutes: 15));
      expect(state.remainingOf(start.add(const Duration(minutes: 30))), Duration.zero);
    });

    test('暂停时剩余时长冻结，恢复后正确延长', () {
      final start = DateTime(2026, 1, 1, 10, 0, 0);
      final pausedAt = start.add(const Duration(minutes: 10));
      var state = PomodoroState(
        phase: 'focus',
        startedAt: start,
        plannedMinutes: 25,
        pausedAt: pausedAt,
      );
      // 暂停 5 分钟后查询：剩余仍是 15 分钟
      expect(state.remainingOf(pausedAt.add(const Duration(minutes: 5))),
          const Duration(minutes: 15));

      // 恢复：暂停累计 5 分钟
      state = state.resume(now: pausedAt.add(const Duration(minutes: 5)));
      expect(state.pausedAccum, const Duration(minutes: 5));
      // 结束时刻相应顺延 5 分钟
      expect(state.endAt, start.add(const Duration(minutes: 30)));
      expect(state.remainingOf(pausedAt.add(const Duration(minutes: 5))),
          const Duration(minutes: 15));
    });

    test('过期判断', () {
      final start = DateTime(2026, 1, 1, 10, 0, 0);
      final state = PomodoroState(
          phase: 'focus', startedAt: start, plannedMinutes: 25);
      expect(state.isExpired(start.add(const Duration(minutes: 24))), false);
      expect(state.isExpired(start.add(const Duration(minutes: 26))), true);
    });

    test('状态序列化往返（旧 JSON 含 taskId/round 字段被忽略）', () {
      final state = PomodoroState(
        phase: 'focus',
        startedAt: DateTime(2026, 1, 1, 10, 0, 0),
        plannedMinutes: 40,
        pausedAccum: const Duration(minutes: 3),
      );
      final decoded = PomodoroState.decode(PomodoroState.encode(state))!;
      expect(decoded.phase, 'focus');
      expect(decoded.plannedMinutes, 40);
      expect(decoded.pausedAccum, const Duration(minutes: 3));

      // 兼容 v0.1 旧持久化 JSON
      final legacy = PomodoroState.decode(
          '{"phase":"break","startedAt":"2026-01-01T10:00:00.000","plannedMinutes":25,"pausedAccumMs":0,"taskId":7,"round":2}');
      expect(legacy, isNotNull);
      expect(legacy!.phase, 'idle'); // break 已废弃 → idle（视为无运行中状态）
    });
  });

  group('PomodoroSettings（v0.2 仅专注时长）', () {
    test('旧 JSON 多余字段忽略', () {
      final s = PomodoroSettings.fromJson(const {
        'focusMinutes': 45,
        'shortBreakMinutes': 5,
        'longBreakMinutes': 15,
        'roundsBeforeLongBreak': 4,
      });
      expect(s.focusMinutes, 45);
      expect(s.toJson(), {'focusMinutes': 45});
    });
  });

  group('AudioPreset', () {
    test('新预设列表：专注/思考/冥想/睡眠/雨声/海浪/静音', () {
      expect(AudioPreset.presets.map((p) => p.name).toList(),
          ['专注', '思考', '冥想', '睡眠', '雨声', '海浪', '静音']);
      final sleep = AudioPreset.presets[3];
      expect(sleep.carrierHz, 140);
      expect(sleep.beatHz, 3); // 整数 Hz 保证无缝循环
      expect(AudioPreset.presets[6].kind, AudioKind.silent);
      expect(AudioPreset.presets[4].kind, AudioKind.ambient);
      expect(AudioPreset.presets[4].noise, AmbientNoise.rain);
      expect(AudioPreset.presets[5].noise, AmbientNoise.wave);
    });

    test('旧预设名迁移', () {
      expect(AudioPreset.migrateName('阿尔法·专注'), '专注');
      expect(AudioPreset.migrateName('贝塔·警觉'), '思考');
      expect(AudioPreset.migrateName('西塔·深度'), '冥想');
      expect(AudioPreset.migrateName('无音频'), '静音');
      expect(AudioPreset.migrateName('不存在'), null);
    });
  });
}
