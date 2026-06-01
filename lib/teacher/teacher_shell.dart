import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

import '../theme/app_theme.dart';
import '../models/heart_rate_data.dart';
import '../services/miband_service.dart';
import 'teacher_ble_service.dart';
import 'teacher_local_store.dart';
import 'teacher_models.dart';

String teacherAlertEventLabel(String eventType) {
  switch (eventType) {
    case 'rapidRiseHeartRate':
      return '心率短时骤升';
    case 'lowHeartRate':
      return '心率持续偏低';
    case 'highHeartRate':
    default:
      return '心率持续偏高';
  }
}

/// 手环 2A46 短句用状态词（与 [teacherAlertEventLabel] 区分，尽量短）。
String teacherBandAlertShortStatus(String eventType) {
  switch (eventType) {
    case 'rapidRiseHeartRate':
      return '心率骤升';
    case 'lowHeartRate':
      return '心率偏低';
    case 'highHeartRate':
    default:
      return '心率偏高';
  }
}

String teacherStudentThresholdSummary(TeacherStudent student) {
  return '自动提醒线：过高 >${student.thresholdBpm} / 过低 <${student.lowThresholdBpm} 次/分钟';
}

const String teacherRapidRiseRuleSummary = '额外规则：5 分钟内较基线升高 30% 也会提醒';

class TeacherShell extends StatefulWidget {
  const TeacherShell({super.key, required this.onSwitchMode});

  final VoidCallback onSwitchMode;

  @override
  State<TeacherShell> createState() => _TeacherShellState();
}

class _TeacherShellState extends State<TeacherShell> {
  static const int _maxStudents = 3;
  static const Duration _cooldown = Duration(seconds: 90);
  static const Duration _rapidRiseWindow = Duration(minutes: 5);
  static const List<String> _genderOptions = <String>['男', '女', '其他', '不便说明'];

  final TeacherBleService _bleService = TeacherBleService();
  List<TeacherStudent> _students = const <TeacherStudent>[];
  List<TeacherAlertEvent> _events = const <TeacherAlertEvent>[];
  TeacherBandBinding? _teacherBand;
  bool _loading = true;
  bool _monitoring = false;
  bool _monitorBusy = false;
  bool _teacherBindingBusy = false;
  bool _teacherVibrationBusy = false;
  Color? _teacherBandVibrationTestColor;
  String? _teacherBandMessage;
  MiBandStatus? _teacherBandStatus;
  String? _teacherBandLastFailure;
  final Map<String, MiBand6Auth> _studentClients = <String, MiBand6Auth>{};
  final Map<String, StreamSubscription<HeartRateSample>> _studentHrSubs =
      <String, StreamSubscription<HeartRateSample>>{};
  final Map<String, MiBandStatus> _studentBandStatuses = <String, MiBandStatus>{};
  final Map<String, String> _studentBandLastFailures = <String, String>{};
  final Map<String, VoidCallback> _studentStatusListeners = <String, VoidCallback>{};
  VoidCallback? _teacherStatusListener;
  MiBand6Auth? _teacherBandClient;

  final Map<String, int> _bpmByStudent = <String, int>{};
  final Map<String, int> _highSampleCount = <String, int>{};
  final Map<String, int> _lowSampleCount = <String, int>{};
  final Map<String, List<_HeartRateSnapshot>> _recentHeartRateHistory =
      <String, List<_HeartRateSnapshot>>{};
  final Map<String, DateTime> _lastAlertAt = <String, DateTime>{};
  final Set<String> _alertingStudents = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  @override
  void dispose() {
    unawaited(_shutdownAllBandConnections(fromDispose: true));
    super.dispose();
  }

  Future<void> _restore() async {
    final students = await TeacherLocalStore.getStudents();
    final teacherBand = await TeacherLocalStore.getTeacherBand();
    final events = await TeacherLocalStore.getAlertEvents();
    if (!mounted) return;
    setState(() {
      _students = students;
      _teacherBand = teacherBand;
      _events = events;
      if (teacherBand != null) {
        _teacherBandStatus = const MiBandStatus(
          MiBandStage.idle,
          message: '老师手环信息已保存，等待开始连接。',
        );
        _teacherBandLastFailure = null;
      }
      for (final student in students) {
        if ((student.bandRemoteId ?? '').isNotEmpty) {
          _studentBandStatuses[student.id] = const MiBandStatus(
            MiBandStage.idle,
            message: '学生手环信息已保存，等待开始连接。',
          );
        }
      }
      _loading = false;
    });
  }

  Future<void> _persistStudents(List<TeacherStudent> students) async {
    await TeacherLocalStore.saveStudents(students);
    if (!mounted) return;
    setState(() => _students = students);
  }

  Future<void> _addStudent() async {
    if (_students.length >= _maxStudents) {
      _showSnack('当前版本最多同时监测 3 名学生');
      return;
    }

    final result = await _showStudentDialog();
    if (result == null) return;

    final student = TeacherStudent(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: result.name,
      nickname: result.nickname,
      age: result.age,
      gender: result.gender,
      personality: result.personality,
      interests: result.interests,
      category: result.category,
      note: result.note,
      thresholdBpm: result.thresholdBpm,
      lowThresholdBpm: result.lowThresholdBpm,
      createdAt: DateTime.now(),
    );
    await _persistStudents(<TeacherStudent>[..._students, student]);
  }

  Future<void> _editStudent(TeacherStudent student) async {
    final result = await _showStudentDialog(student: student);
    if (result == null) return;

    final next = _students
        .map(
          (item) => item.id == student.id
              ? item.copyWith(
                  name: result.name,
                  nickname: result.nickname,
                  age: result.age,
                  gender: result.gender,
                  personality: result.personality,
                  interests: result.interests,
                  category: result.category,
                  note: result.note,
                  thresholdBpm: result.thresholdBpm,
                  lowThresholdBpm: result.lowThresholdBpm,
                )
              : item,
        )
        .toList();
    await _persistStudents(next);
  }

  Future<void> _removeStudent(TeacherStudent student) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除学生？'),
        content: Text('移除后，${student.name} 的本地绑定会一起清除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    _bpmByStudent.remove(student.id);
    _highSampleCount.remove(student.id);
    _lowSampleCount.remove(student.id);
    _recentHeartRateHistory.remove(student.id);
    _alertingStudents.remove(student.id);
    _lastAlertAt.remove(student.id);
    await _disposeStudentClient(student.id);
    await _persistStudents(
      _students.where((item) => item.id != student.id).toList(),
    );
  }

  Future<void> _toggleStudentEnabled(TeacherStudent student) async {
    if (student.enabled) {
      await _disposeStudentClient(student.id);
      _bpmByStudent.remove(student.id);
      _highSampleCount.remove(student.id);
      _lowSampleCount.remove(student.id);
      _recentHeartRateHistory.remove(student.id);
      _alertingStudents.remove(student.id);
      _lastAlertAt.remove(student.id);
      _studentBandStatuses[student.id] = const MiBandStatus(
        MiBandStage.disconnected,
        message: '该学生已暂停监测。',
      );
    }
    final next = _students
        .map((item) => item.id == student.id
            ? item.copyWith(enabled: !item.enabled)
            : item)
        .toList();
    await _persistStudents(next);
  }

  Future<void> _bindStudentBand(TeacherStudent student) async {
    _showSnack('正在搜索附近可绑定的小米手环 6...');
    final selected = await _pickNearbyBand(title: '选择 ${student.name} 的手环');
    if (selected == null) return;

    final duplicate = _students.any(
      (item) => item.id != student.id && item.bandRemoteId == selected.remoteId,
    );
    if (duplicate || _teacherBand?.remoteId == selected.remoteId) {
      _showSnack('这只手环已经绑定给其他人了，请换一只再试。');
      return;
    }

    if (mounted) {
      setState(() {
        _studentBandStatuses[student.id] = const MiBandStatus(
          MiBandStage.idle,
          message: '已扫描到学生手环，等待填写连接密钥。',
        );
      });
    }

    final authKey = await _showAuthKeyDialog(
      title: '填写 ${student.name} 手环的连接密钥',
      initialValue: student.bandAuthHexKey,
    );
    if (authKey == null) return;

    _showSnack('正在验证 ${student.name} 的手环连接...');
    final result = await _bleService.connectBand(
      remoteId: selected.remoteId,
      authHexKey: authKey,
      localAlertBpm: student.thresholdBpm,
    );
    if (!result.success || result.client == null) {
      if (mounted) {
        setState(() {
          _studentBandStatuses[student.id] = result.status ??
              MiBandStatus(MiBandStage.error, message: result.message);
          _studentBandLastFailures[student.id] = result.message;
        });
      }
      _showSnack(result.message);
      return;
    }

    await result.client!.dispose();

    final next = _students
        .map((item) => item.id == student.id
        ? item.copyWith(
            bandRemoteId: selected.remoteId,
            bandDisplayName: selected.name,
            bandAuthHexKey: authKey,
          )
            : item)
        .toList();
    await _persistStudents(next);
    if (mounted) {
      setState(() {
        _studentBandStatuses[student.id] = const MiBandStatus(
          MiBandStage.idle,
          message: '学生手环已验证通过，等待开始监测。',
        );
        _studentBandLastFailures.remove(student.id);
      });
    }
    _showSnack('${student.name} 的手环已完成绑定验证，可以开始接收真实心率了。');
  }

  Future<void> _bindTeacherBand() async {
    if (_teacherBindingBusy) return;
    _teacherBindingBusy = true;
    if (mounted) setState(() {});
    try {
      _showSnack('正在搜索附近可绑定的老师手环...');
      final selected = await _pickNearbyBand(title: '选择老师手环');
      if (selected == null) return;

      final duplicateStudent = _students.any((item) => item.bandRemoteId == selected.remoteId);
      if (duplicateStudent) {
        _showSnack('这只手环已经绑定给学生了，请换一只再试。');
        return;
      }

      if (mounted) {
        setState(() {
          _teacherBandStatus = const MiBandStatus(
            MiBandStage.idle,
            message: '已扫描到老师手环，等待填写连接密钥。',
          );
        });
      }

      final authKey = await _showAuthKeyDialog(
        title: '填写老师手环的连接密钥',
        initialValue: _teacherBand?.authHexKey,
      );
      if (authKey == null) return;

      _showSnack('正在验证老师手环连接...');
      final result = await _bleService.connectBand(
        remoteId: selected.remoteId,
        authHexKey: authKey,
      );
      if (!result.success || result.client == null) {
        if (mounted) {
          setState(() {
            _teacherBandStatus = result.status ??
                MiBandStatus(MiBandStage.error, message: result.message);
            _teacherBandLastFailure = result.message;
          });
        }
        _showSnack(result.message);
        return;
      }

      await _disposeTeacherClient();
      _attachTeacherClient(result.client!);

      final binding = TeacherBandBinding(
        remoteId: selected.remoteId,
        displayName: result.connectedName ?? selected.name,
        authHexKey: authKey,
        vibrationVerified: false,
        boundAt: DateTime.now(),
      );
      await TeacherLocalStore.saveTeacherBand(binding);
      if (!mounted) return;
      setState(() {
        _teacherBand = binding;
        _teacherBandMessage = '已连接 ${binding.displayName ?? '老师手环'}，接下来请完成震动测试。';
        _teacherBandStatus = _teacherBandClient?.status.value ?? _teacherBandStatus;
        _teacherBandLastFailure = null;
      });
      _showSnack('老师手环已真实连接并保存，可以继续测试震动。');
    } finally {
      _teacherBindingBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<bool> _confirmBandVibration(String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('老师手环震动了吗？'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('没有'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('震动了'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _verifyTeacherVibration() async {
    final binding = _teacherBand;
    if (binding == null) {
      _showSnack('请先绑定老师手环');
      return;
    }

    if (_teacherVibrationBusy) {
      _showSnack('老师手环测试还在进行，请稍等结束后再试。');
      return;
    }

    if ((binding.authHexKey ?? '').isEmpty) {
      _showSnack('老师手环还没有填写连接密钥，请重新绑定一次。');
      return;
    }

    _teacherVibrationBusy = true;
    if (mounted) setState(() {});
    try {
      if (_teacherBandClient == null || !_teacherBandClient!.status.value.isConnected) {
        final connectResult = await _bleService.connectBand(
          remoteId: binding.remoteId,
          authHexKey: binding.authHexKey!,
        );
        if (!connectResult.success || connectResult.client == null) {
          if (mounted) {
            setState(() {
              _teacherBandStatus = connectResult.status ??
                  MiBandStatus(MiBandStage.error, message: connectResult.message);
              _teacherBandLastFailure = connectResult.message;
            });
          }
          _showSnack(connectResult.message);
          return;
        }
        await _disposeTeacherClient();
        _attachTeacherClient(connectResult.client!);
      }

      final client = _teacherBandClient!;
      final nameLabel = (binding.displayName?.trim().isNotEmpty ?? false)
          ? binding.displayName!.trim()
          : '老师';

      _showSnack('正在运行红屏/绿屏与手环震动测试，请稍候…');

      var paused = false;
      var phasesOk = false;
      try {
        paused = await client.pauseHeartRateReceptionForTest();
        if (!paused) {
          if (mounted) {
            _showSnack('无法暂停心率接收，测试已取消。');
          }
          return;
        }

        if (!mounted) return;
        setState(() => _teacherBandVibrationTestColor = const Color(0xFFE84B4B));
        final redOk = await client.vibrateBandForTest(
          times: 3,
          newAlertMessage: '$nameLabel 红屏测试',
        );
        if (!redOk) {
          throw StateError('手环未响应「查找设备」命令（私有协议可能未握手成功）。');
        }

        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        setState(() => _teacherBandVibrationTestColor = const Color(0xFF47B276));
        final greenOk = await client.vibrateBandForTest(
          times: 3,
          newAlertMessage: '$nameLabel 绿屏测试',
        );
        if (!greenOk) {
          throw StateError('第二轮震动失败，请确认手环仍在附近并保持连接。');
        }
        phasesOk = true;
        if (mounted) {
          _showSnack('红绿屏与震动测试完成，已断开蓝牙，方便官方 App 重新连接。');
        }
      } catch (e) {
        if (mounted) {
          final s = e.toString();
          _showSnack(
            (s.contains('SocketException') ||
                    s.contains('Connection refused') ||
                    s.contains('Failed host lookup') ||
                    s.contains('TimeoutException'))
                ? '手环测试没有完成，请确认网络和蓝牙状态后再试'
                : '手环测试暂时没有成功，请确认手环靠近手机后再试',
          );
        }
      } finally {
        if (paused) {
          await client.disconnect();
        }
        if (mounted) {
          setState(() => _teacherBandVibrationTestColor = null);
        }
      }

      if (!phasesOk || !mounted) return;

      final confirmed = await _confirmBandVibration(
        '屏幕会先泛红再泛绿，手环在每段是否各震动三次？若均已感受到，请点「震动了」。',
      );
      if (!confirmed) {
        _showSnack('这次没有确认到手环震动，请靠近手机后再试。');
        return;
      }

      final verified = binding.copyWith(vibrationVerified: true);
      await TeacherLocalStore.saveTeacherBand(verified);
      if (!mounted) return;
      setState(() {
        _teacherBand = verified;
        _teacherBandMessage = '老师手环震动测试已通过，告警时会优先提醒手环。';
        _teacherBandStatus = _teacherBandClient?.status.value ?? _teacherBandStatus;
        _teacherBandLastFailure = null;
      });
      _showSnack('老师手环震动测试通过，绑定已经生效。');
    } finally {
      _teacherVibrationBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _toggleMonitoring() async {
    if (_monitoring) {
      await _stopMonitoring();
      return;
    }

    if (_teacherVibrationBusy) {
      _showSnack('老师手环测试还没结束，请稍等后再开始监测。');
      return;
    }

    if (_students.where((student) => student.enabled).isEmpty) {
      _showSnack('请先添加学生');
      return;
    }

    final readyStudents = _students.where((student) => student.enabled).toList();
    final missingBindings = readyStudents
        .where((student) => (student.bandRemoteId ?? '').isEmpty || (student.bandAuthHexKey ?? '').isEmpty)
        .map((student) => student.name)
        .toList();
    if (missingBindings.isNotEmpty) {
      _showSnack('请先完成这些学生的真实手环绑定：${missingBindings.join('、')}');
      return;
    }

    _monitorBusy = true;
    if (mounted) setState(() {});
    final connected = <String>[];
    final failed = <String>[];
    try {
      for (final student in readyStudents) {
        final ok = await _ensureStudentMonitoring(student);
        if (ok) {
          connected.add(student.name);
        } else {
          failed.add(student.name);
        }
      }

      if (!mounted) return;
      setState(() => _monitoring = connected.isNotEmpty);

      if (connected.isEmpty) {
        _showSnack('这次没有连上任何学生手环，请靠近后重试。');
      } else if (failed.isEmpty) {
        _showSnack('已开始真实监测：${connected.join('、')}');
      } else {
        _showSnack('已开始监测 ${connected.join('、')}；${failed.join('、')} 暂未连接成功。');
      }
    } finally {
      _monitorBusy = false;
      if (mounted) setState(() {});
    }
  }

  void _handleStudentHeartRate(TeacherStudent student, int bpm) {
    if (!mounted || !_monitoring) return;
    final now = DateTime.now();

    _bpmByStudent[student.id] = bpm;
    final rapidRiseBaseline = _recordRecentHeartRate(student.id, bpm, now);
    final lastAlert = _lastAlertAt[student.id];
    final canAlert = lastAlert == null || now.difference(lastAlert) > _cooldown;
    if (bpm >= student.thresholdBpm) {
      final count = (_highSampleCount[student.id] ?? 0) + 1;
      _highSampleCount[student.id] = count;
      _lowSampleCount[student.id] = 0;
      if (count >= 2 && canAlert) {
        _alertingStudents.add(student.id);
        _lastAlertAt[student.id] = now;
        unawaited(
          _triggerAlert(
            student,
            bpm,
            eventType: 'highHeartRate',
            thresholdBpm: student.thresholdBpm,
            note: '课堂监测中，心率持续高于年龄对应提醒线。',
          ),
        );
      }
    } else if (bpm <= student.lowThresholdBpm) {
      final count = (_lowSampleCount[student.id] ?? 0) + 1;
      _lowSampleCount[student.id] = count;
      _highSampleCount[student.id] = 0;
      if (count >= 2 && canAlert) {
        _alertingStudents.add(student.id);
        _lastAlertAt[student.id] = now;
        unawaited(
          _triggerAlert(
            student,
            bpm,
            eventType: 'lowHeartRate',
            thresholdBpm: student.lowThresholdBpm,
            note: '课堂监测中，心率持续低于年龄对应提醒线。',
          ),
        );
      }
    } else if (rapidRiseBaseline != null && bpm >= (rapidRiseBaseline * 1.3).ceil()) {
      _highSampleCount[student.id] = 0;
      _lowSampleCount[student.id] = 0;
      if (canAlert) {
        _alertingStudents.add(student.id);
        _lastAlertAt[student.id] = now;
        unawaited(
          _triggerAlert(
            student,
            bpm,
            eventType: 'rapidRiseHeartRate',
            thresholdBpm: (rapidRiseBaseline * 1.3).ceil(),
            note: '课堂监测中，5 分钟内较基线升高超过 30%。',
          ),
        );
      }
    } else {
      _highSampleCount[student.id] = 0;
      _lowSampleCount[student.id] = 0;
      _alertingStudents.remove(student.id);
    }

    setState(() {});
  }

  Future<void> _triggerAlert(
    TeacherStudent student,
    int bpm, {
    required String eventType,
    required int thresholdBpm,
    required String note,
  }) async {
    final teacherBandReady = _teacherBand?.vibrationVerified == true;
    if (teacherBandReady && _teacherBand != null && (_teacherBand!.authHexKey ?? '').isNotEmpty) {
      unawaited(_vibrateTeacherBandForAlert(student, eventType));
    }
    await _phoneFallbackAlert();
    final alertLabel = teacherAlertEventLabel(eventType);
    final event = TeacherAlertEvent(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      studentId: student.id,
      studentNameSnapshot: student.name,
      eventType: eventType,
      bpm: bpm,
      thresholdBpm: thresholdBpm,
      startedAt: DateTime.now(),
      note: note,
    );
    await TeacherLocalStore.addAlertEvent(event);
    final events = await TeacherLocalStore.getAlertEvents();
    if (!mounted) return;
    setState(() => _events = events);

    _showSnack(
      teacherBandReady
          ? '${student.name}$alertLabel，已提醒老师手环'
          : '${student.name}$alertLabel，已先用手机提醒',
    );
  }

  Future<void> _phoneFallbackAlert() async {
    try {
      final hasVibrator = await Vibration.hasVibrator() ?? false;
      if (hasVibrator) {
        await Vibration.vibrate(pattern: const <int>[0, 300, 120, 300]);
      }
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {}
  }

  Future<void> _showEvents() async {
    final events = await TeacherLocalStore.getAlertEvents();
    if (!mounted) return;
    setState(() => _events = events);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          const Text(
            '本地提醒记录',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (events.isEmpty)
            const Text('还没有提醒记录。'),
          for (final event in events)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.notifications_active_outlined),
              title: Text(event.studentNameSnapshot),
              subtitle: Text(
                '${teacherAlertEventLabel(event.eventType)} · ${event.bpm ?? '--'} 次/分钟 / 提醒线 ${event.thresholdBpm ?? '--'}\n${event.startedAt}${(event.note?.isNotEmpty ?? false) ? '\n${event.note}' : ''}',
              ),
            ),
        ],
      ),
    );
  }

  Future<_StudentDialogResult?> _showStudentDialog({TeacherStudent? student}) async {
    final nameController = TextEditingController(text: student?.name ?? '');
    final nicknameController = TextEditingController(text: student?.nickname ?? '');
    final ageController = TextEditingController(text: student?.age?.toString() ?? '');
    final personalityController = TextEditingController(text: student?.personality ?? '');
    final interestsController = TextEditingController(text: student?.interests ?? '');
    final categoryController = TextEditingController(text: student?.category ?? '');
    final noteController = TextEditingController(text: student?.note ?? '');
    var selectedGender = (student?.gender?.trim().isNotEmpty ?? false)
      ? student!.gender!.trim()
      : null;

    final result = await showDialog<_StudentDialogResult>(
      context: context,
      builder: (ctx) {
        String? errorText;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final age = int.tryParse(ageController.text.trim());
            final thresholds = teacherHeartRateThresholdsForAge(age);
            return AlertDialog(
              title: Text(student == null ? '添加学生' : '编辑学生'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: '学生姓名'),
                      textInputAction: TextInputAction.next,
                    ),
                    TextField(
                      controller: nicknameController,
                      decoration: const InputDecoration(labelText: '小名，可选'),
                      textInputAction: TextInputAction.next,
                    ),
                    TextField(
                      controller: ageController,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setDialogState(() => errorText = null),
                      decoration: const InputDecoration(labelText: '年龄'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedGender,
                      decoration: const InputDecoration(labelText: '性别，可选'),
                      items: _genderOptions
                          .map(
                            (item) => DropdownMenuItem<String>(
                              value: item,
                              child: Text(item),
                            ),
                          )
                          .toList(),
                      onChanged: (value) => setDialogState(() => selectedGender = value),
                    ),
                    TextField(
                      controller: categoryController,
                      decoration: const InputDecoration(
                        labelText: '类别',
                        hintText: '如已诊断多动症、自闭症、发育迟缓等',
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                    TextField(
                      controller: personalityController,
                      decoration: const InputDecoration(labelText: '性格，可选'),
                      textInputAction: TextInputAction.next,
                    ),
                    TextField(
                      controller: interestsController,
                      decoration: const InputDecoration(labelText: '兴趣爱好，可选'),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '自动提醒线',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: AppColors.ink,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text('${thresholds.ageBandLabel} · ${thresholds.normalRangeLabel}'),
                          const SizedBox(height: 4),
                          Text('过高提醒：>${thresholds.high} 次/分钟'),
                          Text('过低提醒：<${thresholds.low} 次/分钟'),
                        ],
                      ),
                    ),
                    TextField(
                      controller: noteController,
                      decoration: const InputDecoration(labelText: '补充说明，可选'),
                      maxLines: 2,
                    ),
                    if (errorText != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        errorText!,
                        style: const TextStyle(color: AppColors.coral),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    final name = nameController.text.trim();
                    final ageValue = int.tryParse(ageController.text.trim());
                    if (name.isEmpty) {
                      setDialogState(() => errorText = '请先填写学生姓名。');
                      return;
                    }
                    if (ageValue == null || ageValue < 0) {
                      setDialogState(() => errorText = '请填写正确的年龄，系统会按年龄自动配置提醒线。');
                      return;
                    }
                    final nextThresholds = teacherHeartRateThresholdsForAge(ageValue);
                    Navigator.pop(
                      ctx,
                      _StudentDialogResult(
                        name: name,
                        nickname: nicknameController.text.trim(),
                        age: ageValue,
                        gender: selectedGender?.trim() ?? '',
                        personality: personalityController.text.trim(),
                        interests: interestsController.text.trim(),
                        category: categoryController.text.trim(),
                        note: noteController.text.trim(),
                        thresholdBpm: nextThresholds.high,
                        lowThresholdBpm: nextThresholds.low,
                      ),
                    );
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );

    nameController.dispose();
    nicknameController.dispose();
    ageController.dispose();
    personalityController.dispose();
    interestsController.dispose();
    categoryController.dispose();
    noteController.dispose();
    return result;
  }

  int? _recordRecentHeartRate(String studentId, int bpm, DateTime now) {
    final history = _recentHeartRateHistory.putIfAbsent(
      studentId,
      () => <_HeartRateSnapshot>[],
    );
    history.add(_HeartRateSnapshot(recordedAt: now, bpm: bpm));
    history.removeWhere(
      (sample) => now.difference(sample.recordedAt) > _rapidRiseWindow,
    );
    if (history.length < 2) return null;
    final baseline = history.first;
    if (now.difference(baseline.recordedAt) < const Duration(minutes: 1)) {
      return null;
    }
    return baseline.bpm;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<TeacherBandScanResult?> _pickNearbyBand({required String title}) async {
    final results = await _bleService.scanMiBand6();
    if (!mounted) return null;
    if (results.isEmpty) {
      _showSnack('没有发现附近的小米手环 6，请靠近后再试。');
      return null;
    }

    return showDialog<TeacherBandScanResult>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: results.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (ctx, index) {
              final item = results[index];
              return ListTile(
                title: Text(item.name),
                subtitle: Text('设备编号 ${item.remoteId} · 附近程度 ${item.rssi}'),
                onTap: () => Navigator.pop(ctx, item),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<String?> _showAuthKeyDialog({
    required String title,
    String? initialValue,
  }) async {
    final controller = TextEditingController(
      text: _formatAuthKeyForDisplay(initialValue ?? ''),
    );
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String? errorText;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final normalized = _normalizeAuthKeyDraft(controller.text);
            final grouped = _formatAuthKeyForDisplay(normalized);
            return AlertDialog(
              title: Text(title),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    autocorrect: false,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F\s]')),
                    ],
                    onChanged: (_) {
                      setDialogState(() {
                        errorText = null;
                      });
                    },
                    decoration: InputDecoration(
                      labelText: '手环连接密钥（32 位）',
                      helperText: '只需输入字母和数字，空格会自动忽略。',
                      errorText: errorText,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    grouped.isEmpty
                        ? '格式预览：---- ---- ---- ---- ---- ---- ---- ----'
                        : '格式预览：$grouped',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      color: AppColors.muted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '已输入 ${normalized.length}/32 位',
                    style: const TextStyle(color: AppColors.muted),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    final validation = _validateAuthKeyDraft(controller.text);
                    if (validation != null) {
                      setDialogState(() {
                        errorText = validation;
                      });
                      return;
                    }
                    Navigator.pop(ctx, _normalizeAuthKeyDraft(controller.text));
                  },
                  child: const Text('继续'),
                ),
              ],
            );
          },
        );
      },
    );
    controller.dispose();
    return value;
  }

  String _normalizeAuthKeyDraft(String input) {
    return input.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  }

  String _formatAuthKeyForDisplay(String input) {
    final normalized = _normalizeAuthKeyDraft(input).toUpperCase();
    final buffer = StringBuffer();
    for (var i = 0; i < normalized.length; i++) {
      if (i > 0 && i % 4 == 0) buffer.write(' ');
      buffer.write(normalized[i]);
    }
    return buffer.toString();
  }

  String? _validateAuthKeyDraft(String input) {
    final normalized = _normalizeAuthKeyDraft(input);
    if (normalized.isEmpty) {
      return '请输入 32 位连接密钥。';
    }
    final invalidIndex = normalized.split('').indexWhere(
          (char) => !RegExp(r'[0-9a-f]').hasMatch(char),
        );
    if (invalidIndex >= 0) {
      return '第 ${invalidIndex + 1} 位不是有效的十六进制字符。';
    }
    if (normalized.length < 32) {
      return '还差 ${32 - normalized.length} 位，请继续补全。';
    }
    if (normalized.length > 32) {
      return '当前多输入了 ${normalized.length - 32} 位，请删除后再试。';
    }
    return null;
  }

  Future<bool> _ensureStudentMonitoring(TeacherStudent student) async {
    final remoteId = student.bandRemoteId;
    final authKey = student.bandAuthHexKey;
    if (remoteId == null || remoteId.isEmpty || authKey == null || authKey.isEmpty) {
      return false;
    }

    final existing = _studentClients[student.id];
    if (existing != null && existing.status.value.isConnected) {
      return true;
    }

    await _disposeStudentClient(student.id);
    final result = await _bleService.connectBand(
      remoteId: remoteId,
      authHexKey: authKey,
      localAlertBpm: student.thresholdBpm,
    );
    if (!result.success || result.client == null) {
      if (mounted) {
        setState(() {
          _studentBandStatuses[student.id] = result.status ??
              MiBandStatus(MiBandStage.error, message: result.message);
        });
      }
      return false;
    }

    final client = result.client!;
    _attachStudentClient(student.id, client);
    _studentHrSubs[student.id] = client.bpmStream.listen(
      (sample) => _handleStudentHeartRate(student, sample.bpm),
    );
    return true;
  }

  Future<void> _disposeStudentClient(String studentId) async {
    await _studentHrSubs.remove(studentId)?.cancel();
    final client = _studentClients.remove(studentId);
    final listener = _studentStatusListeners.remove(studentId);
    if (client != null && listener != null) {
      client.status.removeListener(listener);
    }
    if (client != null) {
      await client.dispose();
    }
    _highSampleCount.remove(studentId);
    _lowSampleCount.remove(studentId);
    _recentHeartRateHistory.remove(studentId);
    _alertingStudents.remove(studentId);
    if (mounted && _students.any((student) => student.id == studentId && (student.bandRemoteId ?? '').isNotEmpty)) {
      setState(() {
        _studentBandStatuses[studentId] = const MiBandStatus(
          MiBandStage.disconnected,
          message: '连接已断开，等待再次开始监测。',
        );
      });
    }
  }

  Future<void> _stopMonitoring({bool showFeedback = true}) async {
    for (final studentId in _studentClients.keys.toList()) {
      await _disposeStudentClient(studentId);
    }
    if (!mounted) return;
    setState(() {
      _monitoring = false;
      _bpmByStudent.clear();
      _highSampleCount.clear();
      _lowSampleCount.clear();
      _recentHeartRateHistory.clear();
      _alertingStudents.clear();
      _lastAlertAt.clear();
    });
    if (showFeedback) {
      _showSnack('已停止教师端监测。');
    }
  }

  Future<void> _shutdownAllBandConnections({bool fromDispose = false}) async {
    if (fromDispose) {
      for (final studentId in _studentClients.keys.toList()) {
        await _disposeStudentClient(studentId);
      }
      await _disposeTeacherClient();
      await _bleService.dispose();
      return;
    }
    await _stopMonitoring(showFeedback: false);
    await _disposeTeacherClient();
    await _bleService.dispose();
  }

  Future<void> _vibrateTeacherBandForAlert(
    TeacherStudent student,
    String eventType,
  ) async {
    final binding = _teacherBand;
    if (binding == null || (binding.authHexKey ?? '').isEmpty) return;

    if (_teacherBandClient == null || !_teacherBandClient!.status.value.isConnected) {
      final result = await _bleService.connectBand(
        remoteId: binding.remoteId,
        authHexKey: binding.authHexKey!,
      );
      if (!result.success || result.client == null) return;
      await _disposeTeacherClient();
      _attachTeacherClient(result.client!);
    }
    await _bleService.vibrateAlertBand(
      _teacherBandClient!,
      newAlertMessage:
          '${student.name} ${teacherBandAlertShortStatus(eventType)}',
    );
  }

  _BandDiagnosticViewData _buildTeacherDiagnostic() {
    return _describeBandDiagnostic(
      title: '老师手环',
      displayName: _teacherBand?.displayName,
      hasBinding: _teacherBand != null,
      status: _teacherBandStatus,
      lastFailureReason: _teacherBandLastFailure,
      verified: _teacherBand?.vibrationVerified == true,
    );
  }

  _BandDiagnosticViewData _buildStudentDiagnostic(TeacherStudent student) {
    return _describeBandDiagnostic(
      title: student.name,
      displayName: student.bandDisplayName ?? student.bandRemoteId,
      hasBinding: (student.bandRemoteId ?? '').isNotEmpty,
      status: _studentBandStatuses[student.id],
      currentBpm: _bpmByStudent[student.id],
      lastFailureReason: _studentBandLastFailures[student.id],
      verified: (student.bandAuthHexKey ?? '').isNotEmpty,
    );
  }

  _BandDiagnosticViewData _describeBandDiagnostic({
    required String title,
    required bool hasBinding,
    required MiBandStatus? status,
    String? displayName,
    int? currentBpm,
    String? lastFailureReason,
    bool verified = false,
  }) {
    if (!hasBinding) {
      return _BandDiagnosticViewData(
        title: title,
        stateLabel: '未绑定',
        detail: '还没有选择手环和连接密钥。',
        lastSampleText: '最近一次心率时间：暂无',
        lastFailureText: '最近一次失败原因：暂无',
        color: AppColors.muted,
        icon: Icons.link_off_rounded,
      );
    }

    final lastSampleText = status?.lastSampleAt == null
        ? '最近一次心率时间：暂无'
        : '最近一次心率时间：${_formatDiagnosticTime(status!.lastSampleAt!)}';
    final lastFailureText = (lastFailureReason == null || lastFailureReason.isEmpty)
        ? '最近一次失败原因：暂无'
        : '最近一次失败原因：$lastFailureReason';

    if (status == null || status.stage == MiBandStage.idle) {
      return _BandDiagnosticViewData(
        title: title,
        stateLabel: '已扫描',
        detail: status?.message ?? '${displayName ?? '手环'} 已保存，等待开始连接。',
        lastSampleText: lastSampleText,
        lastFailureText: lastFailureText,
        color: AppColors.teal,
        icon: Icons.bluetooth_searching_rounded,
      );
    }

    final message = status.message ?? '${displayName ?? '手环'} 当前状态已更新。';
    switch (status.stage) {
      case MiBandStage.permissionDenied:
        return _BandDiagnosticViewData(
          title: title,
          stateLabel: '权限不足',
          detail: message,
          lastSampleText: lastSampleText,
          lastFailureText: lastFailureText,
          color: AppColors.warning,
          icon: Icons.lock_outline_rounded,
        );
      case MiBandStage.bluetoothOff:
        return _BandDiagnosticViewData(
          title: title,
          stateLabel: '蓝牙未开启',
          detail: message,
          lastSampleText: lastSampleText,
          lastFailureText: lastFailureText,
          color: AppColors.warning,
          icon: Icons.bluetooth_disabled_rounded,
        );
      case MiBandStage.scanning:
        return _BandDiagnosticViewData(
          title: title,
          stateLabel: '搜索中',
          detail: message,
          lastSampleText: lastSampleText,
          lastFailureText: lastFailureText,
          color: AppColors.teal,
          icon: Icons.radar_rounded,
        );
      case MiBandStage.notFound:
        return _BandDiagnosticViewData(
          title: title,
          stateLabel: '未找到',
          detail: message,
          lastSampleText: lastSampleText,
          lastFailureText: lastFailureText,
          color: AppColors.warning,
          icon: Icons.search_off_rounded,
        );
      case MiBandStage.connecting:
      case MiBandStage.authenticating:
        return _BandDiagnosticViewData(
          title: title,
          stateLabel: '连接中',
          detail: message,
          lastSampleText: lastSampleText,
          lastFailureText: lastFailureText,
          color: AppColors.teal,
          icon: Icons.sync_rounded,
        );
      case MiBandStage.authFailed:
        return _BandDiagnosticViewData(
          title: title,
          stateLabel: '密钥错误',
          detail: message,
          lastSampleText: lastSampleText,
          lastFailureText: lastFailureText,
          color: AppColors.coral,
          icon: Icons.key_off_rounded,
        );
      case MiBandStage.hrSubscribed:
        return _BandDiagnosticViewData(
          title: title,
          stateLabel: '已连接',
          detail: currentBpm == null ? message : '已连上手环，最新心率 $currentBpm 次/分钟。',
          lastSampleText: lastSampleText,
          lastFailureText: lastFailureText,
          color: verified ? AppColors.sage : AppColors.teal,
          icon: Icons.bluetooth_connected_rounded,
        );
      case MiBandStage.awaitingBroadcast:
        return _BandDiagnosticViewData(
          title: title,
          stateLabel: '等待心率广播',
          detail: message,
          lastSampleText: lastSampleText,
          lastFailureText: lastFailureText,
          color: AppColors.warning,
          icon: Icons.monitor_heart_outlined,
        );
      case MiBandStage.streaming:
        return _BandDiagnosticViewData(
          title: title,
          stateLabel: '已连接',
          detail: currentBpm == null ? '正在接收实时心率。' : '最新心率 $currentBpm 次/分钟。',
          lastSampleText: lastSampleText,
          lastFailureText: lastFailureText,
          color: verified ? AppColors.sage : AppColors.teal,
          icon: Icons.favorite_rounded,
        );
      case MiBandStage.disconnected:
        return _BandDiagnosticViewData(
          title: title,
          stateLabel: '连接断开',
          detail: message,
          lastSampleText: lastSampleText,
          lastFailureText: lastFailureText,
          color: AppColors.warning,
          icon: Icons.portable_wifi_off_rounded,
        );
      case MiBandStage.error:
        final isKeyIssue = message.contains('密钥') || message.contains('校验');
        return _BandDiagnosticViewData(
          title: title,
          stateLabel: isKeyIssue ? '密钥错误' : '连接异常',
          detail: message,
          lastSampleText: lastSampleText,
          lastFailureText: lastFailureText,
          color: AppColors.coral,
          icon: isKeyIssue ? Icons.key_off_rounded : Icons.error_outline_rounded,
        );
      case MiBandStage.idle:
        return _BandDiagnosticViewData(
          title: title,
          stateLabel: '已扫描',
          detail: message,
          lastSampleText: lastSampleText,
          lastFailureText: lastFailureText,
          color: AppColors.teal,
          icon: Icons.bluetooth_searching_rounded,
        );
    }
  }

  String _formatDiagnosticTime(DateTime time) {
    final value = time.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.month)}-${two(value.day)} ${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
  }

  Widget _buildConnectionDiagnosticPanel() {
    final diagnostics = <_BandDiagnosticViewData>[
      _buildTeacherDiagnostic(),
      ..._students.map(_buildStudentDiagnostic),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '连接诊断',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          const Text(
            '这里会显示每只手环当前是否已扫描、已连接、等待心率广播，或连接密钥是否有误。',
            style: TextStyle(color: AppColors.muted, height: 1.4),
          ),
          const SizedBox(height: 12),
          for (final item in diagnostics) ...[
            _BandDiagnosticTile(item: item),
            if (item != diagnostics.last) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  void _attachTeacherClient(MiBand6Auth client) {
    _teacherBandClient = client;
    _teacherBandStatus = client.status.value;
    final listener = () {
      if (!mounted) return;
      final status = client.status.value;
      setState(() {
        _teacherBandStatus = status;
        if (status.isFailure && (status.message?.isNotEmpty ?? false)) {
          _teacherBandLastFailure = status.message;
        } else if (status.isConnected || status.stage == MiBandStage.streaming) {
          _teacherBandLastFailure = null;
        }
      });
    };
    _teacherStatusListener = listener;
    client.status.addListener(listener);
  }

  Future<void> _disposeTeacherClient() async {
    final client = _teacherBandClient;
    final listener = _teacherStatusListener;
    if (client != null && listener != null) {
      client.status.removeListener(listener);
    }
    _teacherStatusListener = null;
    _teacherBandClient = null;
    if (client != null) {
      await client.dispose();
    }
  }

  void _attachStudentClient(String studentId, MiBand6Auth client) {
    _studentClients[studentId] = client;
    _studentBandStatuses[studentId] = client.status.value;
    final listener = () {
      if (!mounted) return;
      final status = client.status.value;
      setState(() {
        _studentBandStatuses[studentId] = status;
        if (status.isFailure && (status.message?.isNotEmpty ?? false)) {
          _studentBandLastFailures[studentId] = status.message!;
        } else if (status.isConnected || status.stage == MiBandStage.streaming) {
          _studentBandLastFailures.remove(studentId);
        }
      });
    };
    _studentStatusListeners[studentId] = listener;
    client.status.addListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final teacherReady = _teacherBand?.vibrationVerified == true;
    final activeStudents = _students.where((student) => student.enabled).length;
    final bandTestColor = _teacherBandVibrationTestColor;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: const Text('教师课堂监测'),
        backgroundColor: AppColors.canvas,
        foregroundColor: AppColors.ink,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            height: 1,
            color: bandTestColor != null
                ? bandTestColor.withValues(alpha: 0.75)
                : AppColors.border,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '本地提醒记录',
            onPressed: _showEvents,
            icon: const Icon(Icons.history_rounded),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'mode') widget.onSwitchMode();
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: 'mode', child: Text('切换使用身份')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addStudent,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('添加学生'),
      ),
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: bandTestColor != null
                ? [
                    bandTestColor.withValues(alpha: 0.92),
                    bandTestColor.withValues(alpha: 0.68),
                  ]
                : const [AppColors.canvas, AppColors.canvasAlt],
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
          _StatusPanel(
            teacherReady: teacherReady,
            studentCount: activeStudents,
            monitoring: _monitoring,
            busy: _monitorBusy || _teacherBindingBusy || _teacherVibrationBusy,
            teacherBandName: _teacherBand?.displayName,
            teacherBandMessage: _teacherBandMessage,
            onBindTeacherBand: _bindTeacherBand,
            onVerifyVibration: _verifyTeacherVibration,
            onToggleMonitoring: _toggleMonitoring,
          ),
          const SizedBox(height: 12),
          _buildConnectionDiagnosticPanel(),
          const SizedBox(height: 12),
          if (_students.isEmpty)
            const _EmptyTeacherState(),
          for (final student in _students) ...[
            _StudentCard(
              student: student,
              bpm: _bpmByStudent[student.id],
              alerting: _alertingStudents.contains(student.id),
              monitoring: _monitoring,
              onEdit: () => _editStudent(student),
              onBindBand: () => _bindStudentBand(student),
              onToggleEnabled: () => _toggleStudentEnabled(student),
              onRemove: () => _removeStudent(student),
            ),
            const SizedBox(height: 10),
          ],
          ],
        ),
      ),
    );
  }
}

class _StudentDialogResult {
  const _StudentDialogResult({
    required this.name,
    required this.nickname,
    required this.age,
    required this.gender,
    required this.personality,
    required this.interests,
    required this.category,
    required this.note,
    required this.thresholdBpm,
    required this.lowThresholdBpm,
  });

  final String name;
  final String nickname;
  final int age;
  final String gender;
  final String personality;
  final String interests;
  final String category;
  final String note;
  final int thresholdBpm;
  final int lowThresholdBpm;
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.teacherReady,
    required this.studentCount,
    required this.monitoring,
    required this.busy,
    required this.teacherBandName,
    required this.teacherBandMessage,
    required this.onBindTeacherBand,
    required this.onVerifyVibration,
    required this.onToggleMonitoring,
  });

  final bool teacherReady;
  final int studentCount;
  final bool monitoring;
  final bool busy;
  final String? teacherBandName;
  final String? teacherBandMessage;
  final VoidCallback onBindTeacherBand;
  final VoidCallback onVerifyVibration;
  final Future<void> Function() onToggleMonitoring;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '课堂工作台',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              _StatusBadge(
                text: monitoring ? '监测中' : '未开始',
                color: monitoring ? AppColors.sage : AppColors.muted,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            teacherBandName == null
              ? '先绑定老师手环，再完成震动测试，课堂告警会更及时。'
              : teacherBandMessage ??
                (teacherReady
                  ? '老师手环已完成震动测试，正式监测可用。'
                  : '老师手环已经连好，还差一次震动确认。'),
            style: const TextStyle(
              color: AppColors.muted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusBadge(
                text: teacherBandName == null
                    ? '老师手环未绑定'
                    : (teacherReady ? '老师手环已验证' : '老师手环待测试'),
                color: teacherReady ? AppColors.sage : AppColors.warning,
              ),
              _StatusBadge(
                text: '学生 $studentCount / 3',
                color: AppColors.teal,
              ),
            ],
          ),
          if (teacherBandName != null) ...[
            const SizedBox(height: 10),
            Text('当前老师手环：$teacherBandName', style: const TextStyle(color: AppColors.ink)),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : onBindTeacherBand,
                icon: const Icon(Icons.watch_rounded),
                label: const Text('绑定老师手环'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : onVerifyVibration,
                icon: const Icon(Icons.vibration_rounded),
                label: const Text('测试震动/红绿屏'),
              ),
              FilledButton.icon(
                onPressed: busy ? null : () => onToggleMonitoring(),
                icon: Icon(monitoring ? Icons.pause_rounded : Icons.play_arrow_rounded),
                label: Text(monitoring ? '暂停监测' : '开始监测'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _BandDiagnosticTile extends StatelessWidget {
  const _BandDiagnosticTile({required this.item});

  final _BandDiagnosticViewData item;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: item.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: item.color.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: item.color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(item.icon, color: item.color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppColors.ink,
                        ),
                      ),
                    ),
                    _StatusBadge(text: item.stateLabel, color: item.color),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  item.detail,
                  style: const TextStyle(color: AppColors.muted, height: 1.35),
                ),
                const SizedBox(height: 6),
                Text(
                  item.lastSampleText,
                  style: const TextStyle(color: AppColors.muted, height: 1.3),
                ),
                const SizedBox(height: 2),
                Text(
                  item.lastFailureText,
                  style: const TextStyle(color: AppColors.muted, height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BandDiagnosticViewData {
  const _BandDiagnosticViewData({
    required this.title,
    required this.stateLabel,
    required this.detail,
    required this.lastSampleText,
    required this.lastFailureText,
    required this.color,
    required this.icon,
  });

  final String title;
  final String stateLabel;
  final String detail;
  final String lastSampleText;
  final String lastFailureText;
  final Color color;
  final IconData icon;
}

class _StudentCard extends StatelessWidget {
  const _StudentCard({
    required this.student,
    required this.bpm,
    required this.alerting,
    required this.monitoring,
    required this.onEdit,
    required this.onBindBand,
    required this.onToggleEnabled,
    required this.onRemove,
  });

  final TeacherStudent student;
  final int? bpm;
  final bool alerting;
  final bool monitoring;
  final VoidCallback onEdit;
  final VoidCallback onBindBand;
  final VoidCallback onToggleEnabled;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final hasBand = student.bandRemoteId != null && student.bandRemoteId!.isNotEmpty;
    final profileBits = <String>[
      if ((student.nickname ?? '').trim().isNotEmpty) '小名 ${student.nickname!.trim()}',
      if (student.age != null) '${student.age} 岁',
      if ((student.gender ?? '').trim().isNotEmpty) student.gender!.trim(),
      if ((student.category ?? '').trim().isNotEmpty) student.category!.trim(),
    ];
    final statusText = !student.enabled
        ? '已暂停监测'
        : !hasBand
            ? '还未绑定手环'
        : !monitoring
          ? '已绑定完成，等待开始监测'
          : bpm == null
            ? '正在连接手环并等待心率'
            : alerting
                ? '心率已连续异常，请留意'
          : '实时监测中';
    final bandLabel = student.bandDisplayName?.trim().isNotEmpty == true
      ? student.bandDisplayName!
      : student.bandRemoteId;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: alerting ? const Color(0xFFFFF0EA) : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: alerting ? AppColors.coral : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: alerting ? AppColors.coral : AppColors.sage,
                child: Text(
                  student.name.characters.first,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      student.name,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                    if (profileBits.isNotEmpty)
                      Text(
                        profileBits.join(' · '),
                        style: const TextStyle(height: 1.3, color: AppColors.muted),
                      ),
                    Text(statusText, style: const TextStyle(height: 1.35, color: AppColors.muted)),
                  ],
                ),
              ),
              Text(
                bpm == null ? '--' : '$bpm',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: alerting ? AppColors.coral : AppColors.ink,
                ),
              ),
              const SizedBox(width: 4),
              const Text('次/分钟'),
            ],
          ),
          const SizedBox(height: 10),
          Text(teacherStudentThresholdSummary(student)),
          const Text(teacherRapidRiseRuleSummary),
          if ((student.personality ?? '').trim().isNotEmpty)
            Text('性格：${student.personality!.trim()}'),
          if ((student.interests ?? '').trim().isNotEmpty)
            Text('兴趣爱好：${student.interests!.trim()}'),
          if ((student.note ?? '').trim().isNotEmpty)
            Text('补充说明：${student.note!.trim()}'),
          if (hasBand) Text('学生手环：$bandLabel'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              TextButton(onPressed: onBindBand, child: Text(hasBand ? '更换手环' : '绑定手环')),
              TextButton(onPressed: onEdit, child: const Text('编辑')),
              TextButton(onPressed: onToggleEnabled, child: Text(student.enabled ? '暂停' : '启用')),
              TextButton(onPressed: onRemove, child: const Text('移除')),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyTeacherState extends StatelessWidget {
  const _EmptyTeacherState();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: const Column(
        children: [
          Icon(Icons.groups_rounded, size: 42, color: AppColors.sage),
          SizedBox(height: 8),
          Text(
            '先添加学生，再为每名学生绑定一只小米手环 6。',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _HeartRateSnapshot {
  const _HeartRateSnapshot({required this.recordedAt, required this.bpm});

  final DateTime recordedAt;
  final int bpm;
}
