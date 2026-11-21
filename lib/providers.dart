import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/database.dart';
import 'data/repositories.dart';
import 'services/audio_induction.dart';
import 'services/notification_service.dart';
import 'services/pomodoro_engine.dart';

// ---------- 基础设施 ----------

Future<AppDatabase> _openDatabase() async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File(p.join(dir.path, 'qingliu.sqlite'));
  return AppDatabase(NativeDatabase.createInBackground(file));
}

final databaseProvider = FutureProvider<AppDatabase>((ref) async {
  final db = await _openDatabase();
  ref.onDispose(db.close);
  return db;
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService();
});

final audioServiceProvider = Provider<AudioInductionService>((ref) {
  final svc = AudioInductionService();
  ref.onDispose(svc.dispose);
  return svc;
});

// ---------- 仓库 ----------

final projectRepoProvider = FutureProvider<ProjectRepo>(
    (ref) async => ProjectRepo(await ref.watch(databaseProvider.future)));

final taskRepoProvider = FutureProvider<TaskRepo>(
    (ref) async => TaskRepo(await ref.watch(databaseProvider.future)));

final reminderRepoProvider = FutureProvider<ReminderRepo>(
    (ref) async => ReminderRepo(await ref.watch(databaseProvider.future)));

final focusRepoProvider = FutureProvider<FocusRepo>(
    (ref) async => FocusRepo(await ref.watch(databaseProvider.future)));

final settingsRepoProvider = FutureProvider<SettingsRepo>(
    (ref) async => SettingsRepo(await ref.watch(databaseProvider.future)));

final backupServiceProvider = FutureProvider<BackupService>(
    (ref) async => BackupService(await ref.watch(databaseProvider.future)));

// ---------- 主框架 ----------

/// 底部导航当前页（跨页跳转用，如今日页 → 闹钟页）
final homeTabIndexProvider = StateProvider<int>((ref) => 0);

// ---------- 项目 / 任务 ----------

/// 全部未归档项目
final projectsProvider = StreamProvider<List<Project>>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  yield* ProjectRepo(db).watchAll();
});

/// 看板选中项目 id
final selectedProjectIdProvider = StateProvider<int?>((ref) => null);

/// 选中项目的任务（看板三列数据源）
final projectTasksProvider =
    StreamProvider.family<List<Task>, int>((ref, projectId) async* {
  final db = await ref.watch(databaseProvider.future);
  yield* TaskRepo(db).watchByProject(projectId);
});

/// 今日任务（isToday=true，含临时任务；项目可空）
final todayTasksProvider = StreamProvider<List<(Task, Project?)>>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  yield* TaskRepo(db).watchToday();
});

/// 任务的提醒列表
final taskRemindersProvider =
    StreamProvider.family<List<Reminder>, int>((ref, taskId) async* {
  final db = await ref.watch(databaseProvider.future);
  yield* ReminderRepo(db).watchByTask(taskId);
});

// ---------- 闹钟 ----------

/// 闹钟响铃中（null = 未响铃；id 用于响完后停用一次性闹钟、防止补响重复）
final alarmRingProvider =
    StateProvider<({int? id, String title})?>((ref) => null);

/// 全部已启用的独立闹钟（taskId=null）
final alarmsProvider = StreamProvider<List<Reminder>>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  yield* ReminderRepo(db).watchAlarms();
});

/// 今日将触发的提醒（今日闹钟区）
final todayAlarmsProvider = FutureProvider<List<Reminder>>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return ReminderRepo(db).getTodayAlarms();
});

// ---------- 设置 ----------

const kPomodoroSettingsKey = 'pomodoro_settings';
const kPomodoroStateKey = 'pomodoro_state';
const kAudioPresetKey = 'audio_preset';
const kAudioVolumeKey = 'audio_volume';
const kOnboardedKey = 'onboarded';

final pomodoroSettingsProvider = StreamProvider<PomodoroSettings>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  yield* SettingsRepo(db).watch(kPomodoroSettingsKey).map(
      (raw) => raw == null ? const PomodoroSettings() : PomodoroSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>));
});

final audioPresetProvider = StreamProvider<AudioPreset>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  yield* SettingsRepo(db).watch(kAudioPresetKey).map((raw) {
    if (raw == null) return AudioPreset.presets.first;
    final name =
        (jsonDecode(raw) as Map<String, dynamic>)['name'] as String? ?? '';
    // 兼容旧版预设名（阿尔法·专注 → 专注 等）
    final migrated = AudioPreset.migrateName(name) ?? name;
    return AudioPreset.presets.firstWhere((p) => p.name == migrated,
        orElse: () => AudioPreset.presets.first);
  });
});

final onboardedProvider = StreamProvider<bool>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  yield* SettingsRepo(db).watch(kOnboardedKey).map((raw) => raw == '1');
});

// ---------- 专注计时 ----------

/// 专注计时控制器：时间戳真源 + 通知调度（v0.2 纯倒计时，无任务关联）
class PomodoroController extends Notifier<PomodoroState> {
  Timer? _ticker;

  @override
  PomodoroState build() {
    ref.onDispose(() => _ticker?.cancel());
    // 启动时从 DB 恢复，处理过期补记
    _restore();
    return PomodoroState.idle;
  }

  Future<void> _restore() async {
    try {
      final db = await ref.read(databaseProvider.future);
      final settings = SettingsRepo(db);
      final raw = await settings.get(kPomodoroStateKey);
      final restored = PomodoroState.decode(raw);
      if (restored == null || !restored.isRunning) return;

      if (restored.isExpired(DateTime.now())) {
        // 离线期间已到点：补记完成
        await FocusRepo(db).insert(FocusSessionsCompanion.insert(
          startedAt: restored.startedAt!,
          plannedMinutes: restored.plannedMinutes,
          endedAt: Value(restored.endAt),
          outcome: const Value('completed'),
        ));
        await settings.remove(kPomodoroStateKey);
        await ref.read(notificationServiceProvider).cancelPomodoroEnd();
        state = PomodoroState.idle;
      } else {
        state = restored;
        _startTicker();
      }
    } catch (e) {
      debugPrint('pomodoro restore failed: $e');
    }
  }

  Future<void> _persist() async {
    final db = await ref.read(databaseProvider.future);
    final settings = SettingsRepo(db);
    if (state.isRunning) {
      await settings.set(kPomodoroStateKey, PomodoroState.encode(state));
    } else {
      await settings.remove(kPomodoroStateKey);
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      if (state.isExpired(now) && !state.isPaused) {
        _onFinished();
      } else {
        // 触发 UI 重建（剩余时间由时间戳推算）
        state = state.copyWith();
      }
    });
  }

  /// 启动专注（时长缺省用设置值）
  Future<void> startFocus({int? minutes}) async {
    final settings = await ref.read(pomodoroSettingsProvider.future);
    final focusMinutes = minutes ?? settings.focusMinutes;
    state = state.startFocus(minutes: focusMinutes);
    await _persist();
    _startTicker();

    // 联动音频诱导
    await _startInductionIfNeeded();

    // 调度结束通知（进程被杀也能到点弹出）
    final notif = ref.read(notificationServiceProvider);
    await notif.schedulePomodoroEnd(
      state.endAt!,
      '专注完成',
      '本次 ${state.plannedMinutes} 分钟专注结束',
    );
  }

  Future<void> _startInductionIfNeeded() async {
    final audio = ref.read(audioServiceProvider);
    if (!AudioInductionService.isSupported) return;
    final preset = await ref.read(audioPresetProvider.future);
    if (preset.kind == AudioKind.silent) return;
    final db = await ref.read(databaseProvider.future);
    final volRaw = await SettingsRepo(db).get(kAudioVolumeKey);
    final vol = double.tryParse(volRaw ?? '') ?? 0.6;
    await audio.play(preset, volume: vol);
  }

  /// 暂停
  Future<void> pause() async {
    if (!state.isRunning || state.isPaused) return;
    state = state.pause();
    await _persist();
    await ref.read(audioServiceProvider).stop();
    await ref.read(notificationServiceProvider).cancelPomodoroEnd();
    state = state.copyWith();
  }

  /// 恢复
  Future<void> resume() async {
    if (!state.isPaused) return;
    state = state.resume();
    await _persist();
    await ref.read(notificationServiceProvider).schedulePomodoroEnd(
          state.endAt!,
          '专注完成',
          '本次 ${state.plannedMinutes} 分钟专注结束',
        );
    await _startInductionIfNeeded();
    state = state.copyWith();
  }

  /// 放弃本次专注（记为 abandoned）
  Future<void> abandon() async {
    if (state.isRunning && state.startedAt != null) {
      final db = await ref.read(databaseProvider.future);
      await FocusRepo(db).insert(FocusSessionsCompanion.insert(
        startedAt: state.startedAt!,
        plannedMinutes: state.plannedMinutes,
        endedAt: Value(DateTime.now()),
        outcome: const Value('abandoned'),
      ));
    }
    await _clear();
  }

  Future<void> _clear() async {
    _ticker?.cancel();
    state = PomodoroState.idle;
    await _persist();
    await ref.read(notificationServiceProvider).cancelPomodoroEnd();
    await ref.read(audioServiceProvider).stop();
  }

  /// 计时自然结束
  Future<void> _onFinished() async {
    _ticker?.cancel();
    // 写专注记录
    final db = await ref.read(databaseProvider.future);
    await FocusRepo(db).insert(FocusSessionsCompanion.insert(
      startedAt: state.startedAt!,
      plannedMinutes: state.plannedMinutes,
      endedAt: Value(state.endAt),
      outcome: const Value('completed'),
    ));
    await ref.read(notificationServiceProvider)
        .showPomodoroEndNow('专注完成', '本次 ${state.plannedMinutes} 分钟专注结束');
    await _clear();
  }
}

final pomodoroProvider =
    NotifierProvider<PomodoroController, PomodoroState>(PomodoroController.new);

// ---------- 提醒调度 ----------

/// 应用启动后重建全部提醒的系统调度（导入恢复后同样调用）。
/// v0.2：独立闹钟（taskId=null）用 title 调度；任务提醒用任务名。
Future<void> rescheduleAllReminders(AppDatabase db, NotificationService notif) async {
  final reminders = await ReminderRepo(db).getAllEnabled();
  final tasks = await TaskRepo(db).getAll();
  final projects = await ProjectRepo(db).getAll(includeArchived: true);
  final taskById = {for (final t in tasks) t.id: t};
  final projectById = {for (final p in projects) p.id: p};

  await notif.cancelAll();
  for (final r in reminders) {
    if (r.taskId == null) {
      // 独立闹钟
      await notif.scheduleAlarm(r, title: r.title ?? '闹钟');
    } else {
      final task = taskById[r.taskId];
      if (task == null) continue;
      await notif.scheduleReminder(
        r,
        taskTitle: task.title,
        projectName: projectById[task.projectId]?.name ?? '',
      );
    }
  }
}
