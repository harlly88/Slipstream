import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../app.dart';
import '../data/database.dart';
import '../data/repositories.dart';
import '../providers.dart';
import '../services/ambient_generator.dart';
import '../services/nlp_time_parser.dart';
import '../services/notification_service.dart';
import '../services/system_settings.dart';
import '../widgets/task_card.dart';

/// 智能闹钟页（v0.2，替代统计页）：自然语言生成一次性闹钟 + 闹钟管理
class AlarmPage extends ConsumerStatefulWidget {
  const AlarmPage({super.key});

  @override
  ConsumerState<AlarmPage> createState() => _AlarmPageState();
}

class _AlarmPageState extends ConsumerState<AlarmPage> {
  final _inputCtrl = TextEditingController();
  bool _parsing = false;
  AudioPlayer? _previewPlayer;
  bool _previewing = false;

  @override
  void dispose() {
    _inputCtrl.dispose();
    _previewPlayer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final alarmsAsync = ref.watch(alarmsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('闹钟', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        actions: [
          TextButton.icon(
            onPressed: _showRingCheck,
            icon: const Icon(Icons.volume_up, size: 18, color: AppPalette.accentBright),
            label: const Text('闹钟不响？', style: TextStyle(fontSize: 12, color: AppPalette.accentBright)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---------- 自然语言输入区 ----------
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.auto_awesome, size: 18, color: AppPalette.accentBright),
                      const SizedBox(width: 8),
                      const Text('智能闹钟', style: TextStyle(fontWeight: FontWeight.w600, color: AppPalette.textPrimary)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _inputCtrl,
                    style: const TextStyle(color: AppPalette.textPrimary),
                    decoration: const InputDecoration(hintText: '如：明天下午3点有一个视频会议'),
                    onSubmitted: (_) => _generate(),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _parsing ? null : _generate,
                    icon: _parsing
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.alarm_add),
                    label: const Text('生成闹钟'),
                    style: FilledButton.styleFrom(backgroundColor: AppPalette.accent, foregroundColor: AppPalette.background),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '支持：明天下午3点 / 周五晚上9点 / 过1小时提醒我喝水 / 半小时后',
                    style: TextStyle(fontSize: 11, color: AppPalette.textSecondary),
                  ),
                ],
              ),
            ),
          ),
          // ---------- 闹钟列表 ----------
          const SizedBox(height: 8),
          alarmsAsync.when(
            loading: () => const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator(color: AppPalette.accent))),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text('加载失败: $e', style: const TextStyle(color: AppPalette.danger)),
            ),
            data: (alarms) {
              if (alarms.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: EmptyHint('还没有闹钟\n用上面的输入框创建一个吧', icon: Icons.alarm_off_outlined),
                );
              }
              // 排序：未来闹钟在前（时间正序），已响过的沉底（时间正序）
              final now = DateTime.now();
              final sorted = [...alarms]..sort((a, b) {
                  final aPast = a.fireAt.isBefore(now);
                  final bPast = b.fireAt.isBefore(now);
                  if (aPast != bPast) return aPast ? 1 : -1;
                  return a.fireAt.compareTo(b.fireAt);
                });
              return Column(
                children: [
                  for (final r in sorted) _alarmTile(r),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // ---------- 闹钟响铃自检（v0.5） ----------

  /// 「闹钟不响？」检查面板：权限/设置清单 + 试听铃声
  Future<void> _showRingCheck() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('闹钟响铃检查',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppPalette.textPrimary)),
              const SizedBox(height: 4),
              const Text('逐项确认以下设置，闹钟才能准点响、响得久、锁屏全屏弹出。',
                  style: TextStyle(fontSize: 12, color: AppPalette.textSecondary)),
              const SizedBox(height: 12),
              _checkRow('通知权限', '允许轻流发送通知，否则闹钟无任何提示',
                  () => SystemSettings.openNotificationSettings()),
              _checkRow('精确闹钟', 'Android 12+ 需授权，保证到点秒级触发',
                  () => SystemSettings.openExactAlarmSettings()),
              _checkRow('悬浮窗 / 全屏闹钟', 'MIUI/HyperOS/ColorOS 需开启"后台弹出界面"，锁屏全屏响铃的前提',
                  () => SystemSettings.openOverlaySettings()),
              _checkRow('闹钟声音', '「闹钟响铃」渠道铃声不能为"无"，并调高系统"闹钟"音量',
                  () => SystemSettings.openChannelSettings(NotificationService.alarmChannelId)),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _togglePreview,
                icon: Icon(_previewing ? Icons.stop : Icons.play_arrow, size: 18),
                label: Text(_previewing ? '停止试听' : '试听铃声'),
              ),
            ],
          ),
        ),
      ),
    );
    // 面板关闭后停止试听
    if (_previewing) {
      await _previewPlayer?.stop();
      if (mounted) setState(() => _previewing = false);
    }
  }

  Widget _checkRow(String title, String body, VoidCallback onOpen) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle_outline, size: 18, color: AppPalette.accentBright),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppPalette.textPrimary)),
                Text(body,
                    style: const TextStyle(fontSize: 11.5, color: AppPalette.textSecondary, height: 1.5)),
              ],
            ),
          ),
          TextButton(onPressed: onOpen, child: const Text('去设置', style: TextStyle(fontSize: 12))),
        ],
      ),
    );
  }

  Future<void> _togglePreview() async {
    if (_previewing) {
      await _previewPlayer?.stop();
      if (mounted) setState(() => _previewing = false);
      return;
    }
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/alarm_tone.wav');
      await file.writeAsBytes(AlarmToneGenerator.generate(), flush: true);
      final p = _previewPlayer ??= AudioPlayer();
      // 试听与真实响铃走同一"闹钟音量"通道，验证的就是实际链路
      await p.setAndroidAudioAttributes(
        const AndroidAudioAttributes(usage: AndroidAudioUsage.alarm),
      );
      await p.setFilePath(file.path);
      await p.setLoopMode(LoopMode.one);
      await p.setVolume(1.0);
      await p.play();
      if (mounted) setState(() => _previewing = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('试听失败: $e')));
      }
    }
  }

  // ---------- 解析与保存 ----------

  Future<void> _generate() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _parsing = true);
    final parsed = parseChineseTime(text);
    setState(() => _parsing = false);
    if (!mounted) return;

    if (parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('没听懂时间，试试：「明天下午3点有一个视频会议」'),
      ));
      return;
    }
    await _showPreview(parsed);
  }

  /// 解析结果预览（时间 + 标题可改）
  Future<void> _showPreview(ParsedAlarm parsed) async {
    final titleCtrl = TextEditingController(text: parsed.title);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppPalette.surface,
        title: const Text('确认闹钟', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _fmtDateTime(parsed.fireAt),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppPalette.accentBright),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: titleCtrl,
              style: const TextStyle(color: AppPalette.textPrimary),
              decoration: const InputDecoration(hintText: '闹钟标题'),
            ),
            if (parsed.repeated) ...[
              const SizedBox(height: 8),
              const Text('暂不支持重复闹钟，将按单次创建', style: TextStyle(fontSize: 12, color: AppPalette.warning)),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppPalette.accent, foregroundColor: AppPalette.background),
            child: const Text('保存闹钟'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final title = titleCtrl.text.trim().isEmpty ? '闹钟' : titleCtrl.text.trim();
    final db = await ref.read(databaseProvider.future);
    final repo = ReminderRepo(db);
    final saved = await repo.create(RemindersCompanion.insert(
      title: Value(title),
      type: 'once',
      fireAt: parsed.fireAt,
    ));
    await ref.read(notificationServiceProvider).scheduleAlarm(saved, title: title);
    _inputCtrl.clear();
    ref.invalidate(todayAlarmsProvider);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已创建：${_fmtDateTime(parsed.fireAt)} $title')),
      );
    }
  }

  // ---------- 列表项 ----------

  Widget _alarmTile(Reminder r) {
    final title = r.title ?? '闹钟';
    final fired = r.fireAt.isBefore(DateTime.now()); // 已响过
    final isToday = _isSameDay(r.fireAt, DateTime.now());
    final dateLabel = fired
        ? '已响铃'
        : isToday
            ? '今天'
            : _isSameDay(r.fireAt, DateTime.now().add(const Duration(days: 1)))
                ? '明天'
                : '${r.fireAt.month}/${r.fireAt.day}';
    final hm = '${r.fireAt.hour.toString().padLeft(2, '0')}:${r.fireAt.minute.toString().padLeft(2, '0')}';

    // 已响过：整体置灰，标题划线，提示删除
    final textColor =
        fired ? AppPalette.textSecondary : AppPalette.textPrimary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(hm, style: TextStyle(fontSize: 17, color: textColor)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: fired
                                ? AppPalette.danger.withValues(alpha: 0.15)
                                : isToday
                                    ? AppPalette.accent.withValues(alpha: 0.2)
                                    : AppPalette.surfaceHigh,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(dateLabel,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: fired ? AppPalette.danger : AppPalette.textSecondary)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: textColor,
                        decoration: fired ? TextDecoration.lineThrough : null,
                        decorationColor: AppPalette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (fired)
                Tooltip(
                  message: '已响铃，删除',
                  child: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20, color: AppPalette.danger),
                    onPressed: () async {
                      final db = await ref.read(databaseProvider.future);
                      await ReminderRepo(db).delete(r.id);
                      await ref.read(notificationServiceProvider).cancelReminder(r.id);
                      ref.invalidate(todayAlarmsProvider);
                    },
                  ),
                )
              else ...[
                Switch(
                  value: r.enabled,
                  activeThumbColor: AppPalette.accent,
                  onChanged: (on) async {
                    final db = await ref.read(databaseProvider.future);
                    await ReminderRepo(db).setEnabled(r.id, enabled: on);
                    final notif = ref.read(notificationServiceProvider);
                    if (on) {
                      await notif.scheduleAlarm(r, title: title);
                    } else {
                      await notif.cancelReminder(r.id);
                    }
                    ref.invalidate(todayAlarmsProvider);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20, color: AppPalette.textSecondary),
                  onPressed: () async {
                    final db = await ref.read(databaseProvider.future);
                    await ReminderRepo(db).delete(r.id);
                    await ref.read(notificationServiceProvider).cancelReminder(r.id);
                    ref.invalidate(todayAlarmsProvider);
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _fmtDateTime(DateTime d) {
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}'
        ' 周${weekdays[d.weekday - 1]} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
