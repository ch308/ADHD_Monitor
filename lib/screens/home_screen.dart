import 'dart:async';
import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:vibration/vibration.dart';

import '../models/band_stress_data.dart';
import '../models/device_binding.dart';
import '../models/heart_rate_data.dart';
import '../services/cloud_service.dart';
import '../services/esp_provision_service.dart' show EspProvKind;
import '../services/foreground_task_service.dart';
import '../services/miband_service.dart';
import '../services/session_store.dart';
import '../services/stress_calculator.dart';
import 'breathing_ball_page.dart';
import 'esp_provision_page.dart';
import 'footprint_page.dart';
import 'weekly_report_page.dart';

class AdhdMonitorApp extends StatefulWidget {
  const AdhdMonitorApp({
    super.key,
    required this.serverIp,
    this.authToken,
    this.activeChildId = 1,
    this.onLogout,
    this.onSwitchChild,
  });

  final String serverIp;
  final String? authToken;
  final int activeChildId;
  final VoidCallback? onLogout;
  final void Function(int childId)? onSwitchChild;

  @override
  State<AdhdMonitorApp> createState() => _AdhdMonitorAppState();
}

// 增加TickerProviderStateMixin以支持动画
class _AdhdMonitorAppState extends State<AdhdMonitorApp>
    with TickerProviderStateMixin {
  double bpm = 0;
  int? stressValue;
  DateTime? stressUpdatedAt;
  bool isAlert = false;
  bool isDismissed = false; //是否被家长点击消除警报
  bool isAlerting = false; // 当前是否在报警状态
  DateTime? alertStartTime; // 报警开始时间
  Timer? vibrationTimer; // 持续震动定时器
  late FlutterTts _flutterTts; // 语音播报实例
  List<FlSpot> chartData = []; // 心率历史数据列表
  /// 与 chartData 下标一一对应（后端 `time` 字段，如 14:30:05）
  List<String> chartTimestamps = [];
  String message = "正在同步云端数据...";

  /// 疗愈纯音（资源为 ffmpeg 生成的正弦波，可替换为更长混音）
  final AudioPlayer _healingPlayer = AudioPlayer();
  final ValueNotifier<bool> _massageStrokeOn = ValueNotifier(false);
  Timer? _massageStrokeTimer;

  /// 正念呼吸全屏是否在前台（与音乐、轻抚同属「陪伴调节」）
  bool _breathingPageVisible = false;

  /// 432/528Hz 疗愈音是否正在播放
  bool _healingPlaybackActive = false;

  /// 正在处理一轮完整流程（确认→选择→记录/呼吸→Kimi），期间禁止新报警触发
  bool _flowInProgress = false;

  /// Kimi 建议内容（不为 null 时在主屏显示建议卡片，无需第二个 Dialog）
  String? _kimiAdvice;
  String? _kimiAdviceLabel;
  // ── 内联记录表单（彻底取代 Dialog，消除 _dependents.isEmpty 断言）──
  final TextEditingController _recordController = TextEditingController();
  String? _selectedConditionType; // null=显示选择按钮 'adhd'/'autism'=显示表单
  String? _selectedConditionLabel;
  bool _recordSubmitting = false;

  static const double _alertBpm = 120;

  /// 家长手动消除报警后，再次进入「全量报警」前的一段抑制窗口（防抖动），
  /// 与「设备侧已恢复为非报警」二选一即可解除——避免固定死等 2 分钟错过后续真实升高。
  static const Duration _rearmSuppressDuration = Duration(seconds: 45);
  DateTime? _rearmSuppressedUntil;

  /// 消除报警后，是否已至少看到一次服务器 `alert == false`（认为生理上缓和过）
  bool _sawNoAlertSinceDismiss = true;

  // ── 蓝牙手环（小米手环 6 / 兼容设备）──
  /// TODO: 替换为你从 Mi Fit / Zepp Life 抓包提取出来的真实 32 位 Hex Auth Key
  /// （每只手环唯一；不替换的话握手会失败、收不到心率 notify）。
  static const String _miBand6AuthKey = '1234567890abcdef1234567890abcdef';

  final StressCalculator _stressCalc = StressCalculator();

  late final CloudService _cloudService =
      CloudService(serverHost: widget.serverIp);
  late final MiBand6Auth _miBandService = MiBand6Auth(
    cloudService: _cloudService,
    authHexKey: _miBand6AuthKey,
    // Mi Band 6 压力值为私有协议，这些是 FEE1 服务下可能的候选 UUID。
    // 若仍读取不到，查看 logcat 中 "auto-probe char" 日志定位真实 UUID。
    stressCharacteristicUuids: const <String>[
      '0000000d-0000-1000-8000-00805f9b34fb',
      '0000000e-0000-1000-8000-00805f9b34fb',
      '00000012-0000-1000-8000-00805f9b34fb',
      '00002a59-0000-1000-8000-00805f9b34fb',
    ],
  );
  StreamSubscription<BluetoothAdapterState>? _btAdapterSub;
  StreamSubscription<HeartRateSample>? _bandHrSub;
  StreamSubscription<BandStressSample>? _bandStressSub;
  bool _btBootstrapping = false;
  MiBandStage? _lastBandStageForToast;

  /// 手环设备与孩子的绑定状态
  DeviceBinding? _deviceBinding;
  bool _bindingCheckInProgress = false;
  bool _bindingActionInProgress = false;

  /// 当前孩子已绑定的毛绒球呼吸灯 device_id（null=未绑定/未配网）
  String? _boundEsp32DeviceId;

  /// 当前孩子已绑定的 xiaozhi 星星机器人 device_id（null=未绑定/未配网）
  String? _boundXiaozhiDeviceId;

  /// 手环 stress 触发"还在焦虑中"的阈值（小米手环 stress 0-100），可由家长滑动调整。
  static const int _defaultStressAlertThreshold = 60;
  int _stressAlertThreshold = _defaultStressAlertThreshold;

  /// 防止 stress 值在阈值附近抖动反复触发：当前是否已经因 stress 触发过
  bool _stressAlertTriggered = false;

  Map<String, String> _apiHeaders({bool jsonBody = true}) {
    final h = <String, String>{'X-Child-Id': '${widget.activeChildId}'};
    if (jsonBody) {
      h['Content-Type'] = 'application/json';
    }
    final t = widget.authToken;
    
    if (t != null && t.isNotEmpty) {
      h['Authorization'] = 'Bearer $t';
    }
    return h;
  }

  /// 横轴只生成 3 个刻度位置：起点、中点、终点（依赖显式 interval，否则 getTitlesWidget 几乎收不到整数下标）
  double _bottomTitleInterval() {
    if (chartData.length <= 1) return 1;
    final span = chartData.last.x;
    return span > 0 ? span / 2 : 1;
  }

  String _shortTimeAtX(double x) {
    if (chartData.isEmpty || chartTimestamps.isEmpty) return '';
    final last = chartData.length - 1;
    final i = x.round().clamp(0, last);
    final raw = chartTimestamps[i];
    final parts = raw.split(':');
    if (parts.length >= 2) return '${parts[0]}:${parts[1]}';
    return raw;
  }

  late AnimationController _breathingController;
  late Animation<double> _breathingAnimation;

  @override
  void initState() {
    super.initState();
    _initTts(); // 初始化语音
    // 初始化呼吸动画控制器
    _breathingController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 2000), // 呼吸周期为 2 秒
    )..repeat(reverse: true); //自动往返执行呼吸感

    _breathingAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _breathingController, curve: Curves.easeInOut),
    );

    // 每 3 秒从云服务器拉取一次最新的模拟心率
    Timer.periodic(Duration(seconds: 3), (timer) => fetchStatus());

    // 启动时加载历史心率数据
    fetchHistory();

    // 每 5 秒刷新历史心率数据
    Timer.periodic(Duration(seconds: 5), (timer) => fetchHistory());

    // 蓝牙手环引导：监听适配器状态，开启即尝试静默连接
    _bootstrapMiBand();
    _miBandService.status.addListener(_onBandStatusChanged);
    _bindMiBandRealtimeStreams();
    // Android 前台服务初始化（息屏后保持手环 BLE）
    unawaited(_initForegroundService());
    // 从本地缓存恢复"当前孩子绑定的 ESP32"
    unawaited(_restoreBoundEsp32());
    unawaited(_restoreBoundXiaozhi());
    unawaited(_restoreStressThreshold());
  }

  Future<void> _restoreStressThreshold() async {
    final threshold = await SessionStore.getStressThreshold(widget.activeChildId);
    if (!mounted) return;
    setState(() => _stressAlertThreshold = threshold);
  }

  Future<void> _restoreBoundEsp32() async {
    final id = await SessionStore.getBoundEsp32(widget.activeChildId);
    if (!mounted) return;
    if (id != null && id.isNotEmpty) {
      setState(() => _boundEsp32DeviceId = id);
    }
  }

  Future<void> _restoreBoundXiaozhi() async {
    final id = await SessionStore.getBoundXiaozhi(widget.activeChildId);
    if (!mounted) return;
    if (id != null && id.isNotEmpty) {
      setState(() => _boundXiaozhiDeviceId = id);
    }
  }

  void _bindMiBandRealtimeStreams() {
    _bandHrSub?.cancel();
    _bandHrSub = _miBandService.bpmStream.listen(_appendRealtimeHeartRate);

    _bandStressSub?.cancel();
    _bandStressSub = _miBandService.stressStream.listen((sample) {
      if (!mounted) return;
      setState(() {
        stressValue = sample.value;
        stressUpdatedAt = sample.timestamp;
      });
      _maybeTriggerStressAlert(sample.value);
    });
  }

  /// 手环 stress 高于阈值时触发"还在焦虑中"流程（与 bpm 报警共用同一套 UI 与定时器）。
  /// 一次冒泡只触发一次，回落到阈值以下 5 点才允许下次触发，避免抖动。
  void _maybeTriggerStressAlert(int stress) {
    if (stress < _stressAlertThreshold - 5 && _stressAlertTriggered) {
      _stressAlertTriggered = false;
      return;
    }
    if (stress < _stressAlertThreshold) return;
    if (_stressAlertTriggered) return;
    if (isAlerting || _flowInProgress) return;
    if (_rearmSuppressedUntil != null &&
        DateTime.now().isBefore(_rearmSuppressedUntil!) &&
        !_sawNoAlertSinceDismiss) {
      return;
    }
    _stressAlertTriggered = true;
    setState(() {
      isAlerting = true;
      alertStartTime = DateTime.now();
      isDismissed = false;
      _flowInProgress = false;
      _selectedConditionType = null;
      _selectedConditionLabel = null;
      _recordSubmitting = false;
      _kimiAdvice = null;
      _kimiAdviceLabel = null;
      _rearmSuppressedUntil = null;
      _sawNoAlertSinceDismiss = true;
      vibrationTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _alarmPulseTick();
      });
    });
    debugPrint('Stress=$stress >= $_stressAlertThreshold → alert');
  }

  void _applyStressThreshold(int next, {bool evaluateCurrent = true}) {
    setState(() {
      _stressAlertThreshold = next;
      if ((stressValue ?? 0) < next - 5) {
        _stressAlertTriggered = false;
      }
    });
    unawaited(SessionStore.saveStressThreshold(widget.activeChildId, next));

    if (evaluateCurrent) {
      final current = stressValue;
      if (current != null) {
        _maybeTriggerStressAlert(current);
      }
    }
  }

  Future<void> _showStressThresholdDialog() async {
    var draft = _stressAlertThreshold.toDouble();
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('设置压力报警阈值'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '当前阈值：${draft.round()}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  Slider(
                    value: draft,
                    min: 30,
                    max: 90,
                    divisions: 12,
                    label: '${draft.round()}',
                    onChanged: (v) => setDialogState(() => draft = v),
                  ),
                  const Row(
                    children: [
                      Text('30', style: TextStyle(fontSize: 11)),
                      Spacer(),
                      Text('90', style: TextStyle(fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '压力算法：优先使用小米手环私有 stress 值；拿不到时，基于近 30 个心率样本计算。'
                    '综合三项：心率相对动态基线的抬升(50%)、近期变异度(25%)、上升趋势(25%)，'
                    '输出 0-100 分。低于阈值 5 分后才允许下一次触发，避免来回抖动。',
                    style: TextStyle(fontSize: 12, height: 1.5),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(draft.round()),
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
    if (chosen == null || !mounted) return;
    _applyStressThreshold(chosen);
  }

  /// 手环 BLE notify 一到就直接刷新 UI 和趋势图。
  ///
  /// 云端历史接口仍用于 App 启动/断开后回填；当手环正在 streaming 时，
  /// [fetchHistory] 会跳过覆盖，避免实时曲线被 5 秒轮询的旧数据冲掉。
  void _appendRealtimeHeartRate(HeartRateSample sample) {
    if (!mounted) return;
    if (sample.bpm <= 0) return;
    final label = _formatTime(sample.timestamp);
    final newY = sample.bpm.toDouble();
    final existing = chartData.map((spot) => spot.y).toList();
    existing.add(newY);
    final trimmed = existing.length > 20
        ? existing.sublist(existing.length - 20)
        : existing;
    final calculatedStress =
        _stressCalc.calculateStress(sample.bpm, sample.timestamp);

    setState(() {
      bpm = newY;
      isAlert = newY >= _alertBpm;
      chartData = trimmed
          .asMap()
          .entries
          .map((e) => FlSpot(e.key.toDouble(), e.value))
          .toList();
      chartTimestamps = <String>[
        ...chartTimestamps,
        label,
      ];
      if (chartTimestamps.length > 20) {
        chartTimestamps =
            chartTimestamps.sublist(chartTimestamps.length - 20);
      }
      message = _resolveStatusMessage();
      if (calculatedStress != null) {
        stressValue = calculatedStress;
        stressUpdatedAt = sample.timestamp;
      }
    });
    if (calculatedStress != null) {
      _maybeTriggerStressAlert(calculatedStress);
    }
  }

  String _formatTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Future<void> _initForegroundService() async {
    try {
      await ForegroundTaskService.ensureInit();
      await ForegroundTaskService.requestNotificationPermission();
    } catch (e) {
      debugPrint('FG service init error: $e');
    }
  }

  /// 仅用于一次性 SnackBar 提示（持久化的横幅信息由 ValueListenableBuilder 渲染）
  void _onBandStatusChanged() {
    if (!mounted) return;
    final s = _miBandService.status.value;
    if (s.stage == _lastBandStageForToast) return;
    _lastBandStageForToast = s.stage;
    switch (s.stage) {
      case MiBandStage.streaming:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF2E7D32),
            duration: Duration(seconds: 3),
            content: Text('✅ 已连接小米手环，开始接收实时心率'),
          ),
        );
        unawaited(ForegroundTaskService.start(
          text: '正在与小米手环保持连接 · 实时心率推送中',
        ));
        // 连接成功后同步 MAC 到云端服务并检查绑定
        _syncMacToCloudService();
        unawaited(_checkAndResolveBinding());
        break;
      case MiBandStage.authFailed:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 4),
            content: const Text('❌ 手环安全握手失败，请检查 Auth Key'),
          ),
        );
        break;
      case MiBandStage.notFound:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.orange.shade700,
            duration: const Duration(seconds: 3),
            content: const Text('⚠️ 未发现小米手环 6'),
          ),
        );
        break;
      default:
        break;
    }
  }

  /// 将当前连接的 MAC、childId、token 同步到 CloudService，确保上传携带设备标识。
  void _syncMacToCloudService() {
    final mac = _miBandService.connectedMacAddress;
    _cloudService.macAddress = mac;
    _cloudService.childId = widget.activeChildId;
    _cloudService.authToken = widget.authToken;
  }

  /// 连接成功后检查手环 MAC 的绑定状态，并在需要时提示用户绑定/解绑。
  Future<void> _checkAndResolveBinding() async {
    final mac = _miBandService.connectedMacAddress;
    if (mac == null || mac.isEmpty) return;
    if (_bindingCheckInProgress) return;
    _bindingCheckInProgress = true;
    try {
      // 先查本地缓存
      final cachedMac = await SessionStore.getBoundMac(widget.activeChildId);
      if (cachedMac == mac) {
        _deviceBinding = DeviceBinding.boundToCurrent(mac, widget.activeChildId);
        return;
      }

      // 查云端绑定记录
      final binding = await _cloudService.checkDeviceBinding(mac);
      if (!mounted) return;
      if (binding != null) {
        _deviceBinding = binding;
        if (binding.isBoundToCurrentChild) {
          await SessionStore.saveBoundMac(widget.activeChildId, mac);
        }
      } else {
        // 网络不可达，尝试本地判定
        if (cachedMac != null && cachedMac != mac) {
          _deviceBinding = DeviceBinding.boundToOther(
            mac, widget.activeChildId,
            nickname: '当前孩子已绑定另一只手环（$cachedMac）',
          );
        } else {
          _deviceBinding = DeviceBinding.unbound(mac);
        }
      }
    } finally {
      _bindingCheckInProgress = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _bindCurrentDevice() async {
    final mac = _miBandService.connectedMacAddress;
    if (mac == null || mac.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前还没有连接到小米手环，无法绑定')),
      );
      return;
    }
    if (_bindingActionInProgress) return;
    _bindingActionInProgress = true;
    if (mounted) setState(() {});
    try {
      final ok = await _cloudService.bindDevice(mac, widget.activeChildId);
      if (!mounted) return;
      if (ok) {
        await SessionStore.saveBoundMac(widget.activeChildId, mac);
        _deviceBinding = DeviceBinding.boundToCurrent(mac, widget.activeChildId);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF2E7D32),
            content: Text('✅ 手环已绑定到当前孩子'),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: const Text('绑定失败，请检查网络或服务器状态'),
          ),
        );
      }
    } finally {
      _bindingActionInProgress = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _unbindCurrentDevice() async {
    final mac = _miBandService.connectedMacAddress;
    if (mac == null || mac.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前还没有连接到小米手环，无法解绑')),
      );
      return;
    }
    if (_bindingActionInProgress) return;
    _bindingActionInProgress = true;
    if (mounted) setState(() {});
    try {
      final ok = await _cloudService.unbindDevice(mac, widget.activeChildId);
      if (!mounted) return;
      if (ok) {
        await SessionStore.removeBoundMac(widget.activeChildId);
        _deviceBinding = DeviceBinding.unbound(mac);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFFF57C00),
            content: Text('手环已解绑'),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade700,
            content: const Text('解绑失败，请检查网络或服务器状态'),
          ),
        );
      }
    } finally {
      _bindingActionInProgress = false;
      if (mounted) setState(() {});
    }
  }

  void _initTts() {
    _flutterTts = FlutterTts();
    _flutterTts.setLanguage("zh-CN"); //设置为中文
    _flutterTts.setPitch(1.0); //音调 （0.5-2.0）
    _flutterTts.setSpeechRate(0.5); //语速 0.5 听起来比较温暖自然
  }

  /// BLE 引导：先请求权限，再监听适配器状态；一旦蓝牙打开就尝试自动连接手环
  Future<void> _bootstrapMiBand() async {
    try {
      await _miBandService.requestPermissions();
    } catch (e) {
      debugPrint('MiBand permission error: $e');
    }
    _btAdapterSub?.cancel();
    _btAdapterSub = FlutterBluePlus.adapterState.listen((state) {
      _miBandService.notifyBluetoothState(state);
      if (state == BluetoothAdapterState.on &&
          !_miBandService.isStreaming &&
          !_btBootstrapping) {
        unawaited(_autoConnectToBand());
      }
    });
  }

  Future<void> _retryBandConnect() async {
    if (_btBootstrapping) return;
    await _miBandService.disconnect();
    _lastBandStageForToast = null;
    await _autoConnectToBand();
  }

  Future<void> _autoConnectToBand() async {
    if (_btBootstrapping || _miBandService.isStreaming) return;
    _btBootstrapping = true;
    try {
      // 1. 先尝试从系统已连接设备中直接捞取手环
      BluetoothDevice? targetBand =
          await _miBandService.findAlreadyConnectedBand();

      // 2. 捞不到就走带超时的常规扫描（默认 15s）
      targetBand ??= await _miBandService.scanForBand();

      if (targetBand != null) {
        await _miBandService.startAuthentication(targetBand);
      } else {
        debugPrint('MiBand: 未发现手环，等待下一次蓝牙状态变化或重连。');
      }
    } catch (e) {
      debugPrint('MiBand auto-connect failed: $e');
    } finally {
      _btBootstrapping = false;
    }
  }

  //语音播报函数
  Future<void> _speak(String text) async {
    await _flutterTts.speak(text);
  }

  /// 家长正带孩子做呼吸 / 听音乐 / 轻抚等感官调节时，不反复震动与语音打断
  bool _inCompanionRegulationMode() {
    if (_breathingPageVisible) return true;
    if (_healingPlaybackActive) return true;
    if (_massageStrokeOn.value) return true;
    return false;
  }

  String _resolveStatusMessage() {
    if (!isAlerting) return '✅ 状态平稳';
    if (_inCompanionRegulationMode()) {
      return '🧘 陪伴调节中（心率仍偏高，已暂停反复震动与语音）';
    }
    return '🚨 孩子可能处于焦虑状态';
  }

  void _alarmPulseTick() {
    if (_inCompanionRegulationMode()) return;
    Vibration.vibrate(pattern: [0, 500, 200, 500]);
    unawaited(_speak('孩子可能处于焦虑状态，请及时关注'));
  }

  @override
  void dispose() {
    _breathingController.dispose();
    _recordController.dispose();
    vibrationTimer?.cancel();
    _massageStrokeTimer?.cancel();
    _massageStrokeOn.dispose();
    unawaited(_healingPlayer.dispose());
    _flutterTts.stop(); // 停止语音播报
    _btAdapterSub?.cancel();
    _bandHrSub?.cancel();
    _bandStressSub?.cancel();
    _miBandService.status.removeListener(_onBandStatusChanged);
    unawaited(_miBandService.dispose());
    unawaited(ForegroundTaskService.stop());
    super.dispose();
  }

  Future<void> _playHealingTone(String folder) async {
    // folder: 'assets/audio/432Hz' 或 'assets/audio/528Hz'
    final tracks = folder.contains('432')
        ? const [
            'assets/audio/432Hz/danamusic-432hz-meditation.mp3',
            'assets/audio/432Hz/danamusic-432hz-meditation-with-nature-sound.mp3',
            'assets/audio/432Hz/denis-pavlov-music-432hz-healing-meditation-zen-stress-relief-music.mp3',
            'assets/audio/432Hz/megisss-deep-healing-432hz.mp3',
            'assets/audio/432Hz/wings_of_freedom-nature-sounds-slow-meditation-healing-frequency-432hz.mp3',
          ]
        : const [
            'assets/audio/528Hz/danamusic-528hz-healing-meditation.mp3',
            'assets/audio/528Hz/danamusic-528hz-healing-meditation-with-nature-sound.mp3',
            'assets/audio/528Hz/frequencyoflove-528hz-dna-repair-and-love.mp3',
            'assets/audio/528Hz/frequencyoflove-528hz-miracle-love-tone.mp3',
            'assets/audio/528Hz/frequencyoflove-unconditional-love-resonance-528hz.mp3',
          ];
    try {
      await _flutterTts.stop();
      await _healingPlayer.stop();
      final playlist = ConcatenatingAudioSource(
        useLazyPreparation: true,
        shuffleOrder: DefaultShuffleOrder(),
        children: tracks.map((p) => AudioSource.asset(p)).toList(),
      );
      await _healingPlayer.setAudioSource(playlist, initialIndex: 0);
      await _healingPlayer.setLoopMode(LoopMode.all);
      await _healingPlayer.play();
      _healingPlaybackActive = true;
      if (mounted) {
        setState(() => message = _resolveStatusMessage());
      }
    } catch (e) {
      debugPrint('疗愈音频: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('音频播放失败：$e')),
        );
      }
    }
  }

  Future<void> _stopHealingTones() async {
    try {
      await _healingPlayer.stop();
    } catch (_) {}
    _healingPlaybackActive = false;
    if (mounted) {
      setState(() => message = _resolveStatusMessage());
    }
  }

  void _toggleMassageStroke() {
    if (_massageStrokeOn.value) {
      _massageStrokeTimer?.cancel();
      _massageStrokeTimer = null;
      _massageStrokeOn.value = false;
      if (mounted && isAlerting) {
        setState(() => message = _resolveStatusMessage());
      }
      return;
    }
    _massageStrokeOn.value = true;
    _massageStrokeTimer?.cancel();
    _massageStrokeTimer =
        Timer.periodic(const Duration(milliseconds: 880), (_) {
      if (!_massageStrokeOn.value) return;
      // 轻抚感：短促、错落，与报警用长震区分
      Vibration.vibrate(pattern: [0, 32, 100, 26, 130, 20, 150, 0]);
    });
    if (mounted && isAlerting) {
      setState(() => message = _resolveStatusMessage());
    }
  }

  Future<void> _presentBreathingBallPage() async {
    if (!mounted) return;
    final hadAlarmTimer = vibrationTimer != null;
    vibrationTimer?.cancel();
    vibrationTimer = null;
    _breathingPageVisible = true;
    unawaited(_flutterTts.stop());
    if (mounted && isAlerting) {
      setState(() => message = _resolveStatusMessage());
    }

    // 进入正念呼吸：通知毛绒球呼吸灯开始呼吸灯效（与 UI 呼吸球同步周期）
    final esp = _boundEsp32DeviceId;
    if (esp != null && esp.isNotEmpty) {
      unawaited(_cloudService.triggerEsp32BreathingStart(
        esp,
        cyclePeriod: const Duration(milliseconds: 8000),
      ));
    }

    try {
      await Navigator.of(context).push<void>(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 400),
          opaque: true,
          pageBuilder: (ctx, _, __) =>
              BreathingBallPage(
            massageStrokeOn: _massageStrokeOn,
            onToggleMassageStroke: _toggleMassageStroke,
            onPlay432: () => _playHealingTone('assets/audio/432Hz'),
            onPlay528: () => _playHealingTone('assets/audio/528Hz'),
            onStopAudio: _stopHealingTones,
          ),
        ),
      );
    } finally {
      _breathingPageVisible = false;
      // 用户从呼吸页返回/取消：通知毛绒球呼吸灯停止
      if (esp != null && esp.isNotEmpty) {
        unawaited(_cloudService.triggerEsp32BreathingStop(esp));
      }
      if (mounted) {
        setState(() => message = _resolveStatusMessage());
      }
    }
    if (!mounted) return;
    if (hadAlarmTimer && isAlerting && !isDismissed) {
      vibrationTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _alarmPulseTick();
      });
    }
  }

  /// 入口：跳转到 ESP32 BLE 配网页面；返回带 device_id 时立刻更新本地绑定。
  Future<void> _openEspProvisionPage() async {
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (ctx) => EspProvisionPage(
          cloudService: _cloudService,
          activeChildId: widget.activeChildId,
          currentBoundDeviceId: _boundEsp32DeviceId,
        ),
      ),
    );
    if (!mounted) return;
    if (id != null && id.isNotEmpty) {
      setState(() => _boundEsp32DeviceId = id);
    }
  }

  /// 入口：跳转到 xiaozhi 星星机器人 BLE 配网页面（与毛绒球完全相同的 UI 和流程，
  /// 只是广播名前缀换成 `XIAOZHI_`、绑定时给云端打 `kind=xiaozhi` 标签）。
  Future<void> _openXiaozhiProvisionPage() async {
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (ctx) => EspProvisionPage(
          cloudService: _cloudService,
          activeChildId: widget.activeChildId,
          currentBoundDeviceId: _boundXiaozhiDeviceId,
          kind: EspProvKind.xiaozhi,
        ),
      ),
    );
    if (!mounted) return;
    if (id != null && id.isNotEmpty) {
      setState(() => _boundXiaozhiDeviceId = id);
    }
  }

  /// 让当前绑定的毛绒球呼吸灯清空 WiFi 凭据并重启进入 BLE 配网模式。
  ///
  /// 适用场景：换路由器 / 换 WiFi 密码 / 想把毛绒球呼吸灯搬到别的网络。
  /// 注意：device_id 来自 efuse MAC 不会变，服务器端绑定关系会保留，
  /// 所以重新配网完成后无需再走"绑定到孩子"流程。
  Future<void> _resetEsp32Provisioning() async {
    final deviceId = _boundEsp32DeviceId;
    if (deviceId == null || deviceId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('当前孩子还没有绑定毛绒球呼吸灯，无法发起远程重新配网。'
              '请先用"配网毛绒球呼吸灯"完成首次配网。'),
        ),
      );
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('让毛绒球呼吸灯重新配网？'),
        content: Text(
          '将向毛绒球呼吸灯 $deviceId 下发重启指令：\n'
          '• 板子会清掉当前 WiFi 凭据并重启；\n'
          '• 重启后会广播 ADHD_$deviceId，等待手机 BLE 配网；\n'
          '• 服务器端绑定不变，配网完成后会自动重新上线。\n\n'
          '确认继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认重启毛绒球呼吸灯'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final pushed = await _cloudService.triggerEsp32ResetProvisioning(deviceId);
    if (!mounted) return;
    if (!pushed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('远程重启命令下发失败：毛绒球呼吸灯当前可能离线。'
              '可以长按板子 BOOT 键 5 秒进入物理重置流程。'),
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已下发重启命令，毛绒球呼吸灯将在数秒内广播 ADHD_$deviceId，'
            '请点击右上角"配网毛绒球呼吸灯"完成 BLE 配网。'),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// 让当前绑定的 xiaozhi 星星机器人清空 WiFi 凭据并重启进入 BLE 配网模式。
  ///
  /// 命令流和毛绒球一致：服务器把 `reset_provisioning` 入队，板子长轮询拿到
  /// 后调用 `adhd_prov_ble_reset_and_reboot()` 清掉 NVS 里的 wifi 凭据 + 重启，
  /// 之后会广播 `XIAOZHI_<MAC8>`，App 在配网页一扫就看到。
  Future<void> _resetXiaozhiProvisioning() async {
    final deviceId = _boundXiaozhiDeviceId;
    if (deviceId == null || deviceId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('当前孩子还没有绑定星星机器人，无法发起远程重新配网。'
              '请先用"配网星星机器人"完成首次配网。'),
        ),
      );
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('让星星机器人重新配网？'),
        content: Text(
          '将向星星机器人 $deviceId 下发重启指令：\n'
          '• 板子会清掉当前 WiFi 凭据并重启；\n'
          '• 重启后会广播 XIAOZHI_$deviceId，等待手机 BLE 配网；\n'
          '• 服务器端绑定不变，配网完成后会自动重新上线。\n\n'
          '确认继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认重启星星机器人'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final pushed = await _cloudService.triggerEsp32ResetProvisioning(deviceId);
    if (!mounted) return;
    if (!pushed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('远程重启命令下发失败：星星机器人当前可能离线。'
              '可以长按板子 BOOT 键 5 秒进入物理重置流程。'),
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已下发重启命令，星星机器人将在数秒内广播 XIAOZHI_$deviceId，'
            '请点击右上角"配网星星机器人"完成 BLE 配网。'),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// 绑定小智（xiaozhi）板：输入 WiFi MAC，服务器 `esp32_devices.kind` 记为 xiaozhi，用于 submit_log 后自动唤醒。
  Future<void> _showXiaozhiBindDialog() async {
    final ctrl = TextEditingController();
    final submit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('绑定小智设备 (MAC)'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '请输入设备 Wi‑Fi MAC（12 位十六进制）。可从路由器后台或板子配网界面查看；'
                '绑定后请在小智固件 menuconfig 中打开 ADHD Monitor integration 并填写同一服务器 IP。',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(
                  labelText: 'MAC / device_id',
                  hintText: '例：AABBCCDDEEFF 或 AA:BB:CC:DD:EE:FF',
                ),
                autocorrect: false,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('绑定到当前孩子'),
          ),
        ],
      ),
    );
    if (submit != true || !mounted) return;
    final raw = ctrl.text.trim().replaceAll(RegExp(r'[:\-\s]'), '').toUpperCase();
    if (!RegExp(r'^[0-9A-F]{12}$').hasMatch(raw)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入 12 位十六进制 MAC。')),
      );
      return;
    }
    final ok = await _cloudService.bindEsp32(
      raw,
      widget.activeChildId,
      kind: 'xiaozhi',
    );
    if (!mounted) return;
    if (ok) {
      // 让"让星星机器人重新配网"知道该往哪台设备发命令。
      await SessionStore.saveBoundXiaozhi(widget.activeChildId, raw);
      if (mounted) setState(() => _boundXiaozhiDeviceId = raw);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已绑定小智设备 $raw 到当前孩子' : '绑定失败：请确认已登录且网络正常'),
      ),
    );
  }

  Future<void> fetchHistory() async {
    if (_miBandService.isStreaming) return;
    try {
      final response = await http.get(
        Uri.parse('http://${widget.serverIp}:11760/history'),
        headers: _apiHeaders(jsonBody: false),
      );
      if (response.statusCode == 200) {
        List<dynamic> data = json.decode(response.body);
        // 只保留最近 20 条历史数据，避免图表过度稀疏或过长
        final recentData =
            data.length > 20 ? data.sublist(data.length - 20) : data;
        setState(() {
          chartTimestamps =
              recentData.map((e) => e['time']?.toString() ?? '').toList();
          chartData = recentData.asMap().entries.map((e) {
            return FlSpot(
              e.key.toDouble(),
              (e.value['bpm'] as num).toDouble(),
            );
          }).toList();
        });
      }
    } catch (e) {
      debugPrint('图表数据获取失败: $e');
    }
  }

  Future<void> fetchStatus() async {
    try {
      final response = await http.get(
        Uri.parse('http://${widget.serverIp}:11760/webhook'),
        headers: _apiHeaders(jsonBody: false),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        double newBpm = data['bpm']?.toDouble() ?? 0;
        bool newAlert = data['alert'] ?? false;

        // 当手环正在实时推送时，BPM 以 BLE 数据为准，忽略云端返回值（可能为 0）
        final useCloudBpm = !_miBandService.isStreaming && newBpm > 0;

        // 关键修改：动态调整动画速度
        // 计算新的动画周期（毫秒）
        // 假设：BPM 60-> 2500ms (慢)， BPM 120-> 800ms (快)
        final animBpm = useCloudBpm ? newBpm : (bpm > 0 ? bpm : 60);
        int newDuration = (60 / animBpm * 2000).toInt();
        // 限制范围，防止过快或者过慢
        newDuration = newDuration.clamp(500, 3000);

        if (_breathingController.duration?.inMicroseconds != newDuration) {
          _breathingController.duration = Duration(milliseconds: newDuration);
          if (_breathingController.isAnimating) {
            _breathingController.repeat(reverse: true); // 重新启动动画以应用新周期
          }
        }
        //-------------------------------------
        // 手动消除报警后：任一轮询若已不再报警，则认为可更快「重新武装」
        if (!newAlert) {
          _sawNoAlertSinceDismiss = true;
        }

        // 检查是否需要停止报警（2分钟超时）
        if (isAlerting && alertStartTime != null) {
          Duration elapsed = DateTime.now().difference(alertStartTime!);
          if (elapsed.inMinutes >= 2) {
            setState(() {
              isAlerting = false;
              isDismissed = false;
              vibrationTimer?.cancel();
              vibrationTimer = null;
            });
          }
        }

        final suppressed = _rearmSuppressedUntil != null;
        final pastSuppressWindow =
            suppressed && DateTime.now().isAfter(_rearmSuppressedUntil!);
        final canRearmAfterDismiss =
            !suppressed || pastSuppressWindow || _sawNoAlertSinceDismiss;

        // 若新报警且当前不在报警状态，且流程空闲，且未处于消除后的抑制
        if (newAlert &&
            !isAlerting &&
            !_flowInProgress &&
            canRearmAfterDismiss) {
          setState(() {
            isAlerting = true;
            alertStartTime = DateTime.now();
            isDismissed = false;
            _flowInProgress = false;
            _selectedConditionType = null;
            _selectedConditionLabel = null;
            _recordSubmitting = false;
            _kimiAdvice = null;
            _kimiAdviceLabel = null;
            _rearmSuppressedUntil = null;
            _sawNoAlertSinceDismiss = true;
            // 启动周期性提醒（在陪伴调节模式下由 _alarmPulseTick 跳过）
            vibrationTimer = Timer.periodic(const Duration(seconds: 5), (_) {
              _alarmPulseTick();
            });
          });
        }

        setState(() {
          if (useCloudBpm) bpm = newBpm;
          isAlert = newAlert;
          message = _resolveStatusMessage();
        });
      }
    } catch (e) {
      setState(() => message = "连接云服务器失败");
    }
  }

  Widget _buildAlertActionButtons() {
    if (!isDismissed) return const SizedBox.shrink();

    // ── 阶段 A：选择下一步 ──
    if (_selectedConditionType == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('请选择下一步',
                style: TextStyle(
                    fontSize: 13,
                    color: Colors.black45,
                    fontWeight: FontWeight.w500)),
            const SizedBox(height: 12),
            _OptionCard(
              icon: Icons.spa_outlined,
              label: '引导孩子正念呼吸',
              subtitle: '呼吸球 + 疗愈纯音 + 轻抚震动',
              color: const Color(0xFF00897B),
              onTap: () async {
                await _presentBreathingBallPage();
                if (mounted) {
                  setState(() {
                    isDismissed = false;
                    _flowInProgress = false;
                  });
                }
              },
            ),
            const SizedBox(height: 8),
            _OptionCard(
              icon: Icons.psychology_outlined,
              label: '多动症 · 记录当前行为',
              subtitle: '描述行为，获取 AI 建议',
              color: const Color(0xFFF57C00),
              onTap: () => setState(() {
                _selectedConditionType = 'adhd';
                _selectedConditionLabel = '多动症';
                _recordController.clear();
              }),
            ),
            const SizedBox(height: 8),
            _OptionCard(
              icon: Icons.volunteer_activism_outlined,
              label: '自闭症 · 记录当前行为',
              subtitle: '描述行为，获取 AI 建议',
              color: const Color(0xFF3949AB),
              onTap: () => setState(() {
                _selectedConditionType = 'autism';
                _selectedConditionLabel = '自闭症';
                _recordController.clear();
              }),
            ),
          ],
        ),
      );
    }

    // ── 阶段 B：内联记录表单 ──
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Card(
        elevation: 2,
        shadowColor: Colors.black12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [
                        _selectedConditionType == 'adhd'
                            ? const Color(0xFFFF9800)
                            : const Color(0xFF5C6BC0),
                        _selectedConditionType == 'adhd'
                            ? const Color(0xFFF57C00)
                            : const Color(0xFF3949AB),
                      ]),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _selectedConditionLabel!,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '记录孩子行为',
                      style:
                          TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _recordController,
                decoration: InputDecoration(
                  hintText: '孩子现在在做什么？（如：写作业、大叫、来回踱步）',
                  hintStyle: TextStyle(color: Colors.grey.shade400),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade200),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                        color: _selectedConditionType == 'adhd'
                            ? const Color(0xFFFF9800)
                            : const Color(0xFF5C6BC0),
                        width: 2),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  filled: true,
                  fillColor: Colors.grey.shade50,
                ),
                maxLines: 3,
                autofocus: true,
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: _recordSubmitting
                        ? null
                        : () => setState(() {
                              _selectedConditionType = null;
                              _selectedConditionLabel = null;
                              _recordController.clear();
                            }),
                    child: const Text('返回'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _recordSubmitting ? null : _submitRecord,
                      style: FilledButton.styleFrom(
                        backgroundColor: _selectedConditionType == 'adhd'
                            ? const Color(0xFFFF9800)
                            : const Color(0xFF5C6BC0),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _recordSubmitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('提交并获取建议',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 14)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submitRecord() async {
    final text = _recordController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请简要描述孩子当下的行为')),
      );
      return;
    }
    setState(() => _recordSubmitting = true);
    try {
      final response = await http.post(
        Uri.parse('http://${widget.serverIp}:11760/submit_log'),
        headers: _apiHeaders(),
        body: json.encode({
          'bpm': bpm,
          'observation': text,
          'condition_type': _selectedConditionType,
        }),
      );
      if (!mounted) return;
      if (response.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('提交失败：${response.statusCode}')),
        );
        setState(() => _recordSubmitting = false);
        return;
      }
      final data = json.decode(response.body);
      final advice = data is Map && data['advice'] != null
          ? data['advice'].toString()
          : '暂无建议';
      setState(() {
        _kimiAdvice = advice;
        _kimiAdviceLabel = _selectedConditionLabel;
        _selectedConditionType = null;
        _selectedConditionLabel = null;
        isDismissed = false;
        _recordSubmitting = false;
      });
      _recordController.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('网络错误：$e')));
      setState(() => _recordSubmitting = false);
    }
  }

  Widget _buildAdviceCard() {
    if (_kimiAdvice == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Card(
        elevation: 3,
        shadowColor: Colors.black26,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF7C4DFF), Color(0xFF536DFE)],
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.auto_awesome,
                        color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'AI 专家建议 · $_kimiAdviceLabel',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_kimiAdvice!,
                      style:
                          const TextStyle(fontSize: 14, height: 1.65)),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.check_circle_outline, size: 18),
                      label: const Text('收到，回到待机'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF536DFE),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () => setState(() {
                        _kimiAdvice = null;
                        _kimiAdviceLabel = null;
                        _flowInProgress = false;
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSwitchChildDialog() async {
    final t = widget.authToken;
    if (t == null || t.isEmpty) return;
    try {
      final r = await http.get(
        Uri.parse('http://${widget.serverIp}:11760/my/children'),
        headers: _apiHeaders(jsonBody: false),
      );
      if (!mounted) return;
      if (r.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败（${r.statusCode}）')),
        );
        return;
      }
      final list =
          (json.decode(r.body) as Map)['children'] as List? ?? <dynamic>[];
      if (list.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂无孩子档案，请先在云端创建')),
        );
        return;
      }
      final chosen = await showDialog<int>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('选择关注的孩子'),
          children: list.map<Widget>((raw) {
            final m = Map<String, dynamic>.from(raw as Map);
            final id = (m['id'] as num).toInt();
            final nick = m['nickname']?.toString() ?? '';
            final role = m['role']?.toString() ?? '';
            return SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, id),
              child: Text('$nick (#$id) · $role'),
            );
          }).toList(),
        ),
      );
      if (chosen != null) widget.onSwitchChild?.call(chosen);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _showInviteMemberDialog() async {
    final t = widget.authToken;
    if (t == null || t.isEmpty) return;
    final userC = TextEditingController();
    final roleC = TextEditingController(text: '爸爸');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('邀请家庭成员'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: userC,
              decoration: const InputDecoration(
                labelText: '对方用户名（需已注册）',
              ),
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: roleC,
              decoration: const InputDecoration(
                labelText: '角色（如：爸爸、奶奶、老师）',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('加入协作'),
          ),
        ],
      ),
    );
    String? userTxt;
    String? roleTxt;
    if (ok == true) {
      userTxt = userC.text.trim().toLowerCase();
      roleTxt = roleC.text.trim();
    }
    userC.dispose();
    roleC.dispose();
    if (userTxt == null || userTxt.isEmpty || !mounted) return;
    try {
      final r = await http.post(
        Uri.parse(
          'http://${widget.serverIp}:11760/my/children/${widget.activeChildId}/members',
        ),
        headers: _apiHeaders(),
        body: json.encode({
          'username': userTxt,
          'role': roleTxt ?? 'family',
        }),
      );
      if (!mounted) return;
      if (r.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已将该用户加入本孩子的协作')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('失败：${r.body}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAlertMode = isAlerting && !isDismissed;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('ADHD 专注精灵',
            style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 1)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: isAlertMode
                  ? [const Color(0xFFE53935), const Color(0xFFFF6D6D)]
                  : [const Color(0xFF3949AB), const Color(0xFF5C6BC0)],
            ),
            boxShadow: [
              BoxShadow(
                color: (isAlertMode ? Colors.red : Colors.indigo)
                    .withValues(alpha: 0.3),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: '家庭协作',
            icon: const Icon(Icons.menu, color: Colors.white),
            onSelected: (v) async {
              if (v == 'logout') widget.onLogout?.call();
              if (v == 'invite') await _showInviteMemberDialog();
              if (v == 'switch') await _showSwitchChildDialog();
              if (v == 'band_bind') await _bindCurrentDevice();
              if (v == 'band_unbind') await _unbindCurrentDevice();
              if (v == 'stress_threshold') await _showStressThresholdDialog();
              if (v == 'esp_prov') await _openEspProvisionPage();
              if (v == 'esp_reset') await _resetEsp32Provisioning();
              if (v == 'xiaozhi_prov') await _openXiaozhiProvisionPage();
              if (v == 'xiaozhi_reset') await _resetXiaozhiProvisioning();
              if (v == 'xiaozhi_bind') await _showXiaozhiBindDialog();
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'switch', child: Text('切换关注的孩子')),
              const PopupMenuItem(value: 'invite', child: Text('邀请家庭成员')),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'band_bind',
                enabled: !_bindingActionInProgress,
                child: const Text('绑定小米手环到当前孩子'),
              ),
              PopupMenuItem(
                value: 'band_unbind',
                enabled: !_bindingActionInProgress,
                child: const Text('解绑当前小米手环'),
              ),
              const PopupMenuItem(
                value: 'stress_threshold',
                child: Text('设置压力报警阈值'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'esp_prov', child: Text('配网毛绒球呼吸灯')),
              const PopupMenuItem(value: 'esp_reset', child: Text('让毛绒球呼吸灯重新配网')),
              const PopupMenuItem(
                value: 'xiaozhi_prov',
                child: Text('配网星星机器人'),
              ),
              const PopupMenuItem(
                value: 'xiaozhi_reset',
                child: Text('让星星机器人重新配网'),
              ),
              const PopupMenuItem(
                value: 'xiaozhi_bind',
                child: Text('绑定小智设备 (MAC)'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'logout', child: Text('退出登录')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.insights_outlined, color: Colors.white),
            tooltip: '历史足迹',
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (ctx) => FootprintPage(
                    serverIp: widget.serverIp,
                    headers: _apiHeaders(jsonBody: false),
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.auto_stories_outlined, color: Colors.white),
            tooltip: 'AI 周报',
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (ctx) => WeeklyReportPage(
                    serverIp: widget.serverIp,
                    headers: _apiHeaders(jsonBody: false),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isAlertMode
                ? [const Color(0xFFFFF0F0), const Color(0xFFFCE4E4),
                   const Color(0xFFFFF5F5)]
                : [const Color(0xFFF5F7FF), const Color(0xFFEEF0FF),
                   const Color(0xFFF8F9FF)],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                // ── 蓝牙手环连接状态条 ──
                _buildBandStatusBanner(),
                // ── 心率圆环区域 ──
                GestureDetector(
                  onTap: () {
                    if (isAlerting && !isDismissed) {
                      setState(() {
                        isAlerting = false;
                        isDismissed = true;
                        _flowInProgress = true;
                        _rearmSuppressedUntil =
                            DateTime.now().add(_rearmSuppressDuration);
                        _sawNoAlertSinceDismiss = false;
                        vibrationTimer?.cancel();
                        vibrationTimer = null;
                      });
                      _speak("家长已确认");
                    }
                  },
                  child: ScaleTransition(
                    scale: _breathingAnimation,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 600),
                      curve: Curves.easeInOut,
                      width: 180,
                      height: 180,
                      padding: const EdgeInsets.all(36),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: isAlertMode
                              ? [const Color(0xFFFF8A80), const Color(0xFFE53935)]
                              : isDismissed
                                  ? [const Color(0xFF81C784), const Color(0xFF4CAF50)]
                                  : [const Color(0xFF90CAF9), const Color(0xFF42A5F5)],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: isAlertMode
                                ? const Color(0xFFFF5252).withValues(alpha: 0.5)
                                : isDismissed
                                    ? const Color(0xFF4CAF50).withValues(alpha: 0.4)
                                    : const Color(0xFF42A5F5).withValues(alpha: 0.4),
                            blurRadius: 30,
                            spreadRadius: 6,
                          ),
                          BoxShadow(
                            color: isAlertMode
                                ? const Color(0xFFFF5252).withValues(alpha: 0.25)
                                : isDismissed
                                    ? const Color(0xFF4CAF50).withValues(alpha: 0.2)
                                    : const Color(0xFF42A5F5).withValues(alpha: 0.2),
                            blurRadius: 50,
                            spreadRadius: 12,
                          ),
                        ],
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 400),
                        child: Icon(
                          isDismissed
                              ? Icons.check_rounded
                              : isAlerting
                                  ? Icons.warning_rounded
                                  : Icons.favorite_rounded,
                          key: ValueKey(isDismissed || isAlerting),
                          size: 72,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // ── 心率数值 ──
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 400),
                  style: TextStyle(
                    fontSize: 42,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1,
                    color: isAlertMode
                        ? const Color(0xFFD32F2F)
                        : const Color(0xFF303F9F),
                  ),
                  child: Text('$bpm'),
                ),
                const Text(
                  'BPM',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Colors.black38,
                    letterSpacing: 3,
                  ),
                ),
                const SizedBox(height: 8),
                _buildStressChip(),
                const SizedBox(height: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: isAlertMode
                        ? const Color(0xFFFFCDD2).withValues(alpha: 0.7)
                        : isDismissed
                            ? const Color(0xFFC8E6C9).withValues(alpha: 0.7)
                            : const Color(0xFFE8EAF6).withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    isDismissed ? '已确认警报' : message,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: isAlertMode
                          ? const Color(0xFFB71C1C)
                          : isDismissed
                              ? const Color(0xFF2E7D32)
                              : const Color(0xFF283593),
                    ),
                  ),
                ),
                if (isAlerting && !isDismissed)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Text(
                      '点击上方精灵确认报警',
                      style: TextStyle(
                          color: Colors.black38,
                          fontSize: 13,
                          fontWeight: FontWeight.w400),
                    ),
                  ),
                const SizedBox(height: 20),
                _buildAlertActionButtons(),
                _buildAdviceCard(),
                const SizedBox(height: 8),
                // ── 心率趋势图 ──
                _buildChartCard(),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBandStatusBanner() {
    return ValueListenableBuilder<MiBandStatus>(
      valueListenable: _miBandService.status,
      builder: (ctx, s, _) {
        return _BandStatusBanner(
          status: s,
          onRetry: _retryBandConnect,
        );
      },
    );
  }

  Widget _buildDeviceBindingBanner() {
    // 仅在 Mi Band 已连接且有 MAC 时才显示绑定状态
    if (!_miBandService.isStreaming) return const SizedBox.shrink();
    final mac = _miBandService.connectedMacAddress;
    if (mac == null || mac.isEmpty) return const SizedBox.shrink();

    final binding = _deviceBinding;
    final checking = _bindingCheckInProgress;
    final acting = _bindingActionInProgress;

    // 检查中
    if (checking) {
      return _buildBindingCard(
        icon: Icons.sync,
        iconColor: Colors.blueGrey,
        message: '正在检查设备绑定状态…',
        trailing: const SizedBox(
          width: 16, height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (binding == null) {
      return _buildBindingCard(
        icon: Icons.error_outline,
        iconColor: Colors.orange,
        message: '设备 ($mac)\n无法获取绑定信息',
      );
    }

    // 已绑定到当前孩子
    if (binding.isBoundToCurrentChild) {
      return _buildBindingCard(
        icon: Icons.link,
        iconColor: const Color(0xFF2E7D32),
        message: '设备 ($mac) 已绑定到当前孩子',
        trailing: TextButton(
          onPressed: acting ? null : _unbindCurrentDevice,
          child: acting
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('解绑', style: TextStyle(color: Colors.red, fontSize: 12)),
        ),
      );
    }

    // 已绑定到其他孩子 —— 需要先切换到对应孩子才能解绑
    if (binding.isBound) {
      return _buildBindingCard(
        icon: Icons.link_off,
        iconColor: Colors.red,
        message: '设备 ($mac)\n已绑定到「${binding.boundChildNickname ?? "孩子#" + (binding.boundChildId?.toString() ?? "?")}」(ID: ${binding.boundChildId})\n请切换到对应孩子后再解绑',
      );
    }

    // 未绑定
    return _buildBindingCard(
      icon: Icons.bluetooth_connected,
      iconColor: const Color(0xFF1976D2),
      message: '设备 ($mac) 未绑定到任何孩子',
      trailing: FilledButton(
        onPressed: acting ? null : _bindCurrentDevice,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF1976D2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: acting
            ? const SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Text('绑定', style: TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _buildBindingCard({
    required IconData icon,
    required Color iconColor,
    required String message,
    Widget? trailing,
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: Colors.white,
      elevation: 1,
      shadowColor: Colors.black12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontSize: 12, height: 1.3),
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }

  Widget _buildStressChip() {
    final value = stressValue;
    final text = value == null
        ? '压力值：收集中…'
        : '压力值：$value · 阈值 $_stressAlertThreshold';
    final color = value == null
        ? Colors.blueGrey
        : value >= _stressAlertThreshold + 20
            ? Colors.red
            : value >= _stressAlertThreshold
                ? Colors.orange
                : Colors.green;
    final subtitle = value == null
        ? '正在通过心率变化计算压力值（约需 5 秒数据）'
        : '更新时间：${stressUpdatedAt != null ? _formatTime(stressUpdatedAt!) : '--'}\n'
            '压力算法：优先使用手环 stress；拿不到时按心率基线抬升、变异度、上升趋势估算。\n'
            '阈值请从右上角菜单「设置压力报警阈值」调整。';
    return Tooltip(
      message: subtitle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.shade50.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.shade200),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.psychology_alt_outlined,
              size: 16,
              color: color.shade700,
            ),
            const SizedBox(width: 6),
            Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChartCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 3,
        shadowColor: Colors.black26,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 12),
                child: Row(
                  children: [
                    Icon(Icons.show_chart_rounded,
                        size: 20, color: Colors.indigo.shade300),
                    const SizedBox(width: 6),
                    const Text(
                      '心率趋势',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '阈值 ${_alertBpm.toInt()} BPM',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.red.shade300,
                          fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 240,
                width: double.infinity,
                child: LineChart(
                  LineChartData(
                    lineBarsData: [
                      LineChartBarData(
                        spots: chartData,
                        isCurved: true,
                        curveSmoothness: 0.3,
                        color: isAlert
                            ? const Color(0xFFE57373)
                            : const Color(0xFF5C6BC0),
                        barWidth: 3,
                        dotData: FlDotData(
                          show: chartData.length <= 10,
                          getDotPainter: (spot, _, __, ___) =>
                              FlDotCirclePainter(
                            radius: 3,
                            color: isAlert
                                ? const Color(0xFFE57373)
                                : const Color(0xFF5C6BC0),
                            strokeWidth: 1.5,
                            strokeColor: Colors.white,
                          ),
                        ),
                        belowBarData: BarAreaData(
                          show: true,
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              (isAlert
                                      ? const Color(0xFFE57373)
                                      : const Color(0xFF5C6BC0))
                                  .withValues(alpha: 0.3),
                              (isAlert
                                      ? const Color(0xFFE57373)
                                      : const Color(0xFF5C6BC0))
                                  .withValues(alpha: 0.02),
                            ],
                          ),
                        ),
                      ),
                    ],
                    extraLinesData: ExtraLinesData(
                      horizontalLines: [
                        HorizontalLine(
                          y: _alertBpm,
                          color: Colors.red.shade300,
                          strokeWidth: 1.5,
                          dashArray: [8, 4],
                          label: HorizontalLineLabel(
                            show: true,
                            alignment: Alignment.topRight,
                            padding:
                                const EdgeInsets.only(right: 8, bottom: 4),
                            style: TextStyle(
                              color: Colors.red.shade300,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                            labelResolver: (line) => '${line.y.toInt()}',
                          ),
                        ),
                      ],
                    ),
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      horizontalInterval: 25,
                      getDrawingHorizontalLine: (value) {
                        if ((value - _alertBpm).abs() < 0.01) {
                          return const FlLine(
                              color: Colors.transparent, strokeWidth: 0);
                        }
                        return FlLine(
                          color: Colors.grey.withValues(alpha: 0.12),
                          strokeWidth: 1,
                        );
                      },
                    ),
                    minY: 50,
                    maxY: 120,
                    minX: 0,
                    maxX: chartData.isNotEmpty ? chartData.last.x : 0,
                    titlesData: FlTitlesData(
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: chartData.isNotEmpty,
                          reservedSize: 28,
                          interval: _bottomTitleInterval(),
                          getTitlesWidget: (value, meta) {
                            final label = _shortTimeAtX(value);
                            if (label.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                label,
                                style: const TextStyle(
                                    fontSize: 10, color: Colors.black54),
                              ),
                            );
                          },
                        ),
                      ),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 30,
                          interval: 25,
                          getTitlesWidget: (value, meta) {
                            return Text(
                              value.toInt().toString(),
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.black54),
                            );
                          },
                        ),
                      ),
                      topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 报警后家长操作入口卡片
class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: color.withValues(alpha: 0.9))),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.black45)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: color.withValues(alpha: 0.4)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 蓝牙手环连接状态条：常态收为细行，失败/需要操作时展开成卡片
/// 给出操作路径与「重试连接」按钮。
class _BandStatusBanner extends StatelessWidget {
  const _BandStatusBanner({
    required this.status,
    required this.onRetry,
  });

  final MiBandStatus status;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final stage = status.stage;
    final palette = _palette(stage);
    final showHint = stage == MiBandStage.awaitingBroadcast ||
        stage == MiBandStage.notFound ||
        stage == MiBandStage.permissionDenied ||
        stage == MiBandStage.bluetoothOff ||
        stage == MiBandStage.authFailed ||
        stage == MiBandStage.disconnected ||
        stage == MiBandStage.error;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: palette.bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: palette.border),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (status.isWorking)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(palette.fg),
                    ),
                  )
                else
                  Icon(palette.icon, size: 18, color: palette.fg),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _headline(stage),
                    style: TextStyle(
                      color: palette.fg,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (showHint)
                  TextButton(
                    onPressed: () => onRetry(),
                    style: TextButton.styleFrom(
                      foregroundColor: palette.fg,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('重试连接',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
            if (status.message != null && status.message!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                status.message!,
                style: TextStyle(
                    fontSize: 12, color: palette.fg.withValues(alpha: 0.85)),
              ),
            ],
            if (showHint) ...[
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.tips_and_updates_outlined,
                            size: 16, color: palette.fg),
                        const SizedBox(width: 6),
                        Text(
                          '操作建议',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: palette.fg),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _hintBody(stage),
                      style: const TextStyle(
                          fontSize: 12, height: 1.5, color: Colors.black87),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _headline(MiBandStage stage) {
    switch (stage) {
      case MiBandStage.idle:
        return '小米手环：等待启动';
      case MiBandStage.permissionDenied:
        return '小米手环：缺少蓝牙权限';
      case MiBandStage.bluetoothOff:
        return '小米手环：手机蓝牙未开启';
      case MiBandStage.scanning:
        return '小米手环：搜索中…';
      case MiBandStage.notFound:
        return '小米手环：未发现设备';
      case MiBandStage.connecting:
        return '小米手环：建立连接中…';
      case MiBandStage.authenticating:
        return '小米手环：安全握手中…';
      case MiBandStage.authFailed:
        return '小米手环：握手失败';
      case MiBandStage.hrSubscribed:
        return '小米手环：通道就绪，等待心率…';
      case MiBandStage.awaitingBroadcast:
        return '小米手环：未收到心率（请开启「运动心率广播」）';
      case MiBandStage.streaming:
        return '小米手环：已连接，正在接收实时心率';
      case MiBandStage.disconnected:
        return '小米手环：连接已断开';
      case MiBandStage.error:
        return '小米手环：连接异常';
    }
  }

  String _hintBody(MiBandStage stage) {
    switch (stage) {
      case MiBandStage.awaitingBroadcast:
        return '操作路径：打开「小米运动健康」App → 我的 → 点击对应手环设备 → '
            '找到「运动心率广播」并开启。\n'
            '注意：开启此功能会增加手环功耗。\n'
            '如果仍无心率，请确认「小米运动健康」未在后台对该手环保持长连，'
            '同一时间手环只能被一个 App 持有。';
      case MiBandStage.notFound:
        return '请检查：① 手环是否在身边、电量充足；② 手机蓝牙是否开启；'
            '③ 手环是否已被「小米运动健康」绑定（同一时间只能被一个 App 持有，'
            '可在 Mi Fit 里临时退出绑定再试一次）。';
      case MiBandStage.permissionDenied:
        return '请进入系统「设置 → 应用 → ADHD 专注精灵 → 权限」，开启：\n'
            '• 附近的设备 / 蓝牙\n'
            '• 位置信息（Android 11 及以下扫描蓝牙必须）。';
      case MiBandStage.bluetoothOff:
        return '请在手机控制中心或「设置 → 蓝牙」中开启蓝牙后再试。';
      case MiBandStage.authFailed:
        return '安全握手失败。请确认 home_screen.dart 中 _miBand6AuthKey 是这只手环对应的 32 位 Hex Auth Key '
            '（来自小米运动健康抓包或厂商工具，每只手环唯一）。';
      case MiBandStage.disconnected:
        return '点击「重试连接」可重新尝试发现并解锁手环。';
      case MiBandStage.error:
      default:
        return '请重试一次；若问题持续，可重启手机蓝牙、重启「小米运动健康」App 或重启手环。';
    }
  }

  _BandPalette _palette(MiBandStage stage) {
    switch (stage) {
      case MiBandStage.streaming:
        return _BandPalette(
          bg: const Color(0xFFE8F5E9),
          border: const Color(0xFFA5D6A7),
          fg: const Color(0xFF2E7D32),
          icon: Icons.bluetooth_connected,
        );
      case MiBandStage.scanning:
      case MiBandStage.connecting:
      case MiBandStage.authenticating:
      case MiBandStage.hrSubscribed:
        return _BandPalette(
          bg: const Color(0xFFE3F2FD),
          border: const Color(0xFF90CAF9),
          fg: const Color(0xFF1565C0),
          icon: Icons.bluetooth_searching,
        );
      case MiBandStage.awaitingBroadcast:
        return _BandPalette(
          bg: const Color(0xFFFFF3E0),
          border: const Color(0xFFFFB74D),
          fg: const Color(0xFFE65100),
          icon: Icons.warning_amber_rounded,
        );
      case MiBandStage.permissionDenied:
      case MiBandStage.bluetoothOff:
      case MiBandStage.notFound:
      case MiBandStage.authFailed:
      case MiBandStage.disconnected:
      case MiBandStage.error:
        return _BandPalette(
          bg: const Color(0xFFFFEBEE),
          border: const Color(0xFFEF9A9A),
          fg: const Color(0xFFC62828),
          icon: Icons.error_outline,
        );
      case MiBandStage.idle:
        return _BandPalette(
          bg: const Color(0xFFF5F5F5),
          border: const Color(0xFFE0E0E0),
          fg: const Color(0xFF616161),
          icon: Icons.bluetooth,
        );
    }
  }
}

class _BandPalette {
  const _BandPalette({
    required this.bg,
    required this.border,
    required this.fg,
    required this.icon,
  });

  final Color bg;
  final Color border;
  final Color fg;
  final IconData icon;
}
