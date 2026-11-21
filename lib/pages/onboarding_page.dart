import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../data/repositories.dart';
import '../main.dart';
import '../providers.dart';
import '../services/notification_service.dart';
import '../services/system_settings.dart';

/// 首次启动引导：隐私说明 + 通知权限 + 精确闹钟 + 悬浮窗 + 闹钟声音 + 电池优化指引
class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  bool _checkingExactAlarm = false;
  bool? _exactAlarmGranted;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
          children: [
            const Icon(Icons.water_drop, size: 64, color: AppPalette.accent),
            const SizedBox(height: 16),
            const Text('轻流', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: AppPalette.textPrimary)),
            const SizedBox(height: 6),
            const Text('装进口袋的个人项目驾驶舱', style: TextStyle(fontSize: 14, color: AppPalette.textSecondary)),
            const SizedBox(height: 36),
            _Item(
              icon: Icons.lock_outline,
              color: AppPalette.accent,
              title: 'Local-first，隐私优先',
              body: '全部数据仅存储在本机，默认零网络请求，'
                  '不收集任何信息。可随时在设置中导出 JSON 备份。',
            ),
            _Item(
              icon: Icons.notifications_active_outlined,
              color: AppPalette.accent,
              title: '开启通知权限',
              body: '到点提醒与番茄钟结束提示依赖系统通知，'
                  'App 被杀掉后依然能准时弹出。',
              action: FilledButton.icon(
                onPressed: () async {
                  await ref.read(notificationServiceProvider).requestPermissions();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('通知权限已请求')));
                  }
                },
                icon: const Icon(Icons.notifications_none, size: 18),
                label: const Text('授权通知'),
                style: FilledButton.styleFrom(backgroundColor: AppPalette.accent, foregroundColor: AppPalette.background),
              ),
            ),
            if (Platform.isAndroid)
              _Item(
                icon: Icons.alarm,
                color: _exactAlarmGranted == false ? AppPalette.danger : AppPalette.accent,
                title: '精确闹钟（提醒准点的前提）',
                body: _exactAlarmGranted == false
                    ? '尚未授权精确闹钟，提醒可能有数分钟误差。'
                        '请到 系统设置 → 应用 → 轻流 → 闹钟和提醒 中开启。'
                    : '用于准点触发任务提醒，授权后误差在秒级。',
                action: _checkingExactAlarm
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppPalette.accent))
                    : OutlinedButton.icon(
                        onPressed: () async {
                          setState(() => _checkingExactAlarm = true);
                          final notif = ref.read(notificationServiceProvider);
                          await notif.requestPermissions();
                          final granted = await notif.supportsExactAlarms();
                          setState(() {
                            _checkingExactAlarm = false;
                            _exactAlarmGranted = granted;
                          });
                        },
                        icon: const Icon(Icons.alarm, size: 18),
                        label: Text(_exactAlarmGranted == false ? '去系统设置' : '检查并授权'),
                      ),
              ),
            if (Platform.isAndroid)
              _Item(
                icon: Icons.picture_in_picture_alt,
                color: AppPalette.warning,
                title: '悬浮窗 / 全屏闹钟',
                body: '闹钟到点时在锁屏/黑屏上全屏弹出响铃页，需要系统允许'
                    '「悬浮窗 / 后台弹出界面」（MIUI/HyperOS/ColorOS 需手动开启）。'
                    '未开启时闹钟仍会响铃通知，但不会全屏弹出。',
                action: OutlinedButton.icon(
                  onPressed: () => SystemSettings.openOverlaySettings(),
                  icon: const Icon(Icons.open_in_full, size: 18),
                  label: const Text('去开启悬浮窗'),
                ),
              ),
            if (Platform.isAndroid)
              _Item(
                icon: Icons.volume_up,
                color: AppPalette.warning,
                title: '闹钟声音',
                body: '请确保「闹钟响铃」渠道铃声不为"无"，并调高系统的"闹钟"音量'
                    '（闹钟走闹钟音量通道，不受通知静音影响）。'
                    '可在闹钟页「闹钟不响？」中试听铃声。',
                action: OutlinedButton.icon(
                  onPressed: () =>
                      SystemSettings.openChannelSettings(NotificationService.alarmChannelId),
                  icon: const Icon(Icons.volume_up, size: 18),
                  label: const Text('设置闹钟声音'),
                ),
              ),
            if (Platform.isAndroid)
              const _Item(
                icon: Icons.battery_saver,
                color: AppPalette.warning,
                title: '电池优化（国产 ROM 建议）',
                body: '为避免 MIUI / ColorOS 等系统清理后台，建议在'
                    '系统设置中允许轻流「自启动」并加入电池优化白名单（无障碍）。'
                    '提醒由系统闹钟调度，即使不做此项也能弹出。',
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () async {
                final db = await ref.read(databaseProvider.future);
                await SettingsRepo(db).set(kOnboardedKey, '1');
                await bootstrap(ref);
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppPalette.accent,
                foregroundColor: AppPalette.background,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('开始使用', style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final Widget? action;

  const _Item({required this.icon, required this.color, required this.title, required this.body, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppPalette.textPrimary)),
                const SizedBox(height: 6),
                Text(body, style: const TextStyle(fontSize: 12.5, color: AppPalette.textSecondary, height: 1.55)),
                if (action != null) ...[const SizedBox(height: 10), action!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
