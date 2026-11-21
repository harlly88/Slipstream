import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../app.dart';
import '../data/repositories.dart';
import '../providers.dart';
import '../services/ambient_generator.dart';
import '../services/system_settings.dart';

/// 闹钟全屏响铃页（v0.5）：循环播放"哔-嘟"铃声，响到用户点「关闭」为止
/// （10 分钟安全上限自动停止）。由闹钟通知的全屏意图/点击触发。
/// v0.6：铃声走系统"闹钟音量"通道（媒体音量静音也能响）+ 响铃期间屏幕常亮；
/// 关闭后停用该一次性闹钟（防止补响重复）。
class AlarmRingOverlay extends ConsumerStatefulWidget {
  final int? alarmId;
  final String title;

  const AlarmRingOverlay({super.key, required this.alarmId, required this.title});

  @override
  ConsumerState<AlarmRingOverlay> createState() => _AlarmRingOverlayState();
}

class _AlarmRingOverlayState extends ConsumerState<AlarmRingOverlay> {
  AudioPlayer? _player;
  Timer? _autoStop;

  @override
  void initState() {
    super.initState();
    SystemSettings.setKeepScreenOn(true); // 响铃期间不熄屏
    _startRinging();
    _autoStop = Timer(const Duration(minutes: 10), _close);
  }

  Future<void> _startRinging() async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/alarm_tone.wav');
      await file.writeAsBytes(AlarmToneGenerator.generate(), flush: true);
      final p = AudioPlayer();
      // 走系统"闹钟音量"通道（与系统闹钟一致），不受媒体音量静音影响
      await p.setAndroidAudioAttributes(
        const AndroidAudioAttributes(usage: AndroidAudioUsage.alarm),
      );
      await p.setFilePath(file.path);
      await p.setLoopMode(LoopMode.one);
      await p.setVolume(1.0);
      await p.play();
      if (mounted) {
        _player = p;
      } else {
        await p.dispose();
      }
    } catch (_) {
      // 播放失败不阻塞响铃页（通知长铃声仍在响）
    }
  }

  Future<void> _close() async {
    // 先取好依赖再清状态（清空后本组件即被移除，避免 dispose 后再用 ref）
    final id = widget.alarmId;
    final dbFuture = ref.read(databaseProvider.future);
    final notif = ref.read(notificationServiceProvider);
    ref.read(alarmRingProvider.notifier).state = null;
    SystemSettings.setKeepScreenOn(false);
    if (id == null) return;
    try {
      // 一次性闹钟响完自动停用（与任务提醒语义一致），避免补响重复
      await ReminderRepo(await dbFuture).setEnabled(id, enabled: false);
      await notif.cancelReminder(id);
    } catch (_) {}
  }

  @override
  void dispose() {
    _autoStop?.cancel();
    _player?.dispose();
    SystemSettings.setKeepScreenOn(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return Scaffold(
      backgroundColor: AppPalette.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
          child: Column(
            children: [
              const Spacer(),
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: AppPalette.accent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.alarm_on, size: 72, color: AppPalette.accentBright),
              ),
              const SizedBox(height: 28),
              Text(time,
                  style: const TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.w700,
                      color: AppPalette.textPrimary)),
              const SizedBox(height: 10),
              Text(widget.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 20, color: AppPalette.textPrimary)),
              const SizedBox(height: 6),
              const Text('闹钟响铃中', style: TextStyle(fontSize: 13, color: AppPalette.textSecondary)),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton(
                  onPressed: _close,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppPalette.accent,
                    foregroundColor: AppPalette.background,
                  ),
                  child: const Text('关闭', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
