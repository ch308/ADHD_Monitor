import 'dart:async';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/band_stress_data.dart';
import '../models/heart_rate_data.dart';
import 'cloud_service.dart';

/// 手环连接生命周期阶段。
///
/// UI 层应订阅 [MiBand6Auth.status] 来根据这个枚举给用户提示
/// （连接进度、失败原因、操作建议等）。
enum MiBandStage {
  /// 还未尝试连接（应用刚启动、尚未触发 bootstrap）
  idle,

  /// 缺少蓝牙/定位权限
  permissionDenied,

  /// 手机蓝牙未开启
  bluetoothOff,

  /// 正在扫描手环
  scanning,

  /// 扫描完成、未发现可识别的手环
  notFound,

  /// 已发现，正在建立 GATT 连接
  connecting,

  /// 已连接，正在跑小米私有 AES 握手
  authenticating,

  /// 私有握手失败（Auth Key 不匹配或超时）
  authFailed,

  /// 已订阅标准 180D/2A37，但还没收到第一条心率 notify
  hrSubscribed,

  /// 订阅后 15s 仍无 notify —— 多半是手环侧未开「运动心率广播」
  awaitingBroadcast,

  /// 正在持续推送心率（已收到至少一条 notify）
  streaming,

  /// 已主动/被动断开
  disconnected,

  /// 其它未归类错误
  error,
}

/// 手环状态快照，配合 [MiBand6Auth.status] 暴露给 UI。
class MiBandStatus {
  const MiBandStatus(this.stage, {this.message, this.lastSampleAt});

  final MiBandStage stage;

  /// 人类可读的细节（错误信息、当前在做什么等）
  final String? message;

  /// 最近一次收到 notify 的时间，仅在 [MiBandStage.streaming] 才有意义
  final DateTime? lastSampleAt;

  bool get isWorking =>
      stage == MiBandStage.scanning ||
      stage == MiBandStage.connecting ||
      stage == MiBandStage.authenticating;

  bool get isConnected =>
      stage == MiBandStage.hrSubscribed ||
      stage == MiBandStage.streaming ||
      stage == MiBandStage.awaitingBroadcast;

  bool get isFailure =>
      stage == MiBandStage.permissionDenied ||
      stage == MiBandStage.bluetoothOff ||
      stage == MiBandStage.notFound ||
      stage == MiBandStage.authFailed ||
      stage == MiBandStage.disconnected ||
      stage == MiBandStage.error;
}

/// 小米手环 6 的 BLE 心率服务封装。
///
/// 完整流程（按顺序执行）：
///   1. 申请 Android 蓝牙/定位运行时权限；
///   2. 在已被系统连接的设备列表中找手环 → 否则做一次有超时的扫描；
///   3. 与手环建立 GATT 连接、`discoverServices`；
///   4. 若提供了 [authHexKey]，先在 `FEE1 / 0x0009` 上跑小米私有
///      AES-128 ECB 握手（step1 注册 key → step2 取 nonce → step3
///      回传加密结果），手环解锁后才会推心率 notify；
///   5. 订阅标准 Heart Rate Service（180D / 2A37），按 Bluetooth SIG
///      协议解析单字节 / 双字节 BPM；
///   6. 端侧本地缓冲，[uploadInterval] 周期内交给 [CloudService] 异步打包；
///   7. 暴露 [bpmStream]，供 UI 层接入实时数值。
class MiBand6Auth {
  MiBand6Auth({
    this.cloudService,
    this.authHexKey,
    this.stressCharacteristicUuids = const <String>[],
    this.deviceNameKeyword = 'Mi Smart Band 6',
    this.remoteIdKeyword = 'MI',
    this.localAlertBpm = 100,
    this.uploadInterval = const Duration(seconds: 30),
    this.scanTimeout = const Duration(seconds: 15),
    this.authTimeout = const Duration(seconds: 12),
  });

  /// 上报通道，可在 host 切换后由外部直接更新 [CloudService.serverHost]。
  CloudService? cloudService;

  /// 32 位 Hex（16 字节）厂商鉴权密钥。
  ///
  /// 来源：从 Mi Fit / Zepp Life 抓包或厂商工具中提取，每只手环唯一。
  /// 为 null 或空串时，跳过私有握手只走标准 180D/2A37（仅作为兜底，
  /// 小米手环 6 本身不解锁是收不到心率 notify 的）。
  String? authHexKey;

  /// 压力值私有特征候选 UUID。
  ///
  /// 小米手环 6 的压力值没有标准 BLE UUID，不同固件/Zepp 版本暴露方式可能不同。
  /// 这里保留可配置入口：如果你从 `_debugDumpGattServices` 日志中确认了压力值
  /// 特征 UUID，填入后服务会尝试 read/notify，并把 0-100 的值推到 [stressStream]。
  final List<String> stressCharacteristicUuids;

  /// 设备 BLE 广播名匹配关键字。
  final String deviceNameKeyword;

  /// 兜底：部分系统下广播名为空，用 remoteId 关键字粗匹配。
  final String remoteIdKeyword;

  /// 本地阈值（仅做 UI 颜色提示，不替代云端判定）。
  final int localAlertBpm;

  /// 批量上报间隔。
  final Duration uploadInterval;

  /// 扫描超时。
  final Duration scanTimeout;

  /// 私有握手超时（包含 step1→step2→step3 全程）。
  final Duration authTimeout;

  /// 标准 Heart Rate Service / Characteristic
  static const String heartRateServiceUuid = '180d';
  static const String heartRateCharUuid = '2a37';

  /// 小米手环 6 私有鉴权服务 / 特征值
  static const String miAuthServiceShort = 'fee1';
  static const String miAuthCharUuid = '00000009-0000-1000-8000-00805f9b34fb';

  final StreamController<HeartRateSample> _hrController =
      StreamController<HeartRateSample>.broadcast();
  final StreamController<BandStressSample> _stressController =
      StreamController<BandStressSample>.broadcast();

  /// 实时心率流，每条 notify 都会推一个 [HeartRateSample]。
  Stream<HeartRateSample> get bpmStream => _hrController.stream;

  /// 压力值流。仅当 [stressCharacteristicUuids] 命中并成功 read/notify 时才有数据。
  Stream<BandStressSample> get stressStream => _stressController.stream;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _hrChar;
  BluetoothCharacteristic? _stressChar;
  StreamSubscription<List<int>>? _hrSub;
  StreamSubscription<List<int>>? _stressSub;
  Timer? _stressPollTimer;
  int? _lastStressRaw;
  int _stressStaleCount = 0;

  // ── 鉴权用 ──
  BluetoothCharacteristic? _authChar;
  StreamSubscription<List<int>>? _authSub;
  Completer<bool>? _authCompleter;

  // ── 自动重连用 ──
  StreamSubscription<BluetoothConnectionState>? _connStateSub;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _userInitiatedDisconnect = false;
  static const List<int> _reconnectBackoffSeconds = <int>[5, 10, 20, 30, 60];

  final List<HeartRateSample> _buffer = <HeartRateSample>[];
  Timer? _uploadTimer;
  Timer? _noBroadcastTimer;

  bool _streaming = false;
  bool _authenticated = false;

  /// UI 可观察的连接状态。
  final ValueNotifier<MiBandStatus> status =
      ValueNotifier<MiBandStatus>(const MiBandStatus(MiBandStage.idle));

  void _setStage(MiBandStage stage, {String? message}) {
    status.value = MiBandStatus(
      stage,
      message: message,
      lastSampleAt: status.value.lastSampleAt,
    );
  }

  /// 是否已经在订阅手环心率（用于外层避免重复扫描）。
  bool get isStreaming => _streaming;

  /// 私有握手是否成功（authHexKey 为空时永远为 false）。
  bool get isAuthenticated => _authenticated;

  /// 当前绑定的手环（已建立或正在建立连接）。
  BluetoothDevice? get currentDevice => _device;

  /// 已连接手环的 MAC 地址（remoteId），未连接时返回 null。
  String? get connectedMacAddress => _device?.remoteId.str;

  /// 申请 Android 端必须的运行时权限：
  ///   - bluetoothScan / bluetoothConnect（Android 12+）
  ///   - location（Android < 12 扫描必须）
  ///
  /// iOS 在 Info.plist 配置即可，无需运行时申请，这里直接返回 true。
  Future<bool> requestPermissions() async {
    if (!_isAndroid) return true;
    final statuses = await <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
    final ok = (statuses[Permission.bluetoothScan]?.isGranted ?? false) &&
        (statuses[Permission.bluetoothConnect]?.isGranted ?? true);
    if (!ok) {
      debugPrint('MiBand6Auth: BLE permissions denied.');
      _setStage(
        MiBandStage.permissionDenied,
        message: '蓝牙权限被拒绝，请在系统设置里允许「附近的设备 / 蓝牙」与「位置信息」。',
      );
    }
    return ok;
  }

  /// 由外层把蓝牙适配器状态转交给服务（用于在 UI 上显示「蓝牙未开启」）。
  void notifyBluetoothState(BluetoothAdapterState state) {
    if (state == BluetoothAdapterState.on) {
      if (status.value.stage == MiBandStage.bluetoothOff) {
        _setStage(MiBandStage.idle);
      }
    } else {
      _setStage(
        MiBandStage.bluetoothOff,
        message: '手机蓝牙已关闭，请在控制中心开启蓝牙后再试。',
      );
    }
  }

  /// 在系统已经连接的设备列表中找手环（用户在系统设置里已经配过）。
  /// 返回 null 表示没找到，调用方应转入 [scanForBand]。
  Future<BluetoothDevice?> findAlreadyConnectedBand() async {
    final List<BluetoothDevice> candidates = <BluetoothDevice>[];
    try {
      // flutter_blue_plus 1.32+ 推荐的 systemDevices 接口
      final sys = await FlutterBluePlus.systemDevices(<Guid>[
        Guid(heartRateServiceUuid),
      ]);
      candidates.addAll(sys);
    } catch (_) {
      // 老版本兜底
    }
    try {
      candidates.addAll(FlutterBluePlus.connectedDevices);
    } catch (_) {}
    for (final d in candidates) {
      if (_looksLikeMiBand(d)) return d;
    }
    return null;
  }

  /// 走一次有超时的常规扫描。
  Future<BluetoothDevice?> scanForBand({Duration? timeout}) async {
    final t = timeout ?? scanTimeout;
    _setStage(MiBandStage.scanning, message: '正在搜索手环…');
    final completer = Completer<BluetoothDevice?>();
    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (_looksLikeMiBand(r.device)) {
          if (!completer.isCompleted) completer.complete(r.device);
          break;
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(timeout: t);
      final found = await completer.future
          .timeout(t + const Duration(seconds: 1), onTimeout: () => null);
      if (found == null) {
        _setStage(
          MiBandStage.notFound,
          message: '未发现小米手环 6。请确认手环靠近手机、电量充足、且未被其它 App 长连占用。',
        );
      }
      return found;
    } catch (e) {
      debugPrint('MiBand6Auth: scan error $e');
      _setStage(MiBandStage.error, message: '扫描出错：$e');
      return null;
    } finally {
      await sub.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }
  }

  /// 与给定手环完成「连接 → 服务发现 → 私有握手 → 心率订阅 → 上报」的全套流程。
  /// 调用前请确保 [device] 已扫描到（或刚从系统连接列表里取出）。
  Future<void> startAuthentication(BluetoothDevice device) async {
    _userInitiatedDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    _device = device;
    _setStage(MiBandStage.connecting, message: '已发现手环，正在建立连接…');
    if (!device.isConnected) {
      try {
        await device.connect();
      } catch (e) {
        debugPrint('MiBand6Auth: connect error $e');
        _setStage(MiBandStage.error, message: '连接失败：$e');
        // 走重连，避免一次失败就放弃（OEM 偶尔 ESP-side timeout）
        _scheduleReconnect();
        rethrow;
      }
    }

    // 监听底层连接状态：意外断开走指数退避自动重连
    await _connStateSub?.cancel();
    _connStateSub = device.connectionState.listen((connState) {
      if (connState == BluetoothConnectionState.disconnected) {
        _onUnexpectedDisconnect();
      }
    });

    final services = await device.discoverServices();
    _debugDumpGattServices(services);

    // 1. 私有 AES 握手（小米手环 6 的强制步骤）
    final hex = authHexKey;
    if (hex != null && hex.isNotEmpty) {
      _setStage(MiBandStage.authenticating, message: '已连接，正在与手环完成安全握手…');
      try {
        await _runMiBand6Handshake(services, hex);
        _authenticated = true;
        debugPrint('MiBand6Auth: 🎉 private handshake unlocked.');
      } catch (e) {
        debugPrint('MiBand6Auth: private handshake failed -> $e');
        if (e.toString().contains('未找到小米手环鉴权特征值')) {
          _setStage(
            MiBandStage.awaitingBroadcast,
            message: '已连接设备，但未发现小米私有鉴权服务（FEE1/0009）。'
                '将尝试标准心率广播通道；如果无法接收心率，请在小米运动健康中开启「运动心率广播」。',
          );
        } else {
          _setStage(
            MiBandStage.authFailed,
            message:
                '安全握手失败：$e\n请检查 32 位 Hex Auth Key 是否与本只手环对应。',
          );
        }
        // 握手失败仍然继续尝试标准 HR 订阅，方便排查（必要时上层可读 isAuthenticated）
      }
    } else {
      debugPrint(
          'MiBand6Auth: 未配置 authHexKey，跳过私有握手；小米手环 6 在未解锁时收不到心率 notify。');
    }

    // 2. 标准 BLE 心率订阅
    BluetoothCharacteristic? hrChar;
    for (final s in services) {
      if (s.uuid.str.toLowerCase() == heartRateServiceUuid) {
        for (final c in s.characteristics) {
          if (c.uuid.str.toLowerCase() == heartRateCharUuid) {
            hrChar = c;
            break;
          }
        }
      }
      if (hrChar != null) break;
    }
    if (hrChar == null) {
      _setStage(
        MiBandStage.error,
        message: '未在该设备上找到心率特征值（180D / 2A37）。',
      );
      throw StateError('未在该设备上找到心率特征值（180D / 2A37）。');
    }

    _hrChar = hrChar;
    final subscribed = await _subscribeHeartRate();
    if (!subscribed) return;
    await _trySubscribeStress(services);
    _ensureUploadTimer();
    _armNoBroadcastTimer();
  }

  /// 订阅成功后开一个 15s 闹钟：到时还没收到任何 notify，
  /// 就转入 [MiBandStage.awaitingBroadcast]，提示用户去开「运动心率广播」。
  void _armNoBroadcastTimer() {
    _noBroadcastTimer?.cancel();
    _setStage(MiBandStage.hrSubscribed, message: '通道已就绪，等待手环推送心率…');
    _noBroadcastTimer = Timer(const Duration(seconds: 15), () {
      if (status.value.stage == MiBandStage.hrSubscribed) {
        _setStage(
          MiBandStage.awaitingBroadcast,
          message:
              '已连接但 15 秒内未收到心率。手环侧可能未开启「运动心率广播」。',
        );
      }
    });
  }

  // ──────────────────────────────────────────────────────────────
  // 自动重连
  // ──────────────────────────────────────────────────────────────

  void _onUnexpectedDisconnect() {
    if (_userInitiatedDisconnect) return;
    debugPrint('MiBand6Auth: device disconnected unexpectedly.');
    _streaming = false;
    _authenticated = false;
    _noBroadcastTimer?.cancel();
    _noBroadcastTimer = null;
    _stressPollTimer?.cancel();
    _stressPollTimer = null;
    unawaited(_hrSub?.cancel());
    _hrSub = null;
    unawaited(_stressSub?.cancel());
    _stressSub = null;
    unawaited(_authSub?.cancel());
    _authSub = null;
    _hrChar = null;
    _authChar = null;
    _stressChar = null;
    _setStage(
      MiBandStage.disconnected,
      message: '蓝牙连接已断开，将自动尝试重连…',
    );
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_userInitiatedDisconnect) return;
    if (_device == null) return;
    _reconnectTimer?.cancel();
    final idx = _reconnectAttempt.clamp(0, _reconnectBackoffSeconds.length - 1);
    final secs = _reconnectBackoffSeconds[idx];
    _reconnectAttempt++;
    debugPrint(
        'MiBand6Auth: schedule auto-reconnect in ${secs}s (attempt $_reconnectAttempt).');
    _reconnectTimer = Timer(Duration(seconds: secs), _attemptReconnect);
  }

  Future<void> _attemptReconnect() async {
    if (_userInitiatedDisconnect) return;
    final dev = _device;
    if (dev == null) return;
    debugPrint('MiBand6Auth: auto-reconnect attempt…');
    try {
      await startAuthentication(dev);
      // 进入 streaming 时由 _onNotify 重置退避计数
    } catch (e) {
      debugPrint('MiBand6Auth: auto-reconnect failed -> $e');
      if (!_userInitiatedDisconnect) {
        _scheduleReconnect();
      }
    }
  }

  void _debugDumpGattServices(List<BluetoothService> services) {
    debugPrint('MiBand6Auth: discovered ${services.length} GATT services:');
    for (final s in services) {
      debugPrint('  service ${s.uuid.str}');
      for (final c in s.characteristics) {
        debugPrint('    char ${c.uuid.str} props=${c.properties}');
      }
    }
  }

  // ──────────────────────────────────────────────────────────────
  // 小米手环 6 私有 AES-128 ECB 握手
  // ──────────────────────────────────────────────────────────────

  Future<void> _runMiBand6Handshake(
    List<BluetoothService> services,
    String hexKey,
  ) async {
    BluetoothCharacteristic? authChar;
    for (final s in services) {
      if (s.uuid.str.toLowerCase().contains(miAuthServiceShort)) {
        for (final c in s.characteristics) {
          final id = c.uuid.str.toLowerCase();
          // Match any 128-bit characteristic whose short ID is 00000009,
          // regardless of UUID base (different firmware variants).
          if (id.length >= 8 && id.substring(0, 8) == '00000009') {
            authChar = c;
            debugPrint('MiBand6Auth: found auth char at $id');
            break;
          }
        }
      }
      if (authChar != null) break;
    }
    if (authChar == null) {
      throw StateError('未找到小米手环鉴权特征值（FEE1 / 0009）。');
    }

    _authChar = authChar;
    await authChar.setNotifyValue(true);

    final completer = Completer<bool>();
    _authCompleter = completer;
    await _authSub?.cancel();
    _authSub = authChar.onValueReceived.listen(_handleAuthNotification);

    // step1：发送密钥注册请求 [0x01, 0x08, ...16 字节 key]
    final keyBytes = _hexToBytes(hexKey);
    final step1 = Uint8List.fromList(<int>[0x01, 0x08, ...keyBytes]);
    debugPrint('MiBand6Auth: send step1 (register key).');
    await authChar.write(step1, withoutResponse: false);

    final ok = await completer.future
        .timeout(authTimeout, onTimeout: () => false);

    await _authSub?.cancel();
    _authSub = null;
    _authCompleter = null;

    if (!ok) {
      throw StateError(
          '小米手环握手失败（超时或 Auth Key 不匹配，请检查 32 位 Hex Key）。');
    }
  }

  Future<void> _handleAuthNotification(List<int> data) async {
    if (data.isEmpty) return;
    debugPrint('MiBand6Auth: auth notify <- $data');
    final ch = _authChar;
    if (ch == null) return;

    // step2：手环已接收 key，要求生成 nonce -> 发送 [0x02, 0x08]
    if (data.length >= 3 &&
        data[0] == 0x10 &&
        data[1] == 0x01 &&
        data[2] == 0x01) {
      final cmd = Uint8List.fromList(<int>[0x02, 0x08]);
      debugPrint('MiBand6Auth: send step2 (request nonce).');
      try {
        await ch.write(cmd, withoutResponse: false);
      } catch (e) {
        _authCompleter?.complete(false);
      }
      return;
    }

    // step3：手环返回 16 字节 nonce -> AES 加密后回传 [0x03, 0x08, ...encrypted]
    if (data.length >= 19 &&
        data[0] == 0x10 &&
        data[1] == 0x02 &&
        data[2] == 0x01) {
      final nonce = Uint8List.fromList(data.sublist(3, 19));
      final encrypted = _encryptNonce(nonce);
      final cmd = Uint8List.fromList(<int>[0x03, 0x08, ...encrypted]);
      debugPrint('MiBand6Auth: send step3 (encrypted nonce).');
      try {
        await ch.write(cmd, withoutResponse: false);
      } catch (e) {
        _authCompleter?.complete(false);
      }
      return;
    }

    // 终判：[0x10, 0x03, 0x01] 解锁成功；[0x10, 0x03, 0x02] 失败
    if (data.length >= 3 && data[0] == 0x10 && data[1] == 0x03) {
      final ok = data[2] == 0x01;
      if (!(_authCompleter?.isCompleted ?? true)) {
        _authCompleter?.complete(ok);
      }
    }
  }

  Uint8List _encryptNonce(Uint8List nonce) {
    final key = enc.Key(_hexToBytes(authHexKey!));
    // 小米协议强制 AES-128 ECB / NoPadding
    final encrypter = enc.Encrypter(
      enc.AES(key, mode: enc.AESMode.ecb, padding: null),
    );
    return Uint8List.fromList(encrypter.encryptBytes(nonce).bytes);
  }

  Uint8List _hexToBytes(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  // ──────────────────────────────────────────────────────────────
  // 心率订阅与上报
  // ──────────────────────────────────────────────────────────────

  Future<bool> _subscribeHeartRate() async {
    final ch = _hrChar;
    if (ch == null) return false;
    try {
      await ch.setNotifyValue(true);
      await _hrSub?.cancel();
      _hrSub = ch.lastValueStream.listen(_onNotify);
      return true;
    } catch (e) {
      debugPrint('MiBand6Auth: subscribe heart rate failed -> $e');
      final msg = e.toString();
      if (msg.contains('GATT_WRITE_NOT_PERMITTED') ||
          msg.contains('android-code: 3')) {
        _setStage(
          MiBandStage.awaitingBroadcast,
          message: '已连接到手环，但系统拒绝开启心率 notify（GATT_WRITE_NOT_PERMITTED）。'
              '请在小米运动健康中开启「运动心率广播」后重试。',
        );
      } else {
        _setStage(MiBandStage.error, message: '订阅心率失败：$e');
      }
      return false;
    }
  }

  Future<void> _trySubscribeStress(List<BluetoothService> services) async {
    // 1. Gather candidate UUIDs (explicit + auto-detected FEE1 base)
    final candidates = <String>{};
    if (stressCharacteristicUuids.isNotEmpty) {
      candidates.addAll(stressCharacteristicUuids.map((e) => e.toLowerCase()));
    }

    // Auto-detect the FEE1 service UUID base used by this particular device.
    // Different Mi Band 6 firmware / Zepp Life versions use different bases:
    //   - 0000-1000-8000-00805f9b34fb (classic)
    //   - 0000-3512-2118-0009af100700 (newer)
    String? detectedFee1Base;
    for (final s in services) {
      if (s.uuid.str.toLowerCase().contains('fee1')) {
        for (final c in s.characteristics) {
          final id = c.uuid.str.toLowerCase();
          // 128-bit FEE1 characteristic e.g. 00000012-0000-3512-2118-0009af100700
          if (id.length >= 36 && id[8] == '-') {
            detectedFee1Base = id.substring(8); // "-0000-3512-2118-0009af100700"
            break;
          }
        }
      }
      if (detectedFee1Base != null) break;
    }

    final fee1Base = detectedFee1Base ?? '-0000-1000-8000-00805f9b34fb';
    debugPrint('MiBand6Auth: using FEE1 base $fee1Base');

    // Known Huami stress / wellness characteristic short IDs under FEE1
    const knownStressShorts = [
      '0000000d', '0000000e', '0000000f',
      '00000011', '00000012', '00000013', '00000020',
    ];
    for (final s in knownStressShorts) {
      candidates.add('$s$fee1Base');
    }
    // Standard stress measurement UUID
    candidates.add('00002a59-0000-1000-8000-00805f9b34fb');

    // 2. Exact-match search across GATT
    BluetoothCharacteristic? stressChar;
    for (final s in services) {
      for (final c in s.characteristics) {
        final id = c.uuid.str.toLowerCase();
        if (candidates.contains(id) &&
            (c.properties.read ||
                c.properties.notify ||
                c.properties.indicate)) {
          stressChar = c;
          break;
        }
      }
      if (stressChar != null) break;
    }

    // 3. Fallback: auto-discover — read every readable characteristic that
    //    is NOT a known infra/HR/auth char, dump raw bytes, and pick the
    //    first one whose payload parses as a plausible stress value.
    if (stressChar == null) {
      debugPrint(
          'MiBand6Auth: no known stress UUID matched; running auto-discovery…');
      stressChar = await _autoDiscoverStressChar(services, null);
    }

    if (stressChar == null) {
      debugPrint(
          'MiBand6Auth: no stress characteristic found (manual or auto).');
      return;
    }

    await _startStressPolling(stressChar);
  }

  Future<void> _startStressPolling(BluetoothCharacteristic stressChar) async {
    _stressChar = stressChar;
    await _stressSub?.cancel();
    _stressPollTimer?.cancel();
    _lastStressRaw = null;
    _stressStaleCount = 0;
    try {
      if (stressChar.properties.notify || stressChar.properties.indicate) {
        await stressChar.setNotifyValue(true);
        _stressSub = stressChar.lastValueStream.listen(_onStressNotify);
      }
      if (stressChar.properties.read) {
        final value = await stressChar.read();
        _onStressNotify(value);
      }
      _stressPollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        try {
          final ch = _stressChar;
          if (ch == null) return;
          final value = await ch.read();
          _onStressNotify(value);
        } catch (e) {
          debugPrint('MiBand6Auth: stress poll error -> $e');
        }
      });
      debugPrint('MiBand6Auth: stress characteristic subscribed/read: '
          '${stressChar.uuid.str}');
    } catch (e) {
      debugPrint('MiBand6Auth: subscribe/read stress failed -> $e');
    }
  }

  /// Fallback: iterate every characteristic with [read] property that is not
  /// a well-known housekeeping UUID, try a single read, and accept the first
  /// one whose payload looks like a stress value (0-100).
  ///
  /// [skipUntil] is used after a stale-char reset to continue probing from
  /// the characteristic *after* the one that previously produced false matches.
  Future<BluetoothCharacteristic?> _autoDiscoverStressChar(
      List<BluetoothService> services,
      String? skipUntil) async {
    // Service-level UUIDs we should never probe.
    const skipServices = <String>{
      '1800', '1801', '180a', '180f', // generic access, device info, battery
      '1802',  // Immediate Alert
      '180d',  // Heart Rate — already handled
      '1811',  // Alert Notification Service — 2a46 is New Alert, not stress
      '1812',  // Human Interface Device
    };
    // Characteristic-level UUIDs we should never probe for stress data.
    const skipChars = <String>{
      '2a00', '2a01', '2a04', '2a05', '2a06', '2a19',
      '2a22', '2a23', '2a24', '2a25', '2a26',
      '2a27', '2a28', '2a29', '2a32',
      '2a37', '2a39', '2a44', '2a46', '2a4a', '2a4b', '2a4c', '2a4d', '2a4e',
      '2a50',
      '2902', // CCCD descriptor
    };

    bool skipService(String uuid) {
      final id = uuid.toLowerCase();
      return skipServices.contains(id);
    }

    bool skipChar(String uuid) {
      final id = uuid.toLowerCase();
      if (skipChars.contains(id)) return true;
      // Skip auth characteristic regardless of UUID base
      // (00000009-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
      if (id.length >= 8 && id.substring(0, 8) == '00000009') return true;
      // Skip FEDx vendor-specific housekeeping chars
      if (id == 'fedd' || id == 'fede' || id == 'fedf' ||
          id == 'fed0' || id == 'fed1' || id == 'fed2' || id == 'fed3') {
        return true;
      }
      // Skip the 0xfec1 proprietary characteristic
      if (id.length >= 42 && id.substring(0, 36) == '0000fec1-0000-3512-2118-0009af100700') {
        return true;
      }
      return false;
    }

    bool passedSkipUntil = skipUntil == null;

    for (final s in services) {
      if (skipService(s.uuid.str)) continue;
      for (final c in s.characteristics) {
        if (!c.properties.read) continue;
        if (skipChar(c.uuid.str)) continue;

        final id = c.uuid.str;
        if (!passedSkipUntil) {
          if (id == skipUntil) passedSkipUntil = true;
          continue;
        }

        try {
          final raw = await c.read();
          debugPrint(
              'MiBand6Auth: auto-probe char $id raw=${_hexDump(raw)}');
          final parsed = _parseStressValue(raw);
          if (parsed != null) {
            debugPrint(
                'MiBand6Auth: auto-discovery picked $id → stress=$parsed');
            return c;
          }
        } catch (e) {
          debugPrint(
              'MiBand6Auth: auto-probe read error for $id: $e');
        }
      }
    }
    return null;
  }

  String _hexDump(List<int> bytes) {
    return bytes.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ');
  }

  Future<void> _onStressNotify(List<int> value) async {
    if (value.isEmpty) return;
    final stress = _parseStressValue(value);
    if (stress == null) {
      debugPrint('MiBand6Auth: ignored unknown stress payload: $value');
      return;
    }

    // Staleness guard: if the identical value repeats for 12 consecutive
    // polls (60 s at the 5 s interval), the characteristic we latched onto
    // is almost certainly a static register, not a real stress sensor.
    // Try the next auto-discovery candidate instead of giving up entirely.
    if (stress == _lastStressRaw) {
      _stressStaleCount++;
      if (_stressStaleCount >= 12) {
        final staleId = _stressChar?.uuid.str ?? 'unknown';
        debugPrint(
            'MiBand6Auth: stress value stuck at $stress for 60 s, '
            'char $staleId is stale; re-running auto-discovery past it.');
        _stressPollTimer?.cancel();
        _stressPollTimer = null;
        await _stressSub?.cancel();
        _stressSub = null;
        _stressChar = null;
        _lastStressRaw = null;
        _stressStaleCount = 0;

        // Retry auto-discovery, skipping the char that gave us the stale value
        if (_device != null) {
          try {
            final services = await _device!.discoverServices();
            final next = await _autoDiscoverStressChar(services, staleId);
            if (next != null) {
              await _startStressPolling(next);
            } else {
              debugPrint('MiBand6Auth: no further stress candidate found after stale reset.');
            }
          } catch (e) {
            debugPrint('MiBand6Auth: stale-recovery discover error -> $e');
          }
        }
        return;
      }
    } else {
      _stressStaleCount = 0;
    }
    _lastStressRaw = stress;

    if (!_stressController.isClosed) {
      _stressController.add(BandStressSample(
        value: stress,
        timestamp: DateTime.now(),
      ));
    }
  }

  int? _parseStressValue(List<int> value) {
    if (value.isEmpty) return null;

    // Case 1: single byte 0-100 (simplest firmware)
    if (value.length == 1 && value.first >= 0 && value.first <= 100) {
      return value.first;
    }

    // Case 2: [0x00/0x01 flag, value] — basic Huami stress packet
    if (value.length == 2 &&
        (value[0] == 0x00 || value[0] == 0x01) &&
        value[1] >= 0 &&
        value[1] <= 100) {
      return value[1];
    }

    // Huami stress protocol headers seen in the wild
    const knownHeaders = <int>{0x00, 0x01, 0x02, 0x03, 0x10};

    // Case 3: [header, value, ...padding] — value at position 1 behind a known header
    if (value.length >= 2 &&
        value.length <= 20 &&
        knownHeaders.contains(value[0]) &&
        value[1] >= 0 &&
        value[1] <= 100) {
      final rest = value.sublist(2);
      if (rest.every((b) => b == 0x00)) return value[1];
      if (value.length <= 4) return value[1];
    }

    // Case 4: last byte 0-100 in a short packet (≤4 bytes), with a plausible header
    if (value.length <= 4 &&
        knownHeaders.contains(value[0]) &&
        value.last >= 0 &&
        value.last <= 100) {
      return value.last;
    }

    return null;
  }

  void _onNotify(List<int> value) {
    if (value.isEmpty) return;
    final flag = value[0];
    int bpm = 0;
    if ((flag & 0x01) == 0) {
      // 8-bit BPM
      if (value.length >= 2) bpm = value[1];
    } else {
      // 16-bit BPM
      if (value.length >= 3) bpm = (value[2] << 8) + value[1];
    }
    if (bpm <= 0) return;
    final now = DateTime.now();
    final sample = HeartRateSample(
      bpm: bpm,
      timestamp: now,
      isAlert: bpm > localAlertBpm,
    );
    _buffer.add(sample);
    if (!_hrController.isClosed) _hrController.add(sample);
    _noBroadcastTimer?.cancel();
    _noBroadcastTimer = null;
    _streaming = true;
    if (status.value.stage != MiBandStage.streaming) {
      _reconnectAttempt = 0;
      status.value = MiBandStatus(
        MiBandStage.streaming,
        message: '手环已开始推送心率',
        lastSampleAt: now,
      );
    } else {
      status.value = MiBandStatus(
        MiBandStage.streaming,
        message: status.value.message,
        lastSampleAt: now,
      );
    }
  }

  void _ensureUploadTimer() {
    _uploadTimer?.cancel();
    _uploadTimer = Timer.periodic(uploadInterval, (_) => _flushBuffer());
  }

  Future<void> _flushBuffer() async {
    if (_buffer.isEmpty) return;
    final cloud = cloudService;
    if (cloud == null) return;
    final chunk = List<HeartRateSample>.from(_buffer);
    _buffer.clear();
    final ok = await cloud.uploadHeartRateBatch(chunk);
    if (!ok) {
      // 失败回滚（保留顺序），等下一周期再试
      _buffer.insertAll(0, chunk);
    }
  }

  bool _looksLikeMiBand(BluetoothDevice d) {
    final name = d.platformName;
    final id = d.remoteId.str.toUpperCase();
    return name.contains(deviceNameKeyword) || id.contains(remoteIdKeyword);
  }

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  /// 仅断开手环连接、清空采样队列，但保留 Stream / status，
  /// 方便外层在用户点击「重试连接」后立刻重跑 bootstrap。
  Future<void> disconnect({bool keepStatus = false}) async {
    _userInitiatedDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    _uploadTimer?.cancel();
    _uploadTimer = null;
    _noBroadcastTimer?.cancel();
    _noBroadcastTimer = null;
    _stressPollTimer?.cancel();
    _stressPollTimer = null;
    await _hrSub?.cancel();
    _hrSub = null;
    await _stressSub?.cancel();
    _stressSub = null;
    await _authSub?.cancel();
    _authSub = null;
    await _connStateSub?.cancel();
    _connStateSub = null;
    _hrChar = null;
    _authChar = null;
    _stressChar = null;
    _authCompleter = null;
    final d = _device;
    if (d != null) {
      try {
        if (d.isConnected) await d.disconnect();
      } catch (_) {}
    }
    _device = null;
    _streaming = false;
    _authenticated = false;
    _buffer.clear();
    if (!keepStatus) {
      _setStage(MiBandStage.disconnected, message: '已断开手环连接');
    }
  }

  /// 释放资源：停采、断开蓝牙、关闭 Stream。
  Future<void> dispose() async {
    await disconnect(keepStatus: true);
    if (!_hrController.isClosed) await _hrController.close();
    if (!_stressController.isClosed) await _stressController.close();
    status.dispose();
  }
}
