import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 前台服务回调入口（必须是顶层函数 + `vm:entry-point`）
@pragma('vm:entry-point')
void _bandKeepAliveEntrypoint() {
  FlutterForegroundTask.setTaskHandler(_BandKeepAliveTaskHandler());
}

/// 前台服务任务处理器：本应用中只是用来"占位保活"，
/// 真正的 BLE / 心率回调仍在主 isolate 的 [MiBand6Auth] 里完成；
/// 这里不做任何业务，只确保 Android 进程不会被息屏后回收。
class _BandKeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    debugPrint('FG keep-alive: onStart $timestamp');
  }

  @override
  void onRepeatEvent(DateTime timestamp, SendPort? sendPort) {
    // no-op: BLE 数据由主 isolate 处理
  }

  @override
  void onDestroy(DateTime timestamp, SendPort? sendPort) {
    debugPrint('FG keep-alive: onDestroy $timestamp');
  }
}

/// `flutter_foreground_task` 的薄包装。
///
/// 用法：
/// ```
/// await ForegroundTaskService.ensureInit();
/// await ForegroundTaskService.requestNotificationPermission();
/// await ForegroundTaskService.start();   // 进入 streaming 时
/// await ForegroundTaskService.stop();    // 用户退出登录或 dispose
/// ```
class ForegroundTaskService {
  ForegroundTaskService._();

  static bool _initDone = false;

  /// 仅 Android 真正生效；非 Android 平台所有方法 no-op。
  static bool get _supported =>
      defaultTargetPlatform == TargetPlatform.android;

  /// 配置通知通道与前台服务策略。可重复调用，幂等。
  static Future<void> ensureInit() async {
    if (!_supported) return;
    if (_initDone) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'adhd_band_keepalive',
        channelName: 'ADHD 专注精灵 · 手环守护',
        channelDescription: '保持小米手环 BLE 连接，息屏后仍可推送心率',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 5000,
        isOnceEvent: false,
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
    _initDone = true;
  }

  /// 申请 Android 13+ 的 POST_NOTIFICATIONS 权限（无前台通知拉不起前台服务）。
  static Future<bool> requestNotificationPermission() async {
    if (!_supported) return true;
    final cur = await FlutterForegroundTask.checkNotificationPermission();
    if (cur == NotificationPermission.granted) return true;
    final r = await FlutterForegroundTask.requestNotificationPermission();
    return r == NotificationPermission.granted;
  }

  /// 启动前台服务（重复调用安全：已运行时直接返回 true）。
  static Future<bool> start({
    String title = 'ADHD 专注精灵 · 守护中',
    String text = '正在与小米手环保持连接',
  }) async {
    if (!_supported) return false;
    await ensureInit();
    if (await FlutterForegroundTask.isRunningService) {
      // 已运行，刷新一下通知文案即可
      try {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
        );
      } catch (_) {}
      return true;
    }
    final result = await FlutterForegroundTask.startService(
      notificationTitle: title,
      notificationText: text,
      callback: _bandKeepAliveEntrypoint,
    );
    if (!result.success) {
      debugPrint('FG keep-alive: startService failed -> ${result.error}');
      return false;
    }
    return true;
  }

  /// 停止前台服务（未运行时安全 no-op）。
  static Future<void> stop() async {
    if (!_supported) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      debugPrint('FG keep-alive: stopService error -> $e');
    }
  }
}
