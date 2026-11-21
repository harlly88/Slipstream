import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'data/repositories.dart';
import 'providers.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: QingliuApp()));
}

/// 应用启动引导逻辑（通知初始化、提醒重建）
Future<void> bootstrap(WidgetRef ref) async {
  final notif = ref.read(notificationServiceProvider);
  await notif.init();

  // 通知动作回调
  notif.onCompleteTask = (taskId) async {
    final db = await ref.read(databaseProvider.future);
    await TaskRepo(db).setDone(taskId, done: true);
    // 一次性提醒触发后自动停用；重复提醒保持周期触发
    final reminders = await ReminderRepo(db).getAllEnabled();
    for (final r in reminders.where((r) => r.taskId == taskId && r.type == 'once')) {
      await ReminderRepo(db).setEnabled(r.id, enabled: false);
      await notif.cancelReminder(r.id);
    }
  };
  notif.onSnoozeTask = (taskId) async {
    final db = await ref.read(databaseProvider.future);
    final task = await TaskRepo(db).getById(taskId);
    if (task == null) return;
    final project = task.projectId == null
        ? null
        : await ProjectRepo(db).getById(task.projectId!);
    await notif.snooze(taskId, task.title, project?.name ?? '');
  };

  // 闹钟响铃：全屏意图启动 / 通知点击 → 全屏响铃页（v0.5）
  notif.onAlarmRinging = (alarmId, title) {
    // 闹钟优先：停掉专注音频诱导
    ref.read(audioServiceProvider).stop();
    ref.read(alarmRingProvider.notifier).state = (id: alarmId, title: title);
  };
  final launchPayload = await notif.getLaunchPayload();
  if (launchPayload != null && launchPayload.startsWith('alarm')) {
    final parsed = NotificationService.parseAlarmPayload(launchPayload);
    notif.onAlarmRinging?.call(parsed.$1, parsed.$2);
  }

  final db = await ref.read(databaseProvider.future);

  // 错过闹钟补响（v0.6）：到点时链路被 ROM 掐断（无声音/无弹窗）的闹钟，
  // 2 小时内打开 App 直接补响，保证闹钟一定会送达。
  if (ref.read(alarmRingProvider) == null) {
    final now = DateTime.now();
    final missed = (await ReminderRepo(db).getAllEnabled())
        .where((r) =>
            r.taskId == null &&
            r.type == 'once' &&
            r.fireAt.isBefore(now) &&
            !r.fireAt.isBefore(now.subtract(const Duration(hours: 2))))
        .toList()
      ..sort((a, b) => b.fireAt.compareTo(a.fireAt));
    if (missed.isNotEmpty) {
      notif.onAlarmRinging?.call(missed.first.id, missed.first.title ?? '闹钟');
    }
  }

  // 重建全部提醒调度（进程重启后恢复系统闹钟）
  await rescheduleAllReminders(db, notif);
}
