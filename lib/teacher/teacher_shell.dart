import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

import '../theme/app_theme.dart';
import 'teacher_ble_service.dart';
import 'teacher_local_store.dart';
import 'teacher_models.dart';

class TeacherShell extends StatefulWidget {
  const TeacherShell({super.key, required this.onSwitchMode});

  final VoidCallback onSwitchMode;

  @override
  State<TeacherShell> createState() => _TeacherShellState();
}

class _TeacherShellState extends State<TeacherShell> {
  static const int _maxStudents = 3;
  static const int _defaultThreshold = 120;
  static const Duration _cooldown = Duration(seconds: 90);

  final Random _random = Random();
  final TeacherBleService _bleService = TeacherBleService();
  List<TeacherStudent> _students = const <TeacherStudent>[];
  List<TeacherAlertEvent> _events = const <TeacherAlertEvent>[];
  TeacherBandBinding? _teacherBand;
  bool _loading = true;
  bool _monitoring = false;
  Timer? _monitorTimer;

  final Map<String, int> _bpmByStudent = <String, int>{};
  final Map<String, int> _highSampleCount = <String, int>{};
  final Map<String, DateTime> _lastAlertAt = <String, DateTime>{};
  final Set<String> _alertingStudents = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  @override
  void dispose() {
    _monitorTimer?.cancel();
    unawaited(_bleService.dispose());
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
      note: result.note,
      thresholdBpm: result.thresholdBpm,
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
                  note: result.note,
                  thresholdBpm: result.thresholdBpm,
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
    _alertingStudents.remove(student.id);
    await _persistStudents(
      _students.where((item) => item.id != student.id).toList(),
    );
  }

  Future<void> _toggleStudentEnabled(TeacherStudent student) async {
    final next = _students
        .map((item) => item.id == student.id
            ? item.copyWith(enabled: !item.enabled)
            : item)
        .toList();
    await _persistStudents(next);
  }

  Future<void> _bindStudentBand(TeacherStudent student) async {
    final controller = TextEditingController(
      text: student.bandRemoteId ?? 'MI-BAND-${student.name}',
    );
    final remoteId = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('绑定 ${student.name} 的手环'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: '手环标识',
            helperText: '真实蓝牙扫描接入前，可先用本地标识占位',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (remoteId == null || remoteId.isEmpty) return;

    final duplicate = _students.any(
      (item) => item.id != student.id && item.bandRemoteId == remoteId,
    );
    if (duplicate) {
      _showSnack('这只手环已经绑定给其他学生了');
      return;
    }

    final next = _students
        .map((item) => item.id == student.id
            ? item.copyWith(bandRemoteId: remoteId)
            : item)
        .toList();
    await _persistStudents(next);
  }

  Future<void> _bindTeacherBand() async {
    _showSnack('正在搜索附近的小米手环 6...');
    final results = await _bleService.scanMiBand6();
    if (!mounted) return;
    if (results.isEmpty) {
      _showSnack('没有发现附近的小米手环 6，请靠近后再试');
      return;
    }

    final selected = await showDialog<TeacherBandScanResult>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择老师手环'),
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
                subtitle: Text('${item.remoteId} · 信号 ${item.rssi}'),
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
    if (selected == null) return;

    final binding = TeacherBandBinding(
      remoteId: selected.remoteId,
      displayName: selected.name,
      vibrationVerified: false,
      boundAt: DateTime.now(),
    );
    await TeacherLocalStore.saveTeacherBand(binding);
    if (!mounted) return;
    setState(() => _teacherBand = binding);
    _showSnack('老师手环已保存，请继续测试震动');
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

    _showSnack('正在连接老师手环并发送震动指令...');
    final result = await _bleService.vibrateTeacherBand(binding.remoteId);
    if (!mounted) return;
    if (!result.success) {
      await _phoneFallbackAlert();
      _showSnack(result.message);
      return;
    }

    final ok = await _confirmBandVibration(result.message);
    if (!ok) {
      _showSnack('老师手环还没有确认震动成功');
      return;
    }

    final verified = binding.copyWith(vibrationVerified: true);
    await TeacherLocalStore.saveTeacherBand(verified);
    if (!mounted) return;
    setState(() => _teacherBand = verified);
  }

  void _toggleMonitoring() {
    if (_monitoring) {
      _monitorTimer?.cancel();
      setState(() => _monitoring = false);
      return;
    }

    if (_students.where((student) => student.enabled).isEmpty) {
      _showSnack('请先添加学生');
      return;
    }
    if (_teacherBand?.vibrationVerified != true) {
      _showSnack('老师手环还没有完成震动测试，已先进入试运行');
    }

    _monitorTimer?.cancel();
    _monitorTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _tickSimulation(),
    );
    setState(() => _monitoring = true);
    _tickSimulation();
  }

  void _tickSimulation() {
    if (!mounted) return;
    final now = DateTime.now();
    final nextBpm = <String, int>{..._bpmByStudent};
    final nextAlerting = <String>{..._alertingStudents};

    for (final student in _students) {
      if (!student.enabled || student.bandRemoteId == null) continue;
      final base = 78 + _random.nextInt(24);
      final spike = _random.nextInt(100) > 68 ? 35 + _random.nextInt(24) : 0;
      final bpm = base + spike;
      nextBpm[student.id] = bpm;

      if (bpm >= student.thresholdBpm) {
        final count = (_highSampleCount[student.id] ?? 0) + 1;
        _highSampleCount[student.id] = count;
        final lastAlert = _lastAlertAt[student.id];
        final canAlert = lastAlert == null || now.difference(lastAlert) > _cooldown;
        if (count >= 2 && canAlert) {
          nextAlerting.add(student.id);
          _lastAlertAt[student.id] = now;
          unawaited(_triggerAlert(student, bpm));
        }
      } else {
        _highSampleCount[student.id] = 0;
        nextAlerting.remove(student.id);
      }
    }

    setState(() {
      _bpmByStudent
        ..clear()
        ..addAll(nextBpm);
      _alertingStudents
        ..clear()
        ..addAll(nextAlerting);
    });
  }

  Future<void> _triggerAlert(TeacherStudent student, int bpm) async {
    final teacherBandReady = _teacherBand?.vibrationVerified == true;
    if (teacherBandReady) {
      unawaited(_bleService.vibrateTeacherBand(_teacherBand!.remoteId));
    }
    await _phoneFallbackAlert();
    final event = TeacherAlertEvent(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      studentId: student.id,
      studentNameSnapshot: student.name,
      eventType: 'highHeartRate',
      bpm: bpm,
      thresholdBpm: student.thresholdBpm,
      startedAt: DateTime.now(),
      note: '课堂监测中，心率持续偏高。',
    );
    await TeacherLocalStore.addAlertEvent(event);
    final events = await TeacherLocalStore.getAlertEvents();
    if (!mounted) return;
    setState(() => _events = events);

    _showSnack(
      teacherBandReady
          ? '${student.name} 心率持续偏高，已提醒老师手环'
          : '${student.name} 心率持续偏高，已先用手机提醒',
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
                '${event.bpm ?? '--'} BPM / 阈值 ${event.thresholdBpm ?? '--'}\n${event.startedAt}',
              ),
            ),
        ],
      ),
    );
  }

  Future<_StudentDialogResult?> _showStudentDialog({TeacherStudent? student}) async {
    final nameController = TextEditingController(text: student?.name ?? '');
    final noteController = TextEditingController(text: student?.note ?? '');
    final thresholdController = TextEditingController(
      text: '${student?.thresholdBpm ?? _defaultThreshold}',
    );

    final result = await showDialog<_StudentDialogResult>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(student == null ? '添加学生' : '编辑学生'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '学生姓名'),
                textInputAction: TextInputAction.next,
              ),
              TextField(
                controller: thresholdController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '提醒阈值 BPM'),
              ),
              TextField(
                controller: noteController,
                decoration: const InputDecoration(labelText: '备注，可选'),
              ),
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
              final threshold = int.tryParse(thresholdController.text.trim()) ??
                  _defaultThreshold;
              if (name.isEmpty) return;
              Navigator.pop(
                ctx,
                _StudentDialogResult(
                  name: name,
                  note: noteController.text.trim(),
                  thresholdBpm: threshold.clamp(80, 180).toInt(),
                ),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );

    nameController.dispose();
    noteController.dispose();
    thresholdController.dispose();
    return result;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final teacherReady = _teacherBand?.vibrationVerified == true;
    final activeStudents = _students.where((student) => student.enabled).length;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: const Text('教师课堂监测'),
        backgroundColor: AppColors.canvas,
        foregroundColor: AppColors.ink,
        elevation: 0,
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
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          _StatusPanel(
            teacherReady: teacherReady,
            studentCount: activeStudents,
            monitoring: _monitoring,
            onBindTeacherBand: _bindTeacherBand,
            onVerifyVibration: _verifyTeacherVibration,
            onToggleMonitoring: _toggleMonitoring,
          ),
          const SizedBox(height: 12),
          if (_students.isEmpty)
            const _EmptyTeacherState(),
          for (final student in _students) ...[
            _StudentCard(
              student: student,
              bpm: _bpmByStudent[student.id],
              alerting: _alertingStudents.contains(student.id),
              onEdit: () => _editStudent(student),
              onBindBand: () => _bindStudentBand(student),
              onToggleEnabled: () => _toggleStudentEnabled(student),
              onRemove: () => _removeStudent(student),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _StudentDialogResult {
  const _StudentDialogResult({
    required this.name,
    required this.note,
    required this.thresholdBpm,
  });

  final String name;
  final String note;
  final int thresholdBpm;
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.teacherReady,
    required this.studentCount,
    required this.monitoring,
    required this.onBindTeacherBand,
    required this.onVerifyVibration,
    required this.onToggleMonitoring,
  });

  final bool teacherReady;
  final int studentCount;
  final bool monitoring;
  final VoidCallback onBindTeacherBand;
  final VoidCallback onVerifyVibration;
  final VoidCallback onToggleMonitoring;

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
            teacherReady
                ? '老师手环已完成震动测试，正式监测可用。'
                : '老师手环还未完成震动测试，可先用手机提醒试运行。',
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
                text: teacherReady ? '老师手环已验证' : '老师手环待测试',
                color: teacherReady ? AppColors.sage : AppColors.warning,
              ),
              _StatusBadge(
                text: '学生 $studentCount / 3',
                color: AppColors.teal,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onBindTeacherBand,
                icon: const Icon(Icons.watch_rounded),
                label: const Text('绑定老师手环'),
              ),
              OutlinedButton.icon(
                onPressed: onVerifyVibration,
                icon: const Icon(Icons.vibration_rounded),
                label: const Text('测试震动'),
              ),
              FilledButton.icon(
                onPressed: onToggleMonitoring,
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

class _StudentCard extends StatelessWidget {
  const _StudentCard({
    required this.student,
    required this.bpm,
    required this.alerting,
    required this.onEdit,
    required this.onBindBand,
    required this.onToggleEnabled,
    required this.onRemove,
  });

  final TeacherStudent student;
  final int? bpm;
  final bool alerting;
  final VoidCallback onEdit;
  final VoidCallback onBindBand;
  final VoidCallback onToggleEnabled;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final hasBand = student.bandRemoteId != null && student.bandRemoteId!.isNotEmpty;
    final statusText = !student.enabled
        ? '已暂停监测'
        : !hasBand
            ? '还未绑定手环'
            : alerting
                ? '心率持续偏高，请留意'
                : '平稳监测中';

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
              const Text('BPM'),
            ],
          ),
          const SizedBox(height: 10),
          Text('提醒阈值：${student.thresholdBpm} BPM'),
          if (hasBand) Text('学生手环：${student.bandRemoteId}'),
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
