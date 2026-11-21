import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../data/repositories.dart';
import '../providers.dart';
import '../services/audio_induction.dart';
import '../services/pomodoro_engine.dart';

/// 专注页（v0.2）：纯倒计时 + 音频诱导，无任务/项目关联
class FocusPage extends ConsumerWidget {
  const FocusPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(pomodoroProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('专注', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
      ),
      body: state.isRunning ? _RunningView(state: state) : const _IdleView(),
    );
  }
}

/// 待机视图：大圆环启动 + 时长快捷选择 + 音频诱导
class _IdleView extends ConsumerWidget {
  const _IdleView();

  static const _quickMinutes = [15, 25, 45, 60];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(pomodoroSettingsProvider);

    return settingsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator(color: AppPalette.accent)),
      error: (e, _) => Center(child: Text('加载失败: $e', style: const TextStyle(color: AppPalette.danger))),
      data: (settings) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 24),
          // 大圆环启动
          Center(
            child: GestureDetector(
              onTap: () => ref.read(pomodoroProvider.notifier).startFocus(),
              child: Container(
                width: 200, height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppPalette.surface,
                  border: Border.all(color: AppPalette.accent, width: 3),
                  boxShadow: [BoxShadow(color: AppPalette.accent.withValues(alpha: 0.2), blurRadius: 40, spreadRadius: 4)],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.play_arrow, size: 52, color: AppPalette.accentBright),
                    const SizedBox(height: 6),
                    Text('${settings.focusMinutes} 分钟', style: const TextStyle(fontSize: 16, color: AppPalette.textPrimary)),
                    const Text('点击开始', style: TextStyle(fontSize: 12, color: AppPalette.textSecondary)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
          // 时长快捷选择
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final m in _quickMinutes)
                ChoiceChip(
                  label: Text('$m 分钟', style: const TextStyle(fontSize: 13)),
                  selected: settings.focusMinutes == m,
                  onSelected: (_) => _setMinutes(ref, m),
                  selectedColor: AppPalette.accent,
                  backgroundColor: AppPalette.surface,
                  labelStyle: TextStyle(
                      color: settings.focusMinutes == m ? AppPalette.background : AppPalette.textPrimary),
                  showCheckmark: false,
                ),
            ],
          ),
          const SizedBox(height: 24),
          const _AudioControl(enabled: true),
        ],
      ),
    );
  }

  /// 选中即改本次时长并写入设置
  Future<void> _setMinutes(WidgetRef ref, int minutes) async {
    final db = await ref.read(databaseProvider.future);
    await SettingsRepo(db).set(
        kPomodoroSettingsKey, jsonEncode(PomodoroSettings(focusMinutes: minutes).toJson()));
  }
}

/// 计时进行中视图
class _RunningView extends ConsumerWidget {
  final PomodoroState state;
  const _RunningView({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remaining = state.remainingOf(DateTime.now());
    final progress = state.plannedMinutes == 0
        ? 0.0
        : 1.0 - remaining.inSeconds / (state.plannedMinutes * 60);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SizedBox(height: 16),
        SizedBox(
          width: 260, height: 260,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                strokeWidth: 8,
                strokeCap: StrokeCap.round,
                backgroundColor: AppPalette.surface,
                color: AppPalette.accent,
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.timer, size: 36, color: AppPalette.accentBright),
                  const SizedBox(height: 8),
                  Text(
                    _fmt(remaining),
                    style: const TextStyle(fontSize: 46, fontWeight: FontWeight.w300, color: AppPalette.textPrimary),
                  ),
                  Text(
                    '专注中 · 共 ${state.plannedMinutes} 分钟',
                    style: const TextStyle(fontSize: 13, color: AppPalette.textSecondary),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (state.isPaused)
              FilledButton.icon(
                onPressed: () => ref.read(pomodoroProvider.notifier).resume(),
                icon: const Icon(Icons.play_arrow),
                label: const Text('继续'),
                style: FilledButton.styleFrom(backgroundColor: AppPalette.accent, foregroundColor: AppPalette.background),
              )
            else
              FilledButton.icon(
                onPressed: () => ref.read(pomodoroProvider.notifier).pause(),
                icon: const Icon(Icons.pause),
                label: const Text('暂停'),
                style: FilledButton.styleFrom(backgroundColor: AppPalette.surfaceHigh, foregroundColor: AppPalette.textPrimary),
              ),
            const SizedBox(width: 16),
            TextButton.icon(
              onPressed: () => ref.read(pomodoroProvider.notifier).abandon(),
              icon: const Icon(Icons.stop_circle_outlined, color: AppPalette.danger),
              label: const Text('停止', style: TextStyle(color: AppPalette.danger)),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _AudioControl(enabled: !state.isPaused),
      ],
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours > 0 ? '${d.inHours}:' : ''}$m:$s';
  }
}

/// 音频诱导控制（预设 + 音量 + 试听）
class _AudioControl extends ConsumerStatefulWidget {
  final bool enabled;
  const _AudioControl({required this.enabled});

  @override
  ConsumerState<_AudioControl> createState() => _AudioControlState();
}

class _AudioControlState extends ConsumerState<_AudioControl> {
  double _volume = 0.6;

  @override
  void initState() {
    super.initState();
    _loadVolume();
  }

  Future<void> _loadVolume() async {
    final db = await ref.read(databaseProvider.future);
    final raw = await SettingsRepo(db).get(kAudioVolumeKey);
    if (raw != null && mounted) setState(() => _volume = double.tryParse(raw) ?? 0.6);
  }

  @override
  Widget build(BuildContext context) {
    final presetAsync = ref.watch(audioPresetProvider);
    final preset = presetAsync.value ?? AudioPreset.presets.first;
    final supported = AudioInductionService.isSupported;
    final audio = ref.read(audioServiceProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.graphic_eq, size: 18, color: AppPalette.accentBright),
                const SizedBox(width: 8),
                const Text('音频诱导', style: TextStyle(fontWeight: FontWeight.w600, color: AppPalette.textPrimary)),
                const Spacer(),
                if (!supported)
                  const Text('当前平台不支持', style: TextStyle(fontSize: 11, color: AppPalette.textSecondary))
                else if (preset.kind == AudioKind.silent)
                  const Text('静音', style: TextStyle(fontSize: 11, color: AppPalette.textSecondary))
                else if (!widget.enabled)
                  const Text('暂停中', style: TextStyle(fontSize: 11, color: AppPalette.textSecondary))
                else if (audio.isPlaying)
                  const Text('播放中', style: TextStyle(fontSize: 11, color: AppPalette.accent))
                else
                  const Text('未播放', style: TextStyle(fontSize: 11, color: AppPalette.textSecondary)),
              ],
            ),
            if (supported) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in AudioPreset.presets)
                    ChoiceChip(
                      label: Text(p.name, style: const TextStyle(fontSize: 12)),
                      selected: preset.name == p.name,
                      onSelected: widget.enabled
                          ? (_) => _selectPreset(p)
                          : null,
                      selectedColor: AppPalette.accent,
                      backgroundColor: AppPalette.background,
                      labelStyle: TextStyle(
                          color: preset.name == p.name ? AppPalette.background : AppPalette.textPrimary),
                      showCheckmark: false,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(preset.desc, style: const TextStyle(fontSize: 11, color: AppPalette.textSecondary)),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.volume_down, size: 18, color: AppPalette.textSecondary),
                  Expanded(
                    child: Slider(
                      value: _volume,
                      onChanged: widget.enabled ? (v) async {
                        setState(() => _volume = v);
                        await ref.read(audioServiceProvider).setVolume(v);
                        final db = await ref.read(databaseProvider.future);
                        await SettingsRepo(db).set(kAudioVolumeKey, v.toStringAsFixed(2));
                      } : null,
                      activeColor: AppPalette.accent,
                    ),
                  ),
                  const Icon(Icons.volume_up, size: 18, color: AppPalette.textSecondary),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 切换预设：写入设置；计时中立即生效（静音→停止，其他→播放）
  Future<void> _selectPreset(AudioPreset p) async {
    final db = await ref.read(databaseProvider.future);
    await SettingsRepo(db).set(kAudioPresetKey, '{"name": "${p.name}"}');
    // 计时中立即切换（静音 → 停止当前音频；其他 → 播放）
    final state = ref.read(pomodoroProvider);
    if (state.isRunning && !state.isPaused) {
      final audio = ref.read(audioServiceProvider);
      if (p.kind == AudioKind.silent) {
        await audio.stop();
      } else {
        final ok = await audio.play(p, volume: _volume);
        if (!ok && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('音频启动失败: ${audio.lastError ?? '未知错误'}')),
          );
        }
      }
    }
    if (mounted) setState(() {});
  }
}
