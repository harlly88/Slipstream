import 'dart:io';

import 'package:flutter/services.dart';

/// 系统设置直达（Android，MethodChannel 封装，宿主实现见 MainActivity.kt）。
/// 各方法失败时回落到应用详情页，返回是否成功打开设置页。
class SystemSettings {
  static const _channel = MethodChannel('dev.qingliu.qingliu/system_settings');

  static Future<bool> _invoke(String method, [Map<String, dynamic>? args]) async {
    if (!Platform.isAndroid) return false;
    try {
      await _channel.invokeMethod(method, args);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 应用通知设置（总开关）
  static Future<bool> openNotificationSettings() =>
      _invoke('openNotificationSettings');

  /// 指定通知渠道设置（铃声/振动，闹钟声音检查用）
  static Future<bool> openChannelSettings(String channelId) =>
      _invoke('openChannelSettings', {'channelId': channelId});

  /// 悬浮窗 / 后台弹出界面（全屏意图弹出的前提，MIUI 等需手动开）
  static Future<bool> openOverlaySettings() => _invoke('openOverlaySettings');

  /// 精确闹钟授权设置（Android 12+）
  static Future<bool> openExactAlarmSettings() => _invoke('openExactAlarmSettings');

  /// 响铃期间保持屏幕常亮（闹钟全屏响铃页用）
  static Future<bool> setKeepScreenOn(bool on) => _invoke('setKeepScreenOn', {'on': on});
}
