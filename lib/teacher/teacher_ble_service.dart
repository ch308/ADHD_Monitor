import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/miband_service.dart';

class TeacherBandScanResult {
  const TeacherBandScanResult({
    required this.remoteId,
    required this.name,
    required this.rssi,
  });

  final String remoteId;
  final String name;
  final int rssi;
}

class TeacherBandVibrationResult {
  const TeacherBandVibrationResult({
    required this.success,
    required this.message,
  });

  final bool success;
  final String message;
}

class TeacherBandConnectionResult {
  const TeacherBandConnectionResult({
    required this.success,
    required this.message,
    this.status,
    this.client,
    this.connectedName,
  });

  final bool success;
  final String message;
  final MiBandStatus? status;
  final MiBand6Auth? client;
  final String? connectedName;
}

class TeacherBleService {
  TeacherBleService({this.deviceNameKeyword = 'Mi Smart Band 6'});

  static const List<String> _stressCharacteristicUuids = <String>[
    '0000000d-0000-1000-8000-00805f9b34fb',
    '0000000e-0000-1000-8000-00805f9b34fb',
    '00000012-0000-1000-8000-00805f9b34fb',
    '00002a59-0000-1000-8000-00805f9b34fb',
  ];

  final String deviceNameKeyword;

  Future<void> dispose() async {
    return;
  }

  Future<bool> requestPermissions() async {
    final statuses = await <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    return (statuses[Permission.bluetoothScan]?.isGranted ?? false) &&
        (statuses[Permission.bluetoothConnect]?.isGranted ?? true);
  }

  Future<List<TeacherBandScanResult>> scanMiBand6({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final allowed = await requestPermissions();
    if (!allowed) return const <TeacherBandScanResult>[];

    final results = <String, TeacherBandScanResult>{};
    final subscription = FlutterBluePlus.scanResults.listen((items) {
      for (final item in items) {
        final name = item.device.platformName.trim();
        final remoteId = item.device.remoteId.str;
        final matchesName = name.contains(deviceNameKeyword);
        final matchesRemoteId = remoteId.toUpperCase().contains('MI');
        if (!matchesName && !matchesRemoteId) continue;

        results[remoteId] = TeacherBandScanResult(
          remoteId: remoteId,
          name: name.isEmpty ? '小米手环 6' : name,
          rssi: item.rssi,
        );
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: timeout);
      await Future<void>.delayed(timeout);
    } finally {
      await FlutterBluePlus.stopScan();
      await subscription.cancel();
    }

    final sorted = results.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return sorted;
  }

  Future<TeacherBandConnectionResult> connectBand({
    required String remoteId,
    required String authHexKey,
    int localAlertBpm = 120,
    Duration scanTimeout = const Duration(seconds: 10),
  }) async {
    final normalizedKey = _normalizeAuthKey(authHexKey);
    if (normalizedKey == null) {
      return const TeacherBandConnectionResult(
        success: false,
        message: '请输入 32 位手环连接密钥后再继续。',
        status: MiBandStatus(
          MiBandStage.authFailed,
          message: '连接密钥格式不对，请检查后再试。',
        ),
      );
    }

    final client = MiBand6Auth(
      authHexKey: normalizedKey,
      localAlertBpm: localAlertBpm,
      stressCharacteristicUuids: _stressCharacteristicUuids,
    );
    final allowed = await client.requestPermissions();
    if (!allowed) {
      await client.dispose();
      return const TeacherBandConnectionResult(
        success: false,
        message: '请先允许蓝牙权限后再试。',
        status: MiBandStatus(
          MiBandStage.permissionDenied,
          message: '蓝牙权限还没有打开，请先授权。',
        ),
      );
    }

    final device = await _findDeviceByRemoteId(remoteId, timeout: scanTimeout);
    if (device == null) {
      await client.dispose();
      return const TeacherBandConnectionResult(
        success: false,
        message: '没有找到这只手环，请让手环靠近手机后再试。',
        status: MiBandStatus(
          MiBandStage.notFound,
          message: '还没有找到这只手环，请靠近手机后再试。',
        ),
      );
    }

    try {
      await client.startAuthentication(device);
      final displayName = device.platformName.trim();
      return TeacherBandConnectionResult(
        success: true,
        message: '已连接到手环，可以继续测试震动或开始监测。',
        status: client.status.value,
        client: client,
        connectedName: displayName.isEmpty ? null : displayName,
      );
    } catch (_) {
      final status = client.status.value;
      final message = status.message ?? '这次没能连上手环，请靠近后重试。';
      await client.dispose();
      return TeacherBandConnectionResult(
        success: false,
        message: message,
        status: status,
      );
    }
  }

  Future<TeacherBandVibrationResult> vibrateConnectedBand(MiBand6Auth client) async {
    final status = client.status.value;
    if (!status.isConnected) {
      return const TeacherBandVibrationResult(
        success: false,
        message: '手环当前还没有连好，请重新绑定后再试。',
      );
    }

    final paused = await client.pauseHeartRateReceptionForTest();
    if (!paused) {
      return const TeacherBandVibrationResult(
        success: false,
        message: '这次还没准备好测试震动，请稍后再试。',
      );
    }

    try {
      final ok = await client.vibrateBandForTest(times: 3);
      if (!ok) {
        return const TeacherBandVibrationResult(
          success: false,
          message: '已经连上手环，但这次没有成功触发震动。',
        );
      }
      return const TeacherBandVibrationResult(
        success: true,
        message: '已向手环发送 3 次测试震动，请确认是否有明显震感。',
      );
    } finally {
      await client.resumeHeartRateReceptionAfterTest();
    }
  }

  Future<TeacherBandVibrationResult> vibrateAlertBand(MiBand6Auth client) async {
    final status = client.status.value;
    if (!status.isConnected) {
      return const TeacherBandVibrationResult(
        success: false,
        message: '老师手环当前没有连好，这次还不能发出震动提醒。',
      );
    }

    final ok = await client.vibrateBandForTest(
      times: 2,
      on: const Duration(milliseconds: 420),
      off: const Duration(milliseconds: 240),
    );
    if (!ok) {
      return const TeacherBandVibrationResult(
        success: false,
        message: '已经连上老师手环，但这次没有成功触发告警震动。',
      );
    }
    return const TeacherBandVibrationResult(
      success: true,
      message: '老师手环已发出告警震动。',
    );
  }

  Future<BluetoothDevice?> _findDeviceByRemoteId(
    String remoteId, {
    required Duration timeout,
  }) async {
    for (final device in FlutterBluePlus.connectedDevices) {
      if (device.remoteId.str == remoteId) return device;
    }

    try {
      final systemDevices = await FlutterBluePlus.systemDevices(const <Guid>[]);
      for (final device in systemDevices) {
        if (device.remoteId.str == remoteId) return device;
      }
    } catch (_) {}

    final completer = Completer<BluetoothDevice?>();
    final subscription = FlutterBluePlus.scanResults.listen((items) {
      for (final item in items) {
        if (item.device.remoteId.str == remoteId) {
          if (!completer.isCompleted) completer.complete(item.device);
          return;
        }
      }
    });

    try {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      await FlutterBluePlus.startScan(timeout: timeout);
      return await completer.future.timeout(
        timeout + const Duration(seconds: 1),
        onTimeout: () => null,
      );
    } finally {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      await subscription.cancel();
    }
  }

  String? _normalizeAuthKey(String raw) {
    final normalized = raw.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(normalized)) return null;
    return normalized;
  }
}
