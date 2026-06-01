import 'dart:async';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/band_stress_data.dart';
import '../models/heart_rate_data.dart';
import 'cloud_service.dart';
import 'huami2021_protocol.dart';

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

  /// 标准 Immediate Alert Service / Alert Level，用于触发手环短震。
  static const String immediateAlertServiceUuid = '1802';
  static const String alertLevelCharUuid = '2a06';

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
  BluetoothCharacteristic? _alertChar;
  BluetoothCharacteristic? _chunkedV3WriteChar;
  BluetoothCharacteristic? _chunkedV3ReadChar;
  int _chunkedV3Seq = 0;
  BluetoothCharacteristic? _stressChar;
  StreamSubscription<List<int>>? _hrSub;
  StreamSubscription<List<int>>? _stressSub;
  StreamSubscription<List<int>>? _huami2021Sub;
  Timer? _stressPollTimer;
  int? _lastStressRaw;
  int _stressStaleCount = 0;

  /// 上次自动告警震动的时间，防抖用（同一轮高 BPM 不会频繁震动）。
  DateTime? _lastAutoVibrationAt;

  // ── 鉴权用 ──
  BluetoothCharacteristic? _authChar;
  StreamSubscription<List<int>>? _authSub;
  Completer<bool>? _authCompleter;
  Completer<Huami2021Payload>? _huami2021PayloadCompleter;
  int? _huami2021ExpectedEndpoint;
  Huami2021Crypto? _huami2021Crypto;
  Huami2021Decoder? _huami2021Decoder;
  bool _authWriteWithoutResponse = false;

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
  bool _heartRateReceptionPaused = false;

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
          message: '还没有发现小米手环 6，请确认手环靠近手机、电量充足，且没有被其他应用占用。',
        );
      }
      return found;
    } catch (e) {
      debugPrint('MiBand6Auth: scan error $e');
      _setStage(MiBandStage.error, message: '搜索手环时出了点问题，请稍后再试。');
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
        _setStage(MiBandStage.error, message: '这次没能连上手环，请靠近后重试。');
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
        if (_hasHuami2021ChunkedPair(services)) {
          await _runHuami2021Handshake(services, hex);
        } else {
          await _runMiBand6Handshake(services, hex);
        }
        _authenticated = true;
        debugPrint('MiBand6Auth: 🎉 private handshake unlocked.');
      } catch (e) {
        debugPrint('MiBand6Auth: primary private handshake failed -> $e');
        if (_hasHuami2021ChunkedPair(services)) {
          _setStage(
              MiBandStage.authenticating, message: '新协议握手失败，正在尝试旧式校验…');
        }
        try {
          await _runMiBand6Handshake(services, hex);
          _authenticated = true;
          debugPrint('MiBand6Auth: 🎉 legacy private handshake unlocked.');
        } catch (legacyError) {
          debugPrint('MiBand6Auth: private handshake failed -> $legacyError');
          if (legacyError.toString().contains('未找到')) {
            _setStage(
              MiBandStage.awaitingBroadcast,
              message: '已经连上手环，但还不能直接接收心率。'
                  '我们会继续尝试；如果仍没有心率，请在小米运动健康中开启「运动心率广播」。',
            );
          } else {
            _setStage(
              MiBandStage.authFailed,
              message: '这只手环暂时无法完成连接校验，请确认当前连接的是已绑定的那只手环。',
            );
          }
        }
        // 握手失败仍然继续尝试标准 HR 订阅，方便排查（必要时上层可读 isAuthenticated）
      }
    } else {
      debugPrint(
          'MiBand6Auth: 未配置 authHexKey，跳过私有握手；小米手环 6 在未解锁时收不到心率 notify。');
    }

    // 2. 标准 BLE 心率订阅
    BluetoothCharacteristic? hrChar;
    BluetoothCharacteristic? alertChar;
    for (final s in services) {
      if (_uuidMatches(s.uuid.str, immediateAlertServiceUuid)) {
        for (final c in s.characteristics) {
          if (_uuidMatches(c.uuid.str, alertLevelCharUuid)) {
            alertChar = c;
            break;
          }
        }
      }
      if (_uuidMatches(s.uuid.str, heartRateServiceUuid)) {
        for (final c in s.characteristics) {
          if (_uuidMatches(c.uuid.str, heartRateCharUuid)) {
            hrChar = c;
            break;
          }
        }
      }
      if (hrChar != null && alertChar != null) break;
    }
    if (hrChar == null) {
      _setStage(
        MiBandStage.error,
        message: '这只设备暂时没有提供可用的心率通道。',
      );
      throw StateError('这只设备暂时没有提供可用的心率通道。');
    }

    _hrChar = hrChar;
    _alertChar = alertChar;
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

  /// 上层（ESP 配网页等）在做关键 BLE 操作时调用，避免自动重连定时器在
  /// 5–60 s 后强行连米带，把 Android host 栈逼到顶不住两条 GATT，
  /// 进而把 ESP32 那条 link 用 LINK_SUPERVISION_TIMEOUT 掐掉。
  bool _autoReconnectPaused = false;
  void pauseAutoReconnect() {
    _autoReconnectPaused = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    debugPrint('MiBand6Auth: auto-reconnect paused.');
  }

  /// 恢复自动重连：如果之前掉过线（_device 非空且不是用户主动断开），
  /// 立刻安排一次最短退避的重连尝试。
  void resumeAutoReconnect() {
    if (!_autoReconnectPaused) return;
    _autoReconnectPaused = false;
    debugPrint('MiBand6Auth: auto-reconnect resumed.');
    if (_userInitiatedDisconnect) return;
    if (_device == null) return;
    if (_streaming) return;
    _scheduleReconnect();
  }

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
    unawaited(_huami2021Sub?.cancel());
    _huami2021Sub = null;
    _hrChar = null;
    _alertChar = null;
    _chunkedV3WriteChar = null;
    _chunkedV3ReadChar = null;
    _chunkedV3Seq = 0;
    _authChar = null;
    _huami2021PayloadCompleter = null;
    _huami2021ExpectedEndpoint = null;
    _huami2021Crypto = null;
    _huami2021Decoder = null;
    _authWriteWithoutResponse = false;
    _stressChar = null;
    _setStage(
      MiBandStage.disconnected,
      message: '蓝牙连接已断开，将自动尝试重连…',
    );
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_userInitiatedDisconnect) return;
    if (_autoReconnectPaused) {
      debugPrint('MiBand6Auth: reconnect skipped (paused for ESP provisioning).');
      return;
    }
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
    if (_autoReconnectPaused) return;
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
  // 小米手环 6 / Huami 2021 新式 chunked-v3 握手
  // ──────────────────────────────────────────────────────────────

  bool _hasHuami2021ChunkedPair(List<BluetoothService> services) {
    BluetoothCharacteristic? writeChar;
    BluetoothCharacteristic? readChar;
    for (final s in services) {
      for (final c in s.characteristics) {
        final id = c.uuid.str.toLowerCase();
        if (id.startsWith('00000016-') &&
            (c.properties.write || c.properties.writeWithoutResponse)) {
          writeChar = c;
        }
        if (id.startsWith('00000017-') &&
            (c.properties.notify || c.properties.indicate)) {
          readChar = c;
        }
      }
    }
    return writeChar != null && readChar != null;
  }

  Future<void> _runHuami2021Handshake(
    List<BluetoothService> services,
    String hexKey,
  ) async {
    final writeChar = await _ensureChunkedV3WriteChar(services: services);
    final readChar = await _ensureChunkedV3ReadChar(services: services);
    if (writeChar == null || readChar == null) {
      throw StateError('未找到 Huami 2021 新协议通道（0x0016/0x0017）。');
    }

    final crypto = Huami2021Crypto(authKey: _hexToBytes(hexKey));
    crypto.start();
    final decoder = Huami2021Decoder();
    _huami2021Crypto = crypto;
    _huami2021Decoder = decoder;
    await _huami2021Sub?.cancel();
    await readChar.setNotifyValue(true);
    _huami2021Sub = readChar.onValueReceived.listen((data) {
      unawaited(_handleHuami2021Notification(data));
    });

    debugPrint('MiBand6Auth: Huami2021 send auth public key.');
    await _writeHuami2021Chunks(
      endpoint: 0x0082,
      payload: crypto.buildAuthHello(),
      encrypted: false,
    );

    final remoteKey = await _waitHuami2021Payload(0x0082, authTimeout);
    final sessionCommand = crypto.handleRemoteKey(remoteKey.payload);
    debugPrint('MiBand6Auth: Huami2021 send double encrypted random.');
    await _writeHuami2021Chunks(
      endpoint: 0x0082,
      payload: sessionCommand,
      encrypted: false,
    );

    final sessionResult = await _waitHuami2021Payload(0x0082, authTimeout);
    final p = sessionResult.payload;
    if (p.length >= 3 && p[0] == 0x10 && p[1] == 0x05 && p[2] == 0x01) {
      debugPrint('MiBand6Auth: Huami2021 auth success.');
      return;
    }
    if (p.length >= 3 && p[0] == 0x10 && p[1] == 0x05 && p[2] == 0x25) {
      throw StateError('Huami2021 鉴权失败：Auth Key 不匹配。');
    }
    throw StateError('Huami2021 鉴权返回未知响应：$p');
  }

  Future<void> _handleHuami2021Notification(List<int> data) async {
    if (data.isEmpty) return;
    debugPrint('MiBand6Auth: Huami2021 notify <- ${_hexDump(data)}');
    if (data[0] == 0x04) {
      debugPrint('MiBand6Auth: Huami2021 ack <- ${_hexDump(data)}');
      return;
    }
    final decoder = _huami2021Decoder;
    final crypto = _huami2021Crypto;
    if (decoder == null || crypto == null) return;
    final needsAck = decoder.needsAck(data);
    final payload = decoder.decode(data, crypto: crypto, extendedFlags: true);
    if (needsAck) {
      await _sendHuami2021Ack(decoder.lastHandle, decoder.lastCount);
    }
    if (payload == null) return;
    debugPrint('MiBand6Auth: Huami2021 payload endpoint='
        '0x${payload.endpoint.toRadixString(16).padLeft(4, '0')} '
        'data=${_hexDump(payload.payload)}');
    final completer = _huami2021PayloadCompleter;
    final expectedEndpoint = _huami2021ExpectedEndpoint;
    if (completer != null &&
        !completer.isCompleted &&
        (expectedEndpoint == null || payload.endpoint == expectedEndpoint)) {
      completer.complete(payload);
    }
  }

  Future<Huami2021Payload> _waitHuami2021Payload(
      int endpoint, Duration timeout) async {
    final completer = Completer<Huami2021Payload>();
    _huami2021PayloadCompleter = completer;
    _huami2021ExpectedEndpoint = endpoint;
    try {
      return await completer.future.timeout(timeout);
    } finally {
      if (_huami2021PayloadCompleter == completer) {
        _huami2021PayloadCompleter = null;
        _huami2021ExpectedEndpoint = null;
      }
    }
  }

  Future<void> _writeHuami2021Chunks({
    required int endpoint,
    required List<int> payload,
    required bool encrypted,
  }) async {
    final ch = await _ensureChunkedV3WriteChar();
    final crypto = _huami2021Crypto;
    if (ch == null || crypto == null) {
      throw StateError('Huami2021 write channel is not ready.');
    }
    final chunks = crypto.encode(
      endpoint: endpoint,
      payload: payload,
      encrypted: encrypted,
      extendedFlags: true,
      mtu: 247,
    );
    final noResp = ch.properties.writeWithoutResponse;
    for (final chunk in chunks) {
      debugPrint('MiBand6Auth: Huami2021 write -> ${_hexDump(chunk)}');
      await ch.write(chunk, withoutResponse: noResp);
    }
  }

  Future<void> _sendHuami2021Ack(int handle, int count) async {
    final readChar = await _ensureChunkedV3ReadChar();
    if (readChar == null) return;
    final ack = <int>[0x04, 0x00, handle & 0xff, 0x01, count & 0xff];
    debugPrint('MiBand6Auth: Huami2021 ack -> ${_hexDump(ack)}');
    await readChar.write(
      ack,
      withoutResponse: readChar.properties.writeWithoutResponse,
    );
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
      throw StateError('未找到可用的手环校验通道。');
    }

    _authChar = authChar;
    await authChar.setNotifyValue(true);

    // 根据特征属性自适应写入模式：部分固件仅支持 writeWithoutResponse
    _authWriteWithoutResponse =
        authChar.properties.writeWithoutResponse && !authChar.properties.write;
    debugPrint(
        'MiBand6Auth: auth char write mode: ${_authWriteWithoutResponse ? "writeWithoutResponse" : "writeWithResponse"}');

    final completer = Completer<bool>();
    _authCompleter = completer;
    await _authSub?.cancel();
    _authSub = authChar.onValueReceived.listen(_handleAuthNotification);

    // step1：发送密钥注册请求 [0x01, 0x08, ...16 字节 key]
    final keyBytes = _hexToBytes(hexKey);
    final step1 = Uint8List.fromList(<int>[0x01, 0x08, ...keyBytes]);
    debugPrint('MiBand6Auth: send step1 (register key).');
    await authChar.write(step1, withoutResponse: _authWriteWithoutResponse);

    final ok = await completer.future
        .timeout(authTimeout, onTimeout: () => false);

    await _authSub?.cancel();
    _authSub = null;
    _authCompleter = null;

    if (!ok) {
      throw StateError('小米手环连接校验未通过，请稍后重试。');
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
        await ch.write(cmd, withoutResponse: _authWriteWithoutResponse);
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
        await ch.write(cmd, withoutResponse: _authWriteWithoutResponse);
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
      _heartRateReceptionPaused = false;
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
          message: '已经连上手环，但手机暂时不能接收心率。'
              '请在小米运动健康中开启「运动心率广播」后重试。',
        );
      } else {
        _setStage(MiBandStage.error, message: '开始接收心率时出了点问题，请稍后再试。');
      }
      return false;
    }
  }

  /// 暂停接收心率 notify，用于 BLE 测试流程中避免心率 UI/云端上报干扰。
  Future<bool> pauseHeartRateReceptionForTest() async {
    final ch = _hrChar;
    if (ch == null) return false;
    _heartRateReceptionPaused = true;
    _noBroadcastTimer?.cancel();
    _noBroadcastTimer = null;
    await _hrSub?.cancel();
    _hrSub = null;
    try {
      await ch.setNotifyValue(false);
    } catch (e) {
      debugPrint('MiBand6Auth: pause HR notify failed -> $e');
    }
    _streaming = false;
    _setStage(MiBandStage.hrSubscribed, message: '已暂停接收心率，正在进行手环测试…');
    return true;
  }

  /// 恢复心率 notify 与上传定时器。
  Future<bool> resumeHeartRateReceptionAfterTest() async {
    final ok = await _subscribeHeartRate();
    if (!ok) return false;
    _ensureUploadTimer();
    _armNoBroadcastTimer();
    return true;
  }

  /// 触发"查找设备"震动若干次。
  ///
  /// 优先走 Huami chunked-v3（端点 `0x000d`，负载 `[0x03,0x01]` / `[0x03,0x00]`），
  /// 与小米运动健康「查找手环」一致。
  ///
  /// 不少 Mi Band 6 / 6 NFC 固件对 `0x000d` 写入成功但不震动；同时对
  /// **标准 Immediate Alert（1802/2A06）** 的 `0x02` 也会「假成功」。
  /// 社区逆向里 **`0x04`（振动、无 LED）** 在部分批次仍可触发马达，因此
  /// 每次开/关震动都会 **双发**：先 `_pulseImmediateAlertLevel`，再 chunked。
  Future<bool> vibrateBandForTest({
    int times = 3,
    Duration on = const Duration(milliseconds: 650),
    Duration off = const Duration(milliseconds: 350),
    @Deprecated('No longer used; kept for source compat.') int command = 0x04,
  }) async {
    final ch = await _ensureChunkedV3WriteChar();
    if (ch == null) {
      debugPrint(
          'MiBand6Auth: chunked-v3 write char (0x0016) not found, '
          'falling back to standard Immediate Alert.');
      return _legacyImmediateAlertVibrate(times: times, on: on, off: off);
    }

    bool anyOk = false;
    try {
      for (var i = 0; i < times; i++) {
        final startOk = await _writeFindDevice(ch, true);
        if (startOk) anyOk = true;
        await Future<void>.delayed(on);
        await _writeFindDevice(ch, false);
        if (i < times - 1) {
          await Future<void>.delayed(off);
        }
      }
      return anyOk;
    } catch (e) {
      debugPrint('MiBand6Auth: find-device vibration failed -> $e');
      return anyOk;
    } finally {
      try {
        await _writeFindDevice(ch, false);
      } catch (_) {}
    }
  }

  /// 一次性"查找设备"：开 → 等 [duration] → 关。返回是否成功写入。
  Future<bool> findBandLikeMiFit({
    Duration duration = const Duration(seconds: 5),
  }) async {
    final ch = await _ensureChunkedV3WriteChar();
    if (ch == null) {
      debugPrint('MiBand6Auth: chunked-v3 write char not found.');
      return false;
    }
    final startOk = await _writeFindDevice(ch, true);
    if (!startOk) return false;
    await Future<void>.delayed(duration);
    await _writeFindDevice(ch, false);
    return true;
  }

  /// 写蓝牙标准 Alert Level（2A06）。`0x04` 为小米系非扩展值，部分固件上比 `0x02` 更能真正触发马达。
  Future<bool> _pulseImmediateAlertLevel(bool start) async {
    final ch = _alertChar ?? await _ensureAlertCharacteristic();
    if (ch == null) return false;
    final noResp =
        ch.properties.writeWithoutResponse && !ch.properties.write;
    try {
      if (start) {
        try {
          await ch.write(<int>[0x04], withoutResponse: noResp);
        } catch (e) {
          debugPrint('MiBand6Auth: alert 0x04 failed, trying 0x02 -> $e');
          await ch.write(<int>[0x02], withoutResponse: noResp);
        }
      } else {
        await ch.write(<int>[0x00], withoutResponse: noResp);
      }
      return true;
    } catch (e) {
      debugPrint('MiBand6Auth: immediate alert write failed -> $e');
      return false;
    }
  }

  Future<bool> _writeFindDevice(
      BluetoothCharacteristic ch, bool start) async {
    // Huami chunked-v3 endpoint 0x000d (FIND_DEVICE):
    //   payload[0] = 0x03 (subtype: vibration)
    //   payload[1] = 0x01 / 0x00 (start / stop)
    final pulseOk = await _pulseImmediateAlertLevel(start);
    final payload = <int>[0x03, start ? 0x01 : 0x00];
    try {
      final crypto = _huami2021Crypto;
      if (_authenticated && crypto != null && crypto.isReady) {
        await _writeHuami2021Chunks(
          endpoint: 0x000d,
          payload: payload,
          encrypted: true,
        );
      } else {
        final pkt = _buildChunkedV3Packet(
          endpoint: 0x000d,
          payload: payload,
        );
        await ch.write(pkt, withoutResponse: ch.properties.writeWithoutResponse);
      }
      return true;
    } catch (e) {
      debugPrint('MiBand6Auth: chunked-v3 write failed -> $e');
      return pulseOk;
    }
  }

  /// 单包 chunked-v3 数据包（payload <= MTU - 9）。
  ///
  /// 字节布局（参考 Gadgetbridge `Huami2021ChunkedHandler`）：
  ///   [0]    0x03                 ── 协议魔数
  ///   [1]    flags                ── bit0=encrypted, bit1=needs_ack 等
  ///   [2]    seq                  ── App 端递增序号
  ///   [3]    count = 0x01         ── 总分片数
  ///   [4]    index = 0x00         ── 当前分片索引
  ///   [5..6] length (LE)          ── payload 长度
  ///   [7..8] endpoint (LE)        ── 业务端点
  ///   [9..]  payload              ── 业务数据
  List<int> _buildChunkedV3Packet({
    required int endpoint,
    required List<int> payload,
    bool encrypted = false,
  }) {
    final flags = encrypted ? 0x01 : 0x00;
    final seq = _chunkedV3Seq;
    _chunkedV3Seq = (_chunkedV3Seq + 1) & 0xff;
    final length = payload.length;
    return <int>[
      0x03,
      flags,
      seq,
      0x01,
      0x00,
      length & 0xff,
      (length >> 8) & 0xff,
      endpoint & 0xff,
      (endpoint >> 8) & 0xff,
      ...payload,
    ];
  }

  Future<BluetoothCharacteristic?> _ensureChunkedV3WriteChar({
    List<BluetoothService>? services,
  }) async {
    final existing = _chunkedV3WriteChar;
    if (existing != null) return existing;
    final dev = _device;
    if (dev == null || !dev.isConnected) return null;
    final discovered = services ?? await dev.discoverServices();

    // Mi Band 6 / 6 NFC: chunked-v3 write char (`00000016-…`) 挂在 FEE0
    // 而不是 FEE1，所以这里不限定 service，直接按 char UUID 全局搜。
    BluetoothCharacteristic? candidate;
    for (final s in discovered) {
      for (final c in s.characteristics) {
        final id = c.uuid.str.toLowerCase();
        if (id.startsWith('00000016-') &&
            (c.properties.write || c.properties.writeWithoutResponse)) {
          candidate = c;
          debugPrint(
              'MiBand6Auth: chunked-v3 write char located: '
              '${c.uuid.str} under service ${s.uuid.str}');
          break;
        }
      }
      if (candidate != null) break;
    }
    _chunkedV3WriteChar = candidate;
    return candidate;
  }

  Future<BluetoothCharacteristic?> _ensureChunkedV3ReadChar({
    List<BluetoothService>? services,
  }) async {
    final existing = _chunkedV3ReadChar;
    if (existing != null) return existing;
    final dev = _device;
    if (dev == null || !dev.isConnected) return null;
    final discovered = services ?? await dev.discoverServices();

    BluetoothCharacteristic? candidate;
    for (final s in discovered) {
      for (final c in s.characteristics) {
        final id = c.uuid.str.toLowerCase();
        if (id.startsWith('00000017-') &&
            (c.properties.notify || c.properties.indicate)) {
          candidate = c;
          debugPrint(
              'MiBand6Auth: chunked-v3 read char located: '
              '${c.uuid.str} under service ${s.uuid.str}');
          break;
        }
      }
      if (candidate != null) break;
    }
    _chunkedV3ReadChar = candidate;
    return candidate;
  }

  /// 老路径兜底：写 1802/2A06。优先 `0x04`（部分新固件上仍能真震动），失败再试 `0x02`。
  /// 若设备没有 FEE0/0x0016，仅靠此路径。
  Future<bool> _legacyImmediateAlertVibrate({
    required int times,
    required Duration on,
    required Duration off,
  }) async {
    final ch = await _ensureAlertCharacteristic();
    if (ch == null) return false;
    final noResp = ch.properties.writeWithoutResponse && !ch.properties.write;
    try {
      for (var i = 0; i < times; i++) {
        try {
          await ch.write(<int>[0x04], withoutResponse: noResp);
        } catch (e) {
          debugPrint('MiBand6Auth: legacy alert 0x04 failed, trying 0x02 -> $e');
          await ch.write(<int>[0x02], withoutResponse: noResp);
        }
        await Future<void>.delayed(on);
        await ch.write(<int>[0x00], withoutResponse: noResp);
        if (i < times - 1) {
          await Future<void>.delayed(off);
        }
      }
      return true;
    } catch (e) {
      debugPrint('MiBand6Auth: legacy 1802 vibration failed -> $e');
      return false;
    } finally {
      try {
        await ch.write(<int>[0x00], withoutResponse: noResp);
      } catch (_) {}
    }
  }

  Future<BluetoothCharacteristic?> _ensureAlertCharacteristic() async {
    final existing = _alertChar;
    if (existing != null) return existing;
    final dev = _device;
    if (dev == null || !dev.isConnected) return null;
    final services = await dev.discoverServices();
    for (final s in services) {
      if (!_uuidMatches(s.uuid.str, immediateAlertServiceUuid)) continue;
      for (final c in s.characteristics) {
        if (_uuidMatches(c.uuid.str, alertLevelCharUuid) &&
            (c.properties.write || c.properties.writeWithoutResponse)) {
          _alertChar = c;
          return c;
        }
      }
    }
    return null;
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
    if (_heartRateReceptionPaused) return;
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
    // 心率超标时自动触发手环震动（防抖：同一条告警期只震一次）
    if (sample.isAlert &&
        (_lastAutoVibrationAt == null ||
            now.difference(_lastAutoVibrationAt!) >
                const Duration(seconds: 30))) {
      _lastAutoVibrationAt = now;
      unawaited(vibrateBandForTest(times: 2, on: const Duration(milliseconds: 400))
          .then((ok) {
        if (!ok) {
          debugPrint('MiBand6Auth: auto-vibration failed (band may be disconnected)');
        }
      }));
    }
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

  bool _uuidMatches(String actual, String expectedShortUuid) {
    final normalized = actual.toLowerCase();
    final expected = expectedShortUuid.toLowerCase();
    return normalized == expected || normalized.startsWith('0000$expected-');
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
    await _huami2021Sub?.cancel();
    _huami2021Sub = null;
    await _connStateSub?.cancel();
    _connStateSub = null;
    _hrChar = null;
    _alertChar = null;
    _chunkedV3WriteChar = null;
    _chunkedV3ReadChar = null;
    _chunkedV3Seq = 0;
    _authChar = null;
    _huami2021PayloadCompleter = null;
    _huami2021ExpectedEndpoint = null;
    _huami2021Crypto = null;
    _huami2021Decoder = null;
    _authWriteWithoutResponse = false;
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
    _heartRateReceptionPaused = false;
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
