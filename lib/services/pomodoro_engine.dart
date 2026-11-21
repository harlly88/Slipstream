import 'dart:convert';

/// 专注计时状态（时间戳为唯一真源，禁止依赖前台 tick 累计）
/// v0.2：纯倒计时，无休息阶段 / 轮数 / 任务关联
class PomodoroState {
  final String phase; // idle / focus
  final DateTime? startedAt;
  final int plannedMinutes;
  final Duration pausedAccum; // 累计暂停时长
  final DateTime? pausedAt; // 正在暂停的时刻

  const PomodoroState({
    this.phase = 'idle',
    this.startedAt,
    this.plannedMinutes = 25,
    this.pausedAccum = Duration.zero,
    this.pausedAt,
  });

  static const idle = PomodoroState();

  bool get isRunning => phase != 'idle' && startedAt != null;
  bool get isPaused => pausedAt != null;

  /// 结束时刻 = 开始 + 暂停累计 + 计划时长
  DateTime? get endAt {
    if (startedAt == null) return null;
    return startedAt!
        .add(pausedAccum)
        .add(Duration(minutes: plannedMinutes));
  }

  /// 剩余时长（暂停时冻结）
  Duration remainingOf(DateTime now) {
    final end = endAt;
    if (end == null) return Duration.zero;
    if (pausedAt != null) {
      // 暂停时：剩余 = 计划时长 - 已运行时长（不含暂停）
      final elapsedRunning = pausedAt!.difference(startedAt!) - pausedAccum;
      final planned = Duration(minutes: plannedMinutes);
      final rem = planned - elapsedRunning;
      return rem.isNegative ? Duration.zero : rem;
    }
    final rem = end.difference(now);
    return rem.isNegative ? Duration.zero : rem;
  }

  /// 是否已到结束时刻（恢复 UI / 重启补记判断）
  bool isExpired(DateTime now) => endAt != null && now.isAfter(endAt!);

  Map<String, dynamic> toJson() => {
        'phase': phase,
        'startedAt': startedAt?.toIso8601String(),
        'plannedMinutes': plannedMinutes,
        'pausedAccumMs': pausedAccum.inMilliseconds,
        'pausedAt': pausedAt?.toIso8601String(),
      };

  static PomodoroState fromJson(Map<String, dynamic> j) => PomodoroState(
        phase: j['phase'] == 'focus' ? 'focus' : 'idle',
        startedAt:
            j['startedAt'] == null ? null : DateTime.parse(j['startedAt'] as String),
        plannedMinutes: (j['plannedMinutes'] as num?)?.toInt() ?? 25,
        pausedAccum: Duration(milliseconds: (j['pausedAccumMs'] as num?)?.toInt() ?? 0),
        pausedAt: j['pausedAt'] == null ? null : DateTime.parse(j['pausedAt'] as String),
      );

  static String encode(PomodoroState s) => jsonEncode(s.toJson());

  static PomodoroState? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return PomodoroState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  PomodoroState copyWith({
    String? phase,
    DateTime? startedAt,
    int? plannedMinutes,
    Duration? pausedAccum,
    DateTime? pausedAt,
    bool clearPausedAt = false,
  }) =>
      PomodoroState(
        phase: phase ?? this.phase,
        startedAt: startedAt ?? this.startedAt,
        plannedMinutes: plannedMinutes ?? this.plannedMinutes,
        pausedAccum: pausedAccum ?? this.pausedAccum,
        pausedAt: clearPausedAt ? null : (pausedAt ?? this.pausedAt),
      );

  PomodoroState startFocus({required int minutes}) => copyWith(
        phase: 'focus',
        startedAt: DateTime.now(),
        plannedMinutes: minutes,
        pausedAccum: Duration.zero,
        clearPausedAt: true,
      );

  PomodoroState pause() => copyWith(pausedAt: DateTime.now());

  PomodoroState resume({DateTime? now}) {
    if (pausedAt == null) return this;
    final extra = (now ?? DateTime.now()).difference(pausedAt!);
    return copyWith(
      pausedAccum: pausedAccum + extra,
      clearPausedAt: true,
    );
  }
}

/// 专注设置（v0.2：只保留专注时长）
class PomodoroSettings {
  final int focusMinutes;

  const PomodoroSettings({this.focusMinutes = 25});

  PomodoroSettings copyWith({int? focusMinutes}) =>
      PomodoroSettings(focusMinutes: focusMinutes ?? this.focusMinutes);

  Map<String, dynamic> toJson() => {'focusMinutes': focusMinutes};

  /// 兼容旧版 JSON（多余字段忽略）
  static PomodoroSettings fromJson(Map<String, dynamic> j) => PomodoroSettings(
        focusMinutes: (j['focusMinutes'] as num?)?.toInt() ?? 25,
      );
}

/// 音频诱导类型
enum AudioKind { binaural, ambient, silent }

/// 环境音类型
enum AmbientNoise { rain, wave }

/// 音频诱导预设（双耳节拍 / 环境音合成 / 静音）
class AudioPreset {
  final String name;
  final AudioKind kind;
  final int carrierHz; // 双耳：载波频率（左耳）
  final int beatHz; // 双耳：差频
  final AmbientNoise? noise; // 环境：雨声/海浪
  final String desc;

  const AudioPreset({
    required this.name,
    required this.kind,
    this.carrierHz = 0,
    this.beatHz = 0,
    this.noise,
    required this.desc,
  });

  int get rightHz => carrierHz + beatHz;

  static const presets = [
    AudioPreset(name: '专注', kind: AudioKind.binaural, carrierHz: 432, beatHz: 12, desc: '12Hz Alpha 放松而清醒，日常专注'),
    AudioPreset(name: '思考', kind: AudioKind.binaural, carrierHz: 332, beatHz: 24, desc: '24Hz Beta 高警觉度，脑力攻坚'),
    AudioPreset(name: '冥想', kind: AudioKind.binaural, carrierHz: 180, beatHz: 8, desc: '8Hz Theta 深度冥想式心流'),
    AudioPreset(name: '睡眠', kind: AudioKind.binaural, carrierHz: 140, beatHz: 3, desc: '3Hz Delta 助眠'),
    AudioPreset(name: '雨声', kind: AudioKind.ambient, noise: AmbientNoise.rain, desc: '白噪声基底 + 雨滴点缀'),
    AudioPreset(name: '海浪', kind: AudioKind.ambient, noise: AmbientNoise.wave, desc: '布朗噪声 + 浪涌节奏'),
    AudioPreset(name: '静音', kind: AudioKind.silent, desc: '不播放音频诱导'),
  ];

  /// 旧版预设名兼容映射
  static String? migrateName(String oldName) => switch (oldName) {
        '阿尔法·专注' => '专注',
        '贝塔·警觉' => '思考',
        '西塔·深度' => '冥想',
        '无音频' => '静音',
        _ => null,
      };

  Map<String, dynamic> toJson() => {'name': name};
}
