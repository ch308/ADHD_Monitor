import 'dart:async';

import 'package:flutter/foundation.dart';
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

  /// Mi Band 6 / 6 NFC / 7 等 Huami 系列常见 OUI（MAC 前 3 字节，去掉冒号大写）。
  /// 实际广播名经常是空，名称匹配会漏；用 OUI 兜底比 `contains('MI')` 可靠。
  static const Set<String> _xiaomiHuamiOuis = <String>{
    'C8B021', // Mi Band 6 / 6 NFC（含日志中的 C8:B0:21）
    'EA3B1F',
    'D5FB3E',
    'F4980F', // Huami
    'C45BBE',
    'D58E7A',
    'E0CA3C',
    'F8AE8F',
    'F0846E',
    'F4F95B',
    'D40C4A',
    'C09F05',
    '885A92',
    '2C415A',
  };

  static bool _looksLikeMiBandResult(ScanResult r, String nameHint) {
    final name = r.device.platformName.trim();
    final lower = name.toLowerCase();
    if (lower.contains(nameHint.toLowerCase()) ||
        lower.contains('mi band') ||
        lower.contains('mi smart band') ||
        lower.contains('xiaomi smart band') ||
        lower.contains('redmi') ||
        lower.contains('amazfit')) {
      return true;
    }
    final ouis = r.device.remoteId.str.replaceAll(':', '').toUpperCase();
    if (ouis.length >= 6 && _xiaomiHuamiOuis.contains(ouis.substring(0, 6))) {
      return true;
    }
    final advertisedServices = <String>{
      ...r.advertisementData.serviceUuids.map((g) => g.str.toLowerCase()),
    };
    final hasMiService = advertisedServices.any((u) =>
        u == 'fee0' || u == 'fee1' ||
        u.startsWith('0000fee0-') || u.startsWith('0000fee1-'));
    if (hasMiService) return true;
    // 0x0157 = Anhui Huami（Mi Band 厂商 ID）
    if (r.advertisementData.manufacturerData.containsKey(0x0157)) return true;
    return false;
  }

  Future<List<TeacherBandScanResult>> scanMiBand6({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final allowed = await requestPermissions();
    if (!allowed) return const <TeacherBandScanResult>[];

    final results = <String, TeacherBandScanResult>{};

    void addResult(BluetoothDevice device, {int rssi = -127}) {
      final name = device.platformName.trim();
      final remoteId = device.remoteId.str;
      results.putIfAbsent(
        remoteId,
        () => TeacherBandScanResult(
          remoteId: remoteId,
          name: name.isEmpty ? '小米手环 6' : name,
          rssi: rssi,
        ),
      );
    }

    // 1) 已连接 / 系统配对里就有手环（带 180D 心率服务）→ 直接展示，不必等广播。
    try {
      for (final d in FlutterBluePlus.connectedDevices) {
        addResult(d, rssi: 0);
      }
    } catch (_) {}
    try {
      final sys = await FlutterBluePlus.systemDevices(<Guid>[
        Guid(MiBand6Auth.heartRateServiceUuid),
      ]);
      for (final d in sys) {
        addResult(d, rssi: 0);
      }
    } catch (_) {}

    final subscription = FlutterBluePlus.scanResults.listen((items) {
      for (final item in items) {
        if (!_looksLikeMiBandResult(item, deviceNameKeyword)) continue;
        final remoteId = item.device.remoteId.str;
        final name = item.device.platformName.trim();
        final prev = results[remoteId];
        if (prev == null || item.rssi > prev.rssi) {
          results[remoteId] = TeacherBandScanResult(
            remoteId: remoteId,
            name: name.isEmpty ? (prev?.name ?? '小米手环 6') : name,
            rssi: item.rssi,
          );
        }
      }
    });

    try {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      // 用 fee0 在系统层做一次精准过滤，命中率最高（Mi Band 一定广播 fee0）。
      try {
        await FlutterBluePlus.startScan(
          timeout: timeout,
          withServices: <Guid>[Guid('fee0')],
        );
        await Future<void>.delayed(timeout);
      } catch (e) {
        debugPrint('TeacherBleService: filtered scan failed, fallback -> $e');
      }
      // 有的 OEM ROM（如华为 EMUI）对 withServices 不一定准，再做一次开放扫描兜底。
      if (results.isEmpty) {
        try {
          await FlutterBluePlus.stopScan();
        } catch (_) {}
        await FlutterBluePlus.startScan(timeout: timeout);
        await Future<void>.delayed(timeout);
      }
    } finally {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
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

  Future<TeacherBandVibrationResult> vibrateAlertBand(
    MiBand6Auth client, {
    required String newAlertMessage,
  }) async {
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
      newAlertMessage: newAlertMessage,
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

  bool _sameBleRemoteId(String a, String b) {
    String norm(String s) =>
        s.toUpperCase().replaceAll(RegExp(r'[-:]'), '');
    return norm(a) == norm(b);
  }

  Future<BluetoothDevice?> _findDeviceByRemoteId(
    String remoteId, {
    required Duration timeout,
  }) async {
    for (final device in FlutterBluePlus.connectedDevices) {
      if (_sameBleRemoteId(device.remoteId.str, remoteId)) return device;
    }

    // 与家长端 [MiBand6Auth.findAlreadyConnectedBand] 一致：带心率服务 UUID，
    // 否则空列表在 Android 上往往拿不到「刚用过小米运动 / 本 App」的手环缓存。
    try {
      final systemDevices = await FlutterBluePlus.systemDevices(<Guid>[
        Guid(MiBand6Auth.heartRateServiceUuid),
      ]);
      for (final device in systemDevices) {
        if (_sameBleRemoteId(device.remoteId.str, remoteId)) return device;
      }
    } catch (_) {}

    final completer = Completer<BluetoothDevice?>();
    final subscription = FlutterBluePlus.scanResults.listen((items) {
      for (final item in items) {
        if (_sameBleRemoteId(item.device.remoteId.str, remoteId)) {
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
      final fromScan = await completer.future.timeout(
        timeout + const Duration(seconds: 1),
        onTimeout: () => null,
      );
      if (fromScan != null) return fromScan;
    } finally {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      await subscription.cancel();
    }

    // 已知 MAC（Android）时可直接构造设备引用再连，不必等广播进扫描结果。
    try {
      final direct = BluetoothDevice.fromId(remoteId);
      return direct;
    } catch (_) {
      return null;
    }
  }

  String? _normalizeAuthKey(String raw) {
    final normalized = raw.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(normalized)) return null;
    return normalized;
  }
}
