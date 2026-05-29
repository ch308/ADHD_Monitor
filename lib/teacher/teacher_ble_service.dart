import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

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

class TeacherBleService {
  TeacherBleService({this.deviceNameKeyword = 'Mi Smart Band 6'});

  static const String _immediateAlertServiceUuid = '1802';
  static const String _alertLevelCharUuid = '2a06';

  final String deviceNameKeyword;
  BluetoothDevice? _teacherDevice;

  Future<void> dispose() async {
    final device = _teacherDevice;
    _teacherDevice = null;
    if (device == null) return;
    try {
      await device.disconnect();
    } catch (_) {}
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

  Future<TeacherBandVibrationResult> vibrateTeacherBand(
    String remoteId, {
    Duration scanTimeout = const Duration(seconds: 10),
  }) async {
    final allowed = await requestPermissions();
    if (!allowed) {
      return const TeacherBandVibrationResult(
        success: false,
        message: '还没有蓝牙权限，允许后才能测试老师手环震动',
      );
    }

    final device = await _findDeviceByRemoteId(remoteId, timeout: scanTimeout);
    if (device == null) {
      return const TeacherBandVibrationResult(
        success: false,
        message: '没有找到这只老师手环，请让手环靠近手机后再试',
      );
    }

    try {
      if (!device.isConnected) {
        await device.connect().timeout(const Duration(seconds: 12));
      }
      _teacherDevice = device;

      final services = await device.discoverServices().timeout(
            const Duration(seconds: 12),
          );
      final alertChar = _findCharacteristic(
        services,
        serviceUuid: _immediateAlertServiceUuid,
        characteristicUuid: _alertLevelCharUuid,
      );
      if (alertChar == null) {
        return const TeacherBandVibrationResult(
          success: false,
          message: '这只手环没有开放标准震动通道，需要继续验证小米手环专用指令',
        );
      }

      await alertChar.write(<int>[0x02], withoutResponse: false).timeout(
            const Duration(seconds: 5),
          );
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      try {
        await alertChar.write(<int>[0x00], withoutResponse: false).timeout(
              const Duration(seconds: 5),
            );
      } catch (_) {}
      return const TeacherBandVibrationResult(
        success: true,
        message: '已向老师手环发送测试震动，请确认手环是否震动',
      );
    } catch (_) {
      return const TeacherBandVibrationResult(
        success: false,
        message: '这次没有成功连上老师手环，请靠近后再试',
      );
    }
  }

  Future<BluetoothDevice?> _findDeviceByRemoteId(
    String remoteId, {
    required Duration timeout,
  }) async {
    final current = _teacherDevice;
    if (current != null && current.remoteId.str == remoteId) return current;

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

  BluetoothCharacteristic? _findCharacteristic(
    List<BluetoothService> services, {
    required String serviceUuid,
    required String characteristicUuid,
  }) {
    for (final service in services) {
      if (!_uuidMatches(service.uuid.str, serviceUuid)) continue;
      for (final characteristic in service.characteristics) {
        if (_uuidMatches(characteristic.uuid.str, characteristicUuid)) {
          return characteristic;
        }
      }
    }
    return null;
  }

  bool _uuidMatches(String actual, String expectedShortUuid) {
    final normalized = actual.toLowerCase();
    final expected = expectedShortUuid.toLowerCase();
    return normalized == expected || normalized.startsWith('0000$expected-');
  }
}
