import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'ambient_generator.dart';
import 'pomodoro_engine.dart';

/// 双耳节拍 WAV 合成器：纯代码合成，无音频资源文件（包体需求 <20MB）
class BinauralGenerator {
  static const sampleRate = 44100;
  static const durationSeconds = 8;

  /// 生成左右耳不同频率的正弦波立体声 WAV。
  /// 整数 Hz + 整数秒 → 每缓冲周期整数个完整波形，无缝循环。
  /// v0.5：叠加与海浪同款 4s+8s 双 LFO 音量包络（右耳相位错开 0.5s），
  /// 忽大忽小的浪涌感缓解单调；LFO 周期整除 8s，循环边界仍连续。
  static Uint8List generate({required int leftHz, required int rightHz, double amplitude = 0.5}) {
    final totalSamples = sampleRate * durationSeconds;
    final dataSize = totalSamples * 4; // 立体声 16bit
    final bytes = ByteData(44 + dataSize);

    void writeStr(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        bytes.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    // RIFF 头
    writeStr(0, 'RIFF');
    bytes.setUint32(4, 36 + dataSize, Endian.little);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little); // PCM
    bytes.setUint16(22, 2, Endian.little); // 立体声
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 4, Endian.little); // byte rate
    bytes.setUint16(32, 4, Endian.little); // block align
    bytes.setUint16(34, 16, Endian.little); // bits per sample
    writeStr(36, 'data');
    bytes.setUint32(40, dataSize, Endian.little);

    final maxVal = 32767 * amplitude;
    final stepL = 2 * math.pi * leftHz / sampleRate;
    final stepR = 2 * math.pi * rightHz / sampleRate;
    // 浪涌包络（与海浪同参数）：0.25Hz + 0.125Hz 双 LFO，右耳错相 0.5s
    const w1 = 2 * math.pi / 4;
    const w2 = 2 * math.pi / 8;
    const phaseR = 2 * math.pi * 0.5 / 8;
    var offset = 44;
    for (var i = 0; i < totalSamples; i++) {
      final t = i / sampleRate;
      final envL = 0.62 + 0.23 * math.sin(w1 * t) + 0.15 * math.sin(w2 * t);
      final envR = 0.62 +
          0.23 * math.sin(w1 * t - phaseR * 2) +
          0.15 * math.sin(w2 * t - phaseR);
      final l = (math.sin(stepL * i) * maxVal * envL).round().clamp(-32768, 32767);
      final r = (math.sin(stepR * i) * maxVal * envR).round().clamp(-32768, 32767);
      bytes.setInt16(offset, l, Endian.little);
      bytes.setInt16(offset + 2, r, Endian.little);
      offset += 4;
    }
    return bytes.buffer.asUint8List();
  }

  static Future<File> writeWav(AudioPreset preset, {double amplitude = 0.5}) async {
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/binaural_${preset.carrierHz}_${preset.rightHz}.wav');
    final data = generate(
        leftHz: preset.carrierHz, rightHz: preset.rightHz, amplitude: amplitude);
    await file.writeAsBytes(data, flush: true);
    return file;
  }
}

/// 音频诱导播放状态
enum AudioPlayState { idle, playing, error }

/// 音频诱导播放服务：后台持续播放（锁屏/切后台）。
/// v0.2：全链路错误处理；AudioService.init 15s 超时后降级为纯 just_audio 播放。
class AudioInductionService {
  AudioPlayer? _fallbackPlayer; // 降级播放器（无前台服务）
  AudioHandler? _handler;
  AudioPreset? _current;
  double _volume = 0.6;
  bool _handlerUnavailable = false; // AudioService 初始化失败/超时后置 true

  String? lastError;
  AudioPlayState state = AudioPlayState.idle;

  AudioPreset? get currentPreset => _current;
  double get volume => _volume;
  bool get isPlaying => state == AudioPlayState.playing;

  static bool get isSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  /// 初始化 AudioService（15s 超时兜底）
  Future<bool> ensureHandler() async {
    if (_handler != null) return true;
    if (_handlerUnavailable) return false;
    try {
      _handler = await AudioService.init(
        builder: () => _InductionHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'dev.qingliu.qingliu.induction',
          androidNotificationChannelName: '音频诱导',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      ).timeout(const Duration(seconds: 15));
      return true;
    } catch (e) {
      // 部分国产 ROM 绑定媒体浏览器服务会挂起/抛错 → 降级纯 just_audio
      _handlerUnavailable = true;
      _handler = null;
      lastError = '前台服务初始化失败（$e），已降级为普通播放';
      return false;
    }
  }

  /// 生成预设对应的 WAV 文件
  Future<File> _writeWav(AudioPreset preset) {
    if (preset.kind == AudioKind.ambient) {
      return AmbientGenerator.writeWav(preset);
    }
    return BinauralGenerator.writeWav(preset);
  }

  /// 开始播放指定预设（循环）。返回是否成功。
  Future<bool> play(AudioPreset preset, {double? volume}) async {
    if (!isSupported) {
      state = AudioPlayState.error;
      lastError = '当前平台不支持音频播放';
      return false;
    }
    if (preset.kind == AudioKind.silent) {
      await stop();
      return true;
    }
    if (volume != null) _volume = volume;
    _current = preset;
    try {
      final wav = await _writeWav(preset);
      final ok = await ensureHandler();
      if (ok && _handler != null) {
        final handler = _handler as _InductionHandler;
        await handler.load(wav, _volume);
        await handler.play();
      } else {
        // 降级：纯 just_audio（退到后台可能被杀，但先保证有声音）
        await _playFallback(wav);
      }
      state = AudioPlayState.playing;
      return true;
    } catch (e) {
      state = AudioPlayState.error;
      lastError = '$e';
      await _safeStop();
      return false;
    }
  }

  Future<void> _playFallback(File wav) async {
    await _fallbackPlayer?.dispose();
    _fallbackPlayer = AudioPlayer();
    final p = _fallbackPlayer!;
    await p.setFilePath(wav.path);
    await p.setVolume(_volume);
    await p.setLoopMode(LoopMode.one);
    await p.play();
  }

  Future<void> setVolume(double v) async {
    _volume = v;
    try {
      await (_handler as _InductionHandler?)?.setVolume(v);
      await _fallbackPlayer?.setVolume(v);
    } catch (_) {}
  }

  Future<void> stop() async {
    _current = null;
    await _safeStop();
    state = AudioPlayState.idle;
  }

  Future<void> _safeStop() async {
    try {
      await _handler?.stop();
    } catch (_) {}
    try {
      await _fallbackPlayer?.stop();
    } catch (_) {}
  }

  void dispose() {
    _fallbackPlayer?.dispose();
    _fallbackPlayer = null;
    _handler = null;
    state = AudioPlayState.idle;
  }
}

class _InductionHandler extends BaseAudioHandler {
  final AudioPlayer _player = AudioPlayer();

  _InductionHandler() {
    _player.playbackEventStream.map(_mapEvent).pipe(playbackState);
  }

  PlaybackState _mapEvent(PlaybackEvent event) => PlaybackState(
        processingState: const {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[_player.processingState]!,
        playing: _player.playing,
      );

  Future<void> load(File wav, double volume) async {
    await _player.setFilePath(wav.path);
    await _player.setVolume(volume);
    await _player.setLoopMode(LoopMode.one);
  }

  Future<void> setVolume(double v) => _player.setVolume(v);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }
}
