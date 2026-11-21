import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/database.dart';

/// 本地通知服务：提醒投递 + 番茄钟结束提示 + 闹钟响铃
class NotificationService {
  static const _channelId = 'qingliu_reminders';
  static const _timerChannelId = 'qingliu_timer';
  static const _alarmChannelId = 'qingliu_alarms';
  static const _channelName = '任务提醒';
  static const _timerChannelName = '番茄钟';
  static const _alarmChannelName = '闹钟响铃';

  /// 闹钟通知渠道 id（"闹钟不响？"检查入口直达该渠道设置用）
  static const alarmChannelId = _alarmChannelId;

  /// 提醒通知 ID 规则：提醒数据库 id
  /// 番茄钟结束：固定大 ID；贪睡：910000000 + taskId
  static const pomodoroNotifId = 900000001;
  static int snoozeNotifId(int taskId) => 910000000 + taskId;

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  /// 完成任务回调（通知动作触发）
  void Function(int taskId)? onCompleteTask;

  /// 贪睡回调（通知动作触发）
  void Function(int taskId)? onSnoozeTask;

  /// 闹钟触发（全屏意图启动 App 或通知被点击），alarmId 用于响完后停用一次性闹钟
  void Function(int? alarmId, String title)? onAlarmRinging;

  /// 番茄钟结束通知被点击
  VoidCallback? onPomodoroTapped;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    await _initLocalTimezone();

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      ),
      macOS: DarwinInitializationSettings(),
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: _notificationTapBackground,
    );

    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl != null) {
      await androidImpl.createNotificationChannel(const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: '任务到点提醒',
        importance: Importance.high,
      ));
      await androidImpl.createNotificationChannel(const AndroidNotificationChannel(
        _timerChannelId,
        _timerChannelName,
        description: '番茄钟计时结束提示',
        importance: Importance.high,
      ));
      // 闹钟专用渠道：长铃声 + 闹钟音量通道 + 振动（v0.5）
      await androidImpl.createNotificationChannel(AndroidNotificationChannel(
        _alarmChannelId,
        _alarmChannelName,
        description: '闹钟到点响铃',
        importance: Importance.max,
        sound: const RawResourceAndroidNotificationSound('alarm'),
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 800, 400, 800, 400, 800]),
        audioAttributesUsage: AudioAttributesUsage.alarm,
      ));
    }
    _initialized = true;
  }

  /// 初始化本地时区。
  /// 修复（v0.3）：Android 上 `DateTime.now().timeZoneName` 返回 "GMT+08:00" 之类的
  /// 显示名而非 IANA 名，`tz.getLocation` 会抛错并被吞掉，导致 tz.local 停留在 UTC、
  /// 全部闹钟被推迟 8 小时。改用 flutter_timezone 获取 IANA 时区名，逐级回退。
  Future<void> _initLocalTimezone() async {
    // 1) flutter_timezone：平台原生 IANA 时区名（如 Asia/Shanghai）
    try {
      final name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name));
      return;
    } catch (e) {
      debugPrint('flutter_timezone failed: $e');
    }
    // 2) 回退：dart:io 的 timeZoneName（桌面平台是 IANA 名）
    try {
      tz.setLocalLocation(tz.getLocation(DateTime.now().timeZoneName));
    } catch (_) {
      // 3) 兜底保持 UTC
    }
  }

  @pragma('vm:entry-point')
  static void _notificationTapBackground(NotificationResponse response) {
    // 后台（进程被杀后重建）时的动作处理：
    // v0.1 采用：进程存活时回调处理；进程重建时下次启动同步状态。
    debugPrint('background notification action: ${response.actionId}');
  }

  Future<void> _onNotificationResponse(NotificationResponse response) async {
    final payload = response.payload;
    final taskId = int.tryParse(payload ?? '');
    if (response.actionId == 'action_complete') {
      if (taskId != null) onCompleteTask?.call(taskId);
    } else if (response.actionId == 'action_snooze') {
      if (taskId != null) onSnoozeTask?.call(taskId);
    } else if (response.id == pomodoroNotifId) {
      onPomodoroTapped?.call();
    } else if (payload != null && payload.startsWith('alarm')) {
      final parsed = parseAlarmPayload(payload);
      onAlarmRinging?.call(parsed.$1, parsed.$2);
    }
  }

  /// 闹钟载荷解析：`alarm|<id>|<title>` → (闹钟id, 标题)
  static (int?, String) parseAlarmPayload(String payload) {
    final parts = payload.split('|');
    return (
      parts.length > 1 ? int.tryParse(parts[1]) : null,
      parts.length > 2 ? parts.sublist(2).join('|') : '闹钟',
    );
  }

  /// 冷启动（进程被杀后由通知/全屏意图拉起）时的启动载荷，null = 非通知启动
  Future<String?> getLaunchPayload() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    return details?.notificationResponse?.payload;
  }

  Future<void> requestPermissions() async {
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl != null) {
      await androidImpl.requestNotificationsPermission();
      // Android 12+ 精确闹钟权限（SCHEDULE_EXACT_ALARM）
      try {
        await androidImpl.requestExactAlarmsPermission();
      } catch (_) {}
    }
    final iosImpl =
        _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    if (iosImpl != null) {
      await iosImpl.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  /// 调度任务提醒。
  /// v0.3：once 且触发时间已过去 → 跳过调度（导入历史备份时 zonedSchedule 会因
  /// "Must be a date in the future" 抛错并中断整个导入，这里直接忽略过期项）。
  Future<void> scheduleReminder(Reminder reminder,
      {required String taskTitle, required String projectName}) async {
    await cancelReminder(reminder.id);
    if (reminder.type == 'once' && reminder.fireAt.isBefore(DateTime.now())) {
      return;
    }
    final fireAt = tz.TZDateTime.from(reminder.fireAt, tz.local);

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: '任务到点提醒',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
        actions: const [
          AndroidNotificationAction('action_complete', '完成', showsUserInterface: false),
          AndroidNotificationAction('action_snooze', '10分钟后再提醒', showsUserInterface: false),
        ],
      ),
      iOS: const DarwinNotificationDetails(),
    );

    DateTimeComponents? match;
    switch (reminder.type) {
      case 'daily':
        match = DateTimeComponents.time;
        break;
      case 'weekly':
        match = DateTimeComponents.dayOfWeekAndTime;
        break;
      case 'monthly':
        match = DateTimeComponents.dayOfMonthAndTime;
        break;
      default:
        match = null;
    }

    await _plugin.zonedSchedule(
      reminder.id,
      taskTitle,
      projectName,
      fireAt,
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: '${reminder.taskId}',
      matchDateTimeComponents: match,
    );
  }

  Future<void> cancelReminder(int reminderId) => _plugin.cancel(reminderId);

  /// 调度独立闹钟（taskId=null 的提醒）：纯提醒，无动作按钮。
  /// v0.3：过期的一次性闹钟跳过调度（同 scheduleReminder）。
  /// v0.5：改用「闹钟响铃」渠道——长铃声（res/raw/alarm.wav）+ 闹钟音量通道
  /// + 全屏意图（锁屏/黑屏弹出响铃页）+ 振动。
  Future<void> scheduleAlarm(Reminder reminder, {required String title}) async {
    await cancelReminder(reminder.id);
    if (reminder.type == 'once' && reminder.fireAt.isBefore(DateTime.now())) {
      return;
    }
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _alarmChannelId,
        _alarmChannelName,
        channelDescription: '闹钟到点响铃',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.alarm,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        fullScreenIntent: true,
        sound: const RawResourceAndroidNotificationSound('alarm'),
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 800, 400, 800, 400, 800]),
        ticker: title,
      ),
      iOS: const DarwinNotificationDetails(presentAlert: true, presentSound: true),
    );
    await _plugin.zonedSchedule(
      reminder.id,
      title,
      '闹钟提醒',
      tz.TZDateTime.from(reminder.fireAt, tz.local),
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: 'alarm|${reminder.id}|$title',
    );
  }

  /// 贪睡：10 分钟后一次性提醒
  Future<void> snooze(int taskId, String title, String body) async {
    final when = tz.TZDateTime.now(tz.local).add(const Duration(minutes: 10));
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: '任务到点提醒',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
    await _plugin.zonedSchedule(
      snoozeNotifId(taskId),
      title,
      body,
      when,
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: '$taskId',
    );
  }

  Future<void> cancelSnooze(int taskId) => _plugin.cancel(snoozeNotifId(taskId));

  /// 番茄钟结束提示（进程被杀也能到点弹出）
  Future<void> schedulePomodoroEnd(DateTime endTime, String title, String body) async {
    await cancelPomodoroEnd();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _timerChannelId,
        _timerChannelName,
        channelDescription: '番茄钟计时结束提示',
        importance: Importance.high,
        priority: Priority.high,
        ongoing: false,
      ),
      iOS: DarwinNotificationDetails(),
    );
    await _plugin.zonedSchedule(
      pomodoroNotifId,
      title,
      body,
      tz.TZDateTime.from(endTime, tz.local),
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: 'pomodoro',
    );
  }

  Future<void> cancelPomodoroEnd() => _plugin.cancel(pomodoroNotifId);

  /// 立即展示一条番茄钟结束通知（App 在前台时结束点补充提示）
  Future<void> showPomodoroEndNow(String title, String body) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _timerChannelId,
        _timerChannelName,
        channelDescription: '番茄钟计时结束提示',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
    await _plugin.show(pomodoroNotifId, title, body, details, payload: 'pomodoro');
  }

  /// 取消全部（导入恢复后重建）
  Future<void> cancelAll() => _plugin.cancelAll();

  /// 精确闹钟是否已授权（Android 12+，用于引导页判断）
  Future<bool> supportsExactAlarms() async {
    if (!Platform.isAndroid) return true;
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl == null) return true;
    try {
      return await androidImpl.requestExactAlarmsPermission() ?? true;
    } catch (_) {
      return true;
    }
  }
}
