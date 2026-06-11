import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/autism_training_session.dart';
import '../models/child_condition.dart';
import '../models/parent_child_profile.dart';
import '../services/cloud_service.dart';
import '../services/parent_child_profile_store.dart';
import '../theme/app_theme.dart';
import '../widgets/parent_child_profile_dialog.dart';
import 'child_skill_page.dart';
import 'esp_provision_page.dart';
import 'footprint_page.dart';
import 'weekly_report_page.dart';
import '../services/esp_provision_service.dart' show EspProvKind;

class _TrainingScenePreset {
  const _TrainingScenePreset({
    required this.sceneId,
    required this.title,
    required this.subtitle,
    required this.goal,
    required this.startButton,
    required this.ttsIntro,
    required this.options,
    required this.flow,
    this.parameters = const [],
  });

  final String sceneId;
  final String title;
  final String subtitle;
  final String goal;
  final String startButton;
  final String ttsIntro;
  final List<String> options;
  final List<String> flow;
  final List<String> parameters;
}

const List<_TrainingScenePreset> _trainingScenePresets = [
  _TrainingScenePreset(
    sceneId: AutismTrainingSceneIds.emotionExpression,
    title: '表达情绪',
    subtitle: '识别并表达当前情绪',
    goal: '让孩子通过图片说出自己现在的感受，并获得即时正向反馈。',
    startButton: '开始情绪训练',
    ttsIntro: '你现在感觉怎么样？',
    options: ['开心', '难过', '生气', '害怕'],
    flow: [
      '机器人询问“你现在感觉怎么样？”并显示情绪图片。',
      '孩子摇晃切换、拍打选择一个情绪。',
      '机器人复述选择并表扬，毛绒球用绿色呼吸光强化。',
      '家长手机记录本次情绪识别结果。',
    ],
  ),
  _TrainingScenePreset(
    sceneId: AutismTrainingSceneIds.needExpression,
    title: '表达需求',
    subtitle: '用图片表达生理需求',
    goal: '让孩子能通过机器人清楚表达喝水、吃饭、上厕所等基本需求。',
    startButton: '开始需求训练',
    ttsIntro: '你需要什么？',
    options: ['喝水', '吃东西', '上厕所', '休息'],
    flow: [
      '机器人说“你需要什么？”并显示需求图片，毛绒球蓝色慢闪。',
      '孩子摇晃切换、拍打确认需求。',
      '机器人说“你想……，好的，我告诉妈妈”，屏幕显示已发送。',
      '手机震动并弹出孩子需求，随后机器人播放表扬语。',
    ],
    parameters: ['进阶：家长可根据实际执行情况再做确认记录。'],
  ),
  _TrainingScenePreset(
    sceneId: AutismTrainingSceneIds.socialResponse,
    title: '社交回应',
    subtitle: '练习问候和简单对话',
    goal: '训练孩子回应他人的问候和基本社交问题，为真人互动打基础。',
    startButton: '开始社交回应训练',
    ttsIntro: '你好！我是你的朋友。今天过得怎么样？',
    options: ['很好', '不太好', '开心', '不知道'],
    flow: [
      '机器人发起问候，毛绒球黄色呼吸光。',
      '孩子选择回应，例如“很好”。',
      '机器人确认并继续追问“你做了什么事情让你开心呀？”',
      '孩子再次选择后，机器人总结并感谢孩子表达。',
    ],
    parameters: ['简单：二选一', '中等：四选一情绪图片', '困难：开放式回答'],
  ),
  _TrainingScenePreset(
    sceneId: AutismTrainingSceneIds.preferenceChoice,
    title: '偏好选择',
    subtitle: '在多个选项中做选择',
    goal: '帮助孩子在日常情境中做出选择并表达自己的偏好。',
    startButton: '开始选择训练',
    ttsIntro: '我们来选一个活动吧！你想选哪一个？',
    options: ['积木', '画画', '饼干', '苹果'],
    flow: [
      '家长预设 2 到 4 个选项并下发。',
      '机器人语音引导并显示选项图片，毛绒球蓝色慢闪。',
      '孩子摇晃切换高亮、拍打选择。',
      '机器人确认选择并鼓励孩子执行。',
    ],
    parameters: ['选项数量：2 / 3 / 4 个', '选项内容：家长可自定义', '可扩展：是否追问“为什么选这个？”'],
  ),
  _TrainingScenePreset(
    sceneId: AutismTrainingSceneIds.helpRequest,
    title: '寻求帮助',
    subtitle: '遇到困难时主动求助',
    goal: '让孩子在够不到、打不开、不会做等情境中通过机器人寻求帮助。',
    startButton: '开始求助训练',
    ttsIntro: '你需要帮忙吗？',
    options: ['需要帮忙', '不需要', '打开盒子', '拿高处的东西'],
    flow: [
      '家长创建模拟困境，例如把零食放在稍高处。',
      '机器人询问是否需要帮忙，屏幕显示“需要 / 不需要”。',
      '孩子选择“需要”后，机器人告诉妈妈。',
      '家长帮助完成后，机器人表扬孩子主动求助。',
    ],
    parameters: ['高级：等待孩子主动摇晃触发', '追问：打开盒子 / 拿高处的东西 / 系鞋带 / 其他'],
  ),
];

class _TrainingSceneDraft {
  _TrainingSceneDraft(_TrainingScenePreset preset)
      : sceneId = preset.sceneId,
        title = preset.title,
        ttsIntro = preset.ttsIntro,
        options = List<String>.from(preset.options);

  final String sceneId;
  final String title;
  String ttsIntro;
  List<String> options;

  Map<String, dynamic> toJson() {
    return {
      'scene_id': sceneId,
      'title': title,
      'tts_intro': ttsIntro.trim(),
      'options': options.where((s) => s.trim().isNotEmpty).toList(),
    };
  }
}

class _DailyPlanPreset {
  const _DailyPlanPreset({
    required this.time,
    required this.tts,
    required this.options,
  });

  final String time;
  final String tts;
  final List<String> options;
}

const List<_DailyPlanPreset> _dailyPlanPresets = [
  _DailyPlanPreset(
    time: '07:00',
    tts: '早上7点，起床啦，你喜欢穿什么颜色的鞋子？',
    options: ['红色鞋子', '蓝色鞋子'],
  ),
  _DailyPlanPreset(
    time: '11:00',
    tts: '中午11点，该吃中饭啦，你想吃什么？',
    options: ['米饭', '面条', '饺子'],
  ),
  _DailyPlanPreset(
    time: '13:00',
    tts: '下午1点，该午睡咯',
    options: ['好的', '不好'],
  ),
  _DailyPlanPreset(
    time: '14:00',
    tts: '下午2点，该起床咯，起床后你想玩什么',
    options: ['搭积木', '滑梯', '拍皮球'],
  ),
  _DailyPlanPreset(
    time: '18:00',
    tts: '晚上6点，到了吃晚饭的时候啦，你喜欢吃什么菜',
    options: ['青菜', '胡萝卜', '肉'],
  ),
];

const List<String> _dailyPlanTimeChoices = [
  '06:00',
  '06:30',
  '07:00',
  '07:30',
  '08:00',
  '10:30',
  '11:00',
  '11:30',
  '12:00',
  '13:00',
  '13:30',
  '14:00',
  '14:30',
  '17:30',
  '18:00',
  '18:30',
  '19:00',
  '20:00',
];

class _DailyPlanRowEdit {
  _DailyPlanRowEdit(_DailyPlanPreset preset)
      : time = preset.time,
        ttsCtrl = TextEditingController(text: preset.tts),
        optionCtrls = List.generate(
          3,
          (i) => TextEditingController(
            text: i < preset.options.length ? preset.options[i] : '',
          ),
        );

  String time;
  final TextEditingController ttsCtrl;
  final List<TextEditingController> optionCtrls;

  Map<String, dynamic> toJson() {
    return {
      'time': time,
      'tts': ttsCtrl.text.trim(),
      'options': optionCtrls
          .map((c) => c.text.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
    };
  }

  void dispose() {
    ttsCtrl.dispose();
    for (final c in optionCtrls) {
      c.dispose();
    }
  }
}

/// 孤独症模式家长壳：裁剪顶栏与菜单，三块主入口 + 足迹 / AI 报告。
class AutismFamilyShell extends StatefulWidget {
  const AutismFamilyShell({
    super.key,
    required this.serverIp,
    this.authToken,
    required this.activeChildId,
    this.onLogout,
    this.onSwitchChild,
    this.onSwitchMode,
    this.onChildCategoryChanged,
  });

  final String serverIp;
  final String? authToken;
  final int activeChildId;
  final VoidCallback? onLogout;
  final void Function(int childId)? onSwitchChild;
  final VoidCallback? onSwitchMode;
  final void Function(ChildCondition condition)? onChildCategoryChanged;

  @override
  State<AutismFamilyShell> createState() => _AutismFamilyShellState();
}

class _AutismFamilyShellState extends State<AutismFamilyShell> {
  late final CloudService _cloud;
  int _section = 0;
  List<Map<String, dynamic>> _pendingNeeds = const [];
  bool _loadingNeeds = false;
  Timer? _needsPollTimer;
  final Set<int> _lastPolledNeedIds = {};
  bool _needsPollPrimed = false;
  String? _childJustChoseBanner;
  DateTime? _needsLastSyncedAt;
  bool _needsPollInFlight = false;
  Timer? _trainingEventsPollTimer;
  int _lastTrainingEventId = 0;
  bool _trainingEventsPrimed = false;
  bool _trainingEventsInFlight = false;
  String? _trainingEventBanner;

  int? _trainingSessionId;
  AutismTrainingPhase _trainingPhase = AutismTrainingPhase.parentSetup;
  Timer? _pollTimer;
  String _lastSessionState = '';
  int _trainingSceneIndex = 0;
  bool _loadingTrainingDraft = false;
  bool _trainingPreparingImages = false;
  bool _trainingImagesReady = false;
  Timer? _trainingAssetCheckTimer;
  String _trainingImageStatus = '正在检查云端是否已有当前场景图片…';
  Map<String, Map<String, String?>> _preparedTrainingImages = const {};
  final List<_TrainingSceneDraft> _trainingDrafts = _trainingScenePresets
      .map(_TrainingSceneDraft.new)
      .toList();
  final List<TextEditingController> _optionCtrls = List.generate(
    4,
    (_) => TextEditingController(),
  );
  final TextEditingController _ttsIntroCtrl = TextEditingController();
  final List<_DailyPlanRowEdit> _dailyPlanRows = _dailyPlanPresets
      .map(_DailyPlanRowEdit.new)
      .toList();
  bool _dailyPlanPreparingImages = false;
  bool _dailyPlanImagesReady = false;
  Timer? _dailyPlanAssetCheckTimer;
  String _dailyPlanImageStatus = '正在检查云端是否已有计划表图片…';
  Map<String, String?> _preparedDailyPlanImages = const {};

  String? _boundXiaozhiDeviceId;

  @override
  void initState() {
    super.initState();
    _loadTrainingDraft(_trainingSceneIndex);
    _ttsIntroCtrl.addListener(_markTrainingDraftDirty);
    for (final c in _optionCtrls) {
      c.addListener(_markTrainingDraftDirty);
    }
    for (final row in _dailyPlanRows) {
      row.ttsCtrl.addListener(_markDailyPlanDirty);
      for (final c in row.optionCtrls) {
        c.addListener(_markDailyPlanDirty);
      }
    }
    _cloud = CloudService(serverHost: widget.serverIp)
      ..authToken = widget.authToken
      ..childId = widget.activeChildId;
    _refreshEspBindings();
    _pollNeedsOnce(showLoadingSpinner: true);
    _startNeedsPolling();
    _startTrainingEventsPolling();
    _scheduleTrainingAssetCacheCheck(immediate: true);
    _scheduleDailyPlanAssetCacheCheck(immediate: true);
  }

  @override
  void didUpdateWidget(covariant AutismFamilyShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeChildId != widget.activeChildId ||
        oldWidget.authToken != widget.authToken ||
        oldWidget.serverIp != widget.serverIp) {
      _cloud
        ..serverHost = widget.serverIp
        ..authToken = widget.authToken
        ..childId = widget.activeChildId;
      _stopPoll();
      _stopNeedsPolling();
      _trainingSessionId = null;
      _trainingPhase = AutismTrainingPhase.parentSetup;
      _trainingPreparingImages = false;
      _trainingImagesReady = false;
      _preparedTrainingImages = const {};
      _trainingImageStatus = '正在检查云端是否已有当前场景图片…';
      _needsPollPrimed = false;
      _trainingEventsPrimed = false;
      _lastTrainingEventId = 0;
      _lastPolledNeedIds.clear();
      _childJustChoseBanner = null;
      _trainingEventBanner = null;
      _dailyPlanPreparingImages = false;
      _dailyPlanImagesReady = false;
      _preparedDailyPlanImages = const {};
      _dailyPlanImageStatus = '正在检查云端是否已有计划表图片…';
      _refreshEspBindings();
      _pollNeedsOnce(showLoadingSpinner: true);
      _pollTrainingEventsOnce();
      _scheduleTrainingAssetCacheCheck(immediate: true);
      _scheduleDailyPlanAssetCacheCheck(immediate: true);
      if (_section == 0) {
        _startNeedsPolling();
      }
    }
  }

  @override
  void dispose() {
    _stopPoll();
    _stopNeedsPolling();
    _stopTrainingEventsPolling();
    _trainingAssetCheckTimer?.cancel();
    _dailyPlanAssetCheckTimer?.cancel();
    for (final c in _optionCtrls) {
      c.dispose();
    }
    _ttsIntroCtrl.dispose();
    for (final row in _dailyPlanRows) {
      row.dispose();
    }
    super.dispose();
  }

  _TrainingScenePreset get _trainingPreset => _trainingScenePresets[_trainingSceneIndex];

  void _saveCurrentTrainingDraft() {
    final draft = _trainingDrafts[_trainingSceneIndex];
    draft.ttsIntro = _ttsIntroCtrl.text.trim();
    draft.options = _optionCtrls
        .map((c) => c.text.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  void _loadTrainingDraft(int index) {
    final draft = _trainingDrafts[index];
    _loadingTrainingDraft = true;
    _ttsIntroCtrl.text = draft.ttsIntro;
    for (var i = 0; i < _optionCtrls.length; i++) {
      _optionCtrls[i].text = i < draft.options.length ? draft.options[i] : '';
    }
    _loadingTrainingDraft = false;
  }

  void _markTrainingDraftDirty() {
    if (_loadingTrainingDraft) return;
    _saveCurrentTrainingDraft();
    if (_trainingPreparingImages) return;
    final nextImages = Map<String, Map<String, String?>>.from(_preparedTrainingImages)
      ..remove(_trainingPreset.sceneId);
    setState(() {
      _trainingImagesReady = false;
      _preparedTrainingImages = nextImages;
      _trainingImageStatus = '当前场景内容已修改，正在检查云端是否已有图片…';
    });
    _scheduleTrainingAssetCacheCheck();
  }

  void _applyTrainingScenePreset(int index) {
    final preset = _trainingScenePresets[index];
    final draft = _trainingDrafts[index];
    draft.ttsIntro = preset.ttsIntro;
    draft.options = List<String>.from(preset.options);
    _trainingImagesReady = false;
    _preparedTrainingImages = Map<String, Map<String, String?>>.from(_preparedTrainingImages)
      ..remove(preset.sceneId);
    _trainingImageStatus = '已恢复当前场景预设，正在检查云端是否已有图片…';
    _loadingTrainingDraft = true;
    _ttsIntroCtrl.text = preset.ttsIntro;
    for (var i = 0; i < _optionCtrls.length; i++) {
      _optionCtrls[i].text = i < preset.options.length ? preset.options[i] : '';
    }
    _loadingTrainingDraft = false;
    _scheduleTrainingAssetCacheCheck();
  }

  void _scheduleTrainingAssetCacheCheck({bool immediate = false}) {
    _trainingAssetCheckTimer?.cancel();
    _trainingAssetCheckTimer = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 650),
      _checkTrainingAssetsCached,
    );
  }

  Future<void> _checkTrainingAssetsCached() async {
    if (!mounted || _trainingPreparingImages) return;
    _saveCurrentTrainingDraft();
    final scene = _trainingDrafts[_trainingSceneIndex].toJson();
    final options = (scene['options'] as List?) ?? const [];
    if (options.isEmpty) {
      if (!mounted) return;
      setState(() {
        _trainingImagesReady = false;
        _preparedTrainingImages = Map<String, Map<String, String?>>.from(_preparedTrainingImages)
          ..remove(_trainingPreset.sceneId);
        _trainingImageStatus = '请先填写当前训练场景的至少一个选项。';
      });
      return;
    }

    final res = await _cloud.checkAutismTrainingAssets(
      childIdToFetch: widget.activeChildId,
      scenes: [scene],
    );
    if (!mounted || _trainingPreparingImages) return;
    if (res == null || res['status'] != 'ok') {
      setState(() {
        _trainingImagesReady = false;
        _preparedTrainingImages = Map<String, Map<String, String?>>.from(_preparedTrainingImages)
          ..remove(_trainingPreset.sceneId);
        _trainingImageStatus = '无法检查当前场景云端图片缓存，请点击“应用”生成图片。';
      });
      return;
    }
    final rawImages = (res['images'] as Map?) ?? const {};
    final parsed = <String, Map<String, String?>>{};
    for (final entry in rawImages.entries) {
      final sceneId = entry.key.toString();
      final value = entry.value;
      if (value is Map) {
        parsed[sceneId] = value.map((k, v) => MapEntry(k.toString(), v?.toString()));
      }
    }
    final ready = res['all_ready'] == true;
    final readyCount = (res['ready_count'] as num?)?.toInt() ?? 0;
    final expectedCount = (res['expected_count'] as num?)?.toInt() ?? 0;
    final nextImages = Map<String, Map<String, String?>>.from(_preparedTrainingImages);
    if (ready) {
      nextImages.addAll(parsed);
    } else {
      nextImages.remove(_trainingPreset.sceneId);
    }
    setState(() {
      _trainingImagesReady = ready;
      _preparedTrainingImages = nextImages;
      _trainingImageStatus = ready
          ? '已检测到云端已有当前场景图片，可直接下发。共 $readyCount 张。'
          : '云端缺少当前场景图片（$readyCount/$expectedCount），请点击“应用”生成。';
    });
  }

  void _selectTrainingScene(int index) {
    if (index == _trainingSceneIndex) return;
    _saveCurrentTrainingDraft();
    _stopPoll();
    setState(() {
      _trainingSceneIndex = index;
      _trainingSessionId = null;
      _trainingPhase = AutismTrainingPhase.parentSetup;
      _lastSessionState = '';
      _loadTrainingDraft(index);
      _trainingImagesReady = false;
      _trainingImageStatus = '正在检查云端是否已有当前场景图片…';
    });
    _scheduleTrainingAssetCacheCheck(immediate: true);
  }

  void _stopPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _stopNeedsPolling() {
    _needsPollTimer?.cancel();
    _needsPollTimer = null;
  }

  void _stopTrainingEventsPolling() {
    _trainingEventsPollTimer?.cancel();
    _trainingEventsPollTimer = null;
  }

  void _startNeedsPolling() {
    _stopNeedsPolling();
    _needsPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _pollNeedsOnce(showLoadingSpinner: false);
    });
  }

  void _startTrainingEventsPolling() {
    _stopTrainingEventsPolling();
    _trainingEventsPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _pollTrainingEventsOnce();
    });
    _pollTrainingEventsOnce();
  }

  static String _joinChildChoiceLabels(
    List<Map<String, dynamic>> list,
    Set<int> newIds,
  ) {
    final parts = <String>[];
    for (final n in list) {
      final id = (n['id'] as num).toInt();
      if (!newIds.contains(id)) continue;
      final lab = n['label']?.toString().trim() ?? '';
      if (lab.isNotEmpty) {
        parts.add(lab);
      }
    }
    return parts.join('、');
  }

  /// 拉取待确认需求；在「孩子发起」页由定时器自动调用。检测到新条目时震动并更新横幅。
  Future<void> _pollNeedsOnce({required bool showLoadingSpinner}) async {
    if (!mounted) return;
    if (_needsPollInFlight) {
      return;
    }
    _needsPollInFlight = true;
    if (showLoadingSpinner) {
      setState(() => _loadingNeeds = true);
    }
    try {
      final list = await _cloud.fetchAutismPendingNeeds(widget.activeChildId);
      if (!mounted) return;

      final ids = list.map((n) => (n['id'] as num).toInt()).toSet();
      String? newBanner = _childJustChoseBanner;
      bool vibrate = false;

      if (_needsPollPrimed) {
        final newIds = ids.difference(_lastPolledNeedIds);
        if (newIds.isNotEmpty) {
          vibrate = true;
          final joined = _joinChildChoiceLabels(list, newIds);
          newBanner = joined.isNotEmpty ? joined : '孩子有新的需求';
        }
      } else {
        _needsPollPrimed = true;
      }

      _lastPolledNeedIds
        ..clear()
        ..addAll(ids);

      if (vibrate) {
        HapticFeedback.heavyImpact();
      }

      setState(() {
        _pendingNeeds = list;
        _loadingNeeds = false;
        _needsLastSyncedAt = DateTime.now();
        if (vibrate) {
          _childJustChoseBanner = newBanner;
        }
      });
    } finally {
      _needsPollInFlight = false;
    }
  }

  Future<void> _pollTrainingEventsOnce() async {
    if (!mounted || _trainingEventsInFlight) return;
    _trainingEventsInFlight = true;
    try {
      final list = await _cloud.fetchAutismTrainingEvents(
        childIdToFetch: widget.activeChildId,
        afterId: _lastTrainingEventId,
      );
      if (!mounted) return;
      if (list.isEmpty) {
        _trainingEventsPrimed = true;
        return;
      }
      for (final e in list) {
        final id = (e['id'] as num?)?.toInt() ?? 0;
        if (id > _lastTrainingEventId) {
          _lastTrainingEventId = id;
        }
      }
      if (!_trainingEventsPrimed) {
        _trainingEventsPrimed = true;
        return;
      }

      final confirmed = list.where((e) => (e['phase'] ?? '').toString() == 'image_confirmed').toList();
      if (confirmed.isEmpty) return;
      final latest = confirmed.last;
      final payload = Map<String, dynamic>.from((latest['payload'] as Map?) ?? const {});
      final label = (payload['label'] ?? '').toString().trim();
      final scene = (latest['scene'] ?? '').toString();
      final slotTime = (payload['slot_time'] ?? '').toString().trim();
      HapticFeedback.heavyImpact();
      setState(() {
        _trainingEventBanner = [
          if (slotTime.isNotEmpty) slotTime,
          scene == 'daily_plan' ? '日常计划' : '孩子训练',
          label.isNotEmpty ? '孩子选择了：$label' : '孩子完成了一次图片确认',
        ].join(' · ');
      });
    } finally {
      _trainingEventsInFlight = false;
    }
  }

  Future<void> _refreshEspBindings() async {
    final list = await _cloud.fetchEsp32List();
    if (!mounted) return;
    String? xz;
    for (final m in list) {
      final cid = m['child_id'];
      final kid = (m['kind'] ?? '').toString().toLowerCase();
      if (cid == widget.activeChildId && kid == 'xiaozhi') {
        xz = (m['device_id'] ?? '').toString();
        break;
      }
    }
    setState(() => _boundXiaozhiDeviceId = xz);
  }

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

  Future<void> _confirmNeed(int id) async {
    final ok = await _cloud.confirmAutismNeed(widget.activeChildId, id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '已确认' : '确认失败，请稍后再试')),
    );
    if (ok) {
      setState(() => _childJustChoseBanner = null);
    }
    await _pollNeedsOnce(showLoadingSpinner: false);
  }

  void _startPollingIfNeeded(int sessionId) {
    _stopPoll();
    _trainingSessionId = sessionId;
    _trainingPhase = AutismTrainingPhase.waitingDevice;
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      final data = await _cloud.fetchAutismTrainingStatus(
        childIdToFetch: widget.activeChildId,
        sessionId: sessionId,
      );
      if (!mounted || data == null) return;
      final s = data['session'] as Map<String, dynamic>?;
      final st = (s?['state'] ?? '').toString();
      if (st != _lastSessionState) {
        setState(() {
          _lastSessionState = st;
          if (st.startsWith('phase:')) {
            _trainingPhase = AutismTrainingPhase.deviceProgress;
          } else if (st == 'sent' || st == 'queued_no_device') {
            _trainingPhase = AutismTrainingPhase.waitingDevice;
          }
        });
      }
    });
    // _trainingSessionId / phase 已更新，须触发一次 build（否则会话号区域可能空白到首轮轮询）
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _applyTrainingAssets() async {
    _saveCurrentTrainingDraft();
    final scene = _trainingDrafts[_trainingSceneIndex].toJson();
    final options = (scene['options'] as List?) ?? const [];
    if (options.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请先填写“${_trainingDrafts[_trainingSceneIndex].title}”的至少一个选项')),
      );
      return;
    }

    setState(() {
      _trainingPreparingImages = true;
      _trainingImagesReady = false;
      _preparedTrainingImages = Map<String, Map<String, String?>>.from(_preparedTrainingImages)
        ..remove(_trainingPreset.sceneId);
      _trainingImageStatus = '当前场景 AI 图片生成中，请稍候…';
    });

    final res = await _cloud.prepareAutismTrainingAssets(
      childIdToFetch: widget.activeChildId,
      scenes: [scene],
    );
    if (!mounted) return;
    if (res == null || res['status'] != 'ok') {
      setState(() {
        _trainingPreparingImages = false;
        _trainingImagesReady = false;
        _trainingImageStatus = 'AI 图片生成失败，请检查 GLM_API_KEY、网络或服务端日志后重试。';
      });
      return;
    }

    final rawImages = (res['images'] as Map?) ?? const {};
    final parsed = <String, Map<String, String?>>{};
    for (final entry in rawImages.entries) {
      final sceneId = entry.key.toString();
      final value = entry.value;
      if (value is Map) {
        parsed[sceneId] = value.map(
          (k, v) => MapEntry(k.toString(), v?.toString()),
        );
      }
    }
    final count = (res['image_count'] as num?)?.toInt() ?? 0;
    final ready = res['all_ready'] == true;
    final readyCount = (res['ready_count'] as num?)?.toInt() ?? count;
    final expectedCount = (res['expected_count'] as num?)?.toInt() ?? count;
    final nextImages = Map<String, Map<String, String?>>.from(_preparedTrainingImages);
    if (ready) {
      nextImages.addAll(parsed);
    } else {
      nextImages.remove(_trainingPreset.sceneId);
    }
    setState(() {
      _preparedTrainingImages = nextImages;
      _trainingPreparingImages = false;
      _trainingImagesReady = ready;
      _trainingImageStatus = _trainingImagesReady
          ? '当前场景 AI 图片已生成并存储，可下发到星星机器人。共 $readyCount 张。'
          : 'AI 图片生成不完整（$readyCount/$expectedCount），请重试。';
    });
  }

  Future<void> _startTraining() async {
    _saveCurrentTrainingDraft();
    if (_trainingPreparingImages || !_trainingImagesReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先点击“应用”，等待当前场景 AI 图片生成完成')),
      );
      return;
    }
    final options = _optionCtrls
        .map((c) => c.text.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (options.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少填写一个选项')),
      );
      return;
    }
    final res = await _cloud.startAutismTraining(
      childIdToFetch: widget.activeChildId,
      sceneId: _trainingPreset.sceneId,
      options: options,
      images: _preparedTrainingImages[_trainingPreset.sceneId],
      followUp: false,
      ttsIntro: _ttsIntroCtrl.text.trim(),
    );
    if (!mounted) return;
    if (res == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下发失败，请检查网络与星星是否在线')),
      );
      return;
    }
    final sid = (res['session_id'] as num?)?.toInt();
    if (sid != null) {
      _startPollingIfNeeded(sid);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${_trainingPreset.title}已排队下发（设备数：${(res['queued_devices'] as List?)?.length ?? 0}）',
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _dailyPlanSlotsJson() {
    return _dailyPlanRows.map((row) => row.toJson()).toList();
  }

  int _invalidDailyPlanSlotIndex(List<Map<String, dynamic>> slots) {
    return slots.indexWhere((slot) {
      final tts = (slot['tts'] ?? '').toString();
      final options = (slot['options'] as List?) ?? const [];
      return tts.isEmpty || options.isEmpty;
    });
  }

  void _markDailyPlanDirty() {
    if (_dailyPlanPreparingImages) return;
    setState(() {
      _dailyPlanImagesReady = false;
      _preparedDailyPlanImages = const {};
      _dailyPlanImageStatus = '计划表内容已修改，正在检查云端是否已有图片…';
    });
    _scheduleDailyPlanAssetCacheCheck();
  }

  void _scheduleDailyPlanAssetCacheCheck({bool immediate = false}) {
    _dailyPlanAssetCheckTimer?.cancel();
    _dailyPlanAssetCheckTimer = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 650),
      _checkDailyPlanAssetsCached,
    );
  }

  Future<void> _checkDailyPlanAssetsCached() async {
    if (!mounted || _dailyPlanPreparingImages) return;
    final slots = _dailyPlanSlotsJson();
    final invalidIndex = _invalidDailyPlanSlotIndex(slots);
    if (invalidIndex >= 0) {
      if (!mounted) return;
      setState(() {
        _dailyPlanImagesReady = false;
        _preparedDailyPlanImages = const {};
        _dailyPlanImageStatus = '第 ${invalidIndex + 1} 项需要填写话术和至少一个选项。';
      });
      return;
    }

    final res = await _cloud.checkAutismDailyPlanAssets(
      widget.activeChildId,
      slots: slots,
    );
    if (!mounted || _dailyPlanPreparingImages) return;
    if (res == null || res['status'] != 'ok') {
      setState(() {
        _dailyPlanImagesReady = false;
        _preparedDailyPlanImages = const {};
        _dailyPlanImageStatus = '无法检查云端图片缓存，请点击“应用”生成图片。';
      });
      return;
    }
    final rawImages = (res['images'] as Map?) ?? const {};
    final parsed = <String, String?>{};
    for (final e in rawImages.entries) {
      parsed[e.key.toString()] = e.value?.toString();
    }
    final ready = res['all_ready'] == true;
    final readyCount = (res['ready_count'] as num?)?.toInt() ?? 0;
    final expectedCount = (res['expected_count'] as num?)?.toInt() ?? 0;
    setState(() {
      _dailyPlanImagesReady = ready;
      _preparedDailyPlanImages = ready ? parsed : const {};
      _dailyPlanImageStatus = ready
          ? '已检测到云端已有计划表图片，可直接同步。共 $readyCount 张。'
          : '云端缺少部分计划表图片（$readyCount/$expectedCount），请点击“应用”生成。';
    });
  }

  Future<void> _applyDailyPlanAssets() async {
    final slots = _dailyPlanSlotsJson();
    final invalidIndex = slots.indexWhere((slot) {
      final tts = (slot['tts'] ?? '').toString();
      final options = (slot['options'] as List?) ?? const [];
      return tts.isEmpty || options.isEmpty;
    });
    if (invalidIndex >= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('第 ${invalidIndex + 1} 行需要填写话术和至少一个选项')),
      );
      return;
    }
    setState(() {
      _dailyPlanPreparingImages = true;
      _dailyPlanImagesReady = false;
      _preparedDailyPlanImages = const {};
      _dailyPlanImageStatus = 'AI 图片生成中，请稍候…';
    });
    final res = await _cloud.prepareAutismDailyPlanAssets(
      widget.activeChildId,
      slots: slots,
    );
    if (!mounted) return;
    if (res == null || res['status'] != 'ok') {
      setState(() {
        _dailyPlanPreparingImages = false;
        _dailyPlanImagesReady = false;
        _dailyPlanImageStatus = 'AI 图片生成失败，请检查 GLM_API_KEY、网络或服务端日志后重试。';
      });
      return;
    }
    final rawImages = (res['images'] as Map?) ?? const {};
    final parsed = <String, String?>{};
    for (final e in rawImages.entries) {
      parsed[e.key.toString()] = e.value?.toString();
    }
    final expectedCount = slots.fold<int>(
      0,
      (sum, slot) => sum + (((slot['options'] as List?) ?? const []).length),
    );
    final readyCount = parsed.values.where((v) => v != null && v!.startsWith('http')).length;
    final count = (res['image_count'] as num?)?.toInt() ?? 0;
    setState(() {
      _preparedDailyPlanImages = parsed;
      _dailyPlanPreparingImages = false;
      _dailyPlanImagesReady = expectedCount > 0 && readyCount == expectedCount;
      _dailyPlanImageStatus = _dailyPlanImagesReady
          ? 'AI 图片已生成并存储，可同步到星星机器人。共 $count 张。'
          : 'AI 图片生成不完整（$readyCount/$expectedCount），请重试。';
    });
  }

  Future<void> _postDailyPlan() async {
    if (_dailyPlanPreparingImages || !_dailyPlanImagesReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先点击“应用”，等待 AI 图片全部生成完成')),
      );
      return;
    }
    final slots = _dailyPlanSlotsJson();
    final invalidIndex = _invalidDailyPlanSlotIndex(slots);
    if (invalidIndex >= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('第 ${invalidIndex + 1} 行需要填写话术和至少一个选项')),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在同步计划表到星星机器人…')),
    );
    final res = await _cloud.postAutismDailyPlan(
      widget.activeChildId,
      slots: slots,
      images: _preparedDailyPlanImages,
    );
    if (!mounted) return;
    if (res == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('同步失败，请稍后再试')),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('日常计划已下发到星星机器人队列')),
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
          const SnackBar(content: Text('暂无孩子档案')),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败：$e')),
        );
      }
    }
  }

  Future<void> _showParentProfile() async {
    final existing = await _cloud.fetchChildProfile(widget.activeChildId);
    if (!mounted) return;
    final result = await showParentChildProfileDialog(
      context: context,
      childId: widget.activeChildId,
      profile: existing,
    );
    if (result == null || !mounted) return;
    final saved = await ParentChildProfileStore.saveProfile(
      result,
      cloudService: _cloud,
    );
    if (!mounted) return;
    widget.onChildCategoryChanged?.call(saved.childCondition);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存孩子资料')),
    );
  }

  Future<void> _openChildSkill() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (ctx) => ChildSkillPage(
          cloudService: _cloud,
          childId: widget.activeChildId,
        ),
      ),
    );
  }

  Future<void> _openXiaozhiProv() async {
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (ctx) => EspProvisionPage(
          cloudService: _cloud,
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
    await _refreshEspBindings();
  }

  Future<void> _resetXiaozhiProv() async {
    final deviceId = _boundXiaozhiDeviceId;
    if (deviceId == null || deviceId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先绑定或配网星星机器人')),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('让星星机器人重新配网？'),
        content: Text('将向 $deviceId 下发清空 WiFi 并重启指令。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final pushed = await _cloud.triggerEsp32ResetProvisioning(deviceId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(pushed ? '已下发重启配网指令' : '指令下发失败，设备可能离线'),
      ),
    );
  }

  Future<void> _showXiaozhiBind() async {
    final ctrl = TextEditingController();
    final submit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('绑定小智设备 (MAC)'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'device_id（8 位）或 MAC',
            hintText: '例：E0160560',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('绑定')),
        ],
      ),
    );
    final text = ctrl.text;
    ctrl.dispose();
    if (submit != true || !mounted) return;
    final cleaned = text.trim().replaceAll(RegExp(r'[:\-\s]'), '').toUpperCase();
    String raw;
    if (RegExp(r'^[0-9A-F]{8}$').hasMatch(cleaned)) {
      raw = cleaned;
    } else if (RegExp(r'^[0-9A-F]{12}$').hasMatch(cleaned)) {
      raw = cleaned.substring(4);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('格式不正确')),
      );
      return;
    }
    final ok = await _cloud.bindEsp32(raw, widget.activeChildId, kind: 'xiaozhi');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '绑定成功' : '绑定失败')),
    );
    await _refreshEspBindings();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('孤独症 · 陪伴'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu_rounded, color: AppColors.sage),
            onSelected: (v) async {
              if (v == 'switch') await _showSwitchChildDialog();
              if (v == 'child_profile') await _showParentProfile();
              if (v == 'child_skill') await _openChildSkill();
              if (v == 'xiaozhi_prov') await _openXiaozhiProv();
              if (v == 'xiaozhi_reset') await _resetXiaozhiProv();
              if (v == 'xiaozhi_bind') await _showXiaozhiBind();
              if (v == 'switch_mode') widget.onSwitchMode?.call();
              if (v == 'logout') widget.onLogout?.call();
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                enabled: false,
                height: 32,
                child: Text('家庭协作', style: TextStyle(fontSize: 11, color: Colors.grey)),
              ),
              const PopupMenuItem(value: 'switch', child: Text('切换关注的孩子')),
              const PopupMenuItem(value: 'child_profile', child: Text('录入孩子资料')),
              const PopupMenuItem(value: 'child_skill', child: Text('查看孩子 Skill')),
              const PopupMenuDivider(),
              const PopupMenuItem(
                enabled: false,
                height: 32,
                child: Text('设备管理', style: TextStyle(fontSize: 11, color: Colors.grey)),
              ),
              const PopupMenuItem(value: 'xiaozhi_prov', child: Text('配网星星机器人')),
              const PopupMenuItem(value: 'xiaozhi_reset', child: Text('让星星机器人重新配网')),
              const PopupMenuItem(value: 'xiaozhi_bind', child: Text('绑定小智设备 (MAC)')),
              const PopupMenuDivider(),
              if (widget.onSwitchMode != null)
                const PopupMenuItem(value: 'switch_mode', child: Text('切换使用身份')),
              const PopupMenuItem(value: 'logout', child: Text('退出登录')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.insights_rounded, color: AppColors.sage),
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
            icon: const Icon(Icons.auto_stories_outlined, color: AppColors.sage),
            tooltip: 'AI 报告',
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
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('主动发起'), icon: Icon(Icons.front_hand_outlined)),
              ButtonSegment(value: 1, label: Text('日常训练'), icon: Icon(Icons.psychology_outlined)),
              ButtonSegment(value: 2, label: Text('计划表'), icon: Icon(Icons.calendar_today_outlined)),
            ],
            selected: {_section},
            onSelectionChanged: (s) {
              final v = s.first;
              setState(() => _section = v);
              if (v == 0) {
                _startNeedsPolling();
                _pollNeedsOnce(showLoadingSpinner: _pendingNeeds.isEmpty);
              } else {
                _stopNeedsPolling();
              }
            },
          ),
          const SizedBox(height: 16),
          if (_trainingEventBanner != null && _trainingEventBanner!.isNotEmpty) ...[
            Material(
              color: AppColors.coral.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.vibration_rounded, color: AppColors.coral),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _trainingEventBanner!,
                        style: const TextStyle(fontWeight: FontWeight.w700, height: 1.35),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭提示',
                      onPressed: () => setState(() => _trainingEventBanner = null),
                      icon: const Icon(Icons.close_rounded, size: 20),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (_section == 0) _buildChildInitiated(),
          if (_section == 1) _buildTraining(),
          if (_section == 2) _buildDailyPlan(),
        ],
      ),
    );
  }

  Widget _buildChildInitiated() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('孩子主动发起', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 8),
            Text(
              _boundXiaozhiDeviceId != null
                  ? '星星已绑定（$_boundXiaozhiDeviceId）。孩子在设备上选择并确认需求后，本页会自动更新，无需手动刷新。'
                  : '尚未检测到已绑定的星星机器人，请先在菜单中配网并绑定。',
              style: const TextStyle(height: 1.45, color: AppColors.muted),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.sensors_rounded, size: 18, color: AppColors.sage.withValues(alpha: 0.9)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _loadingNeeds
                        ? '正在同步待确认需求…'
                        : '自动监听中（约每 2 秒）${_needsLastSyncedAt != null ? ' · 上次 ${_needsLastSyncedAt!.hour.toString().padLeft(2, '0')}:${_needsLastSyncedAt!.minute.toString().padLeft(2, '0')}:${_needsLastSyncedAt!.second.toString().padLeft(2, '0')}' : ''}',
                    style: TextStyle(fontSize: 12, color: AppColors.muted.withValues(alpha: 0.95)),
                  ),
                ),
                if (_loadingNeeds)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (_childJustChoseBanner != null && _childJustChoseBanner!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Material(
                color: AppColors.sage.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.notifications_active_rounded, color: AppColors.sage.withValues(alpha: 0.95)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '孩子选择了：$_childJustChoseBanner',
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, height: 1.35),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭提示',
                        onPressed: () => setState(() => _childJustChoseBanner = null),
                        icon: const Icon(Icons.close_rounded, size: 20),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (_pendingNeeds.isEmpty)
              const Text('暂无待确认需求', style: TextStyle(color: AppColors.muted))
            else
              ..._pendingNeeds.map((n) {
                final id = (n['id'] as num).toInt();
                final label = n['label']?.toString() ?? '';
                final created = n['created_at']?.toString() ?? '';
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(label),
                  subtitle: Text(created, style: const TextStyle(fontSize: 12)),
                  trailing: FilledButton(
                    onPressed: () => _confirmNeed(id),
                    child: const Text('家长确认'),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildTraining() {
    final preset = _trainingPreset;
    final canStartTraining = _trainingImagesReady && !_trainingPreparingImages;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('孩子训练', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
              '选择一个预设场景，家长可调整开场白和图片选项，然后下发到星星机器人。',
              style: TextStyle(height: 1.45, color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < _trainingScenePresets.length; i++) ...[
                    ChoiceChip(
                      label: Text(_trainingScenePresets[i].title),
                      selected: _trainingSceneIndex == i,
                      onSelected: (_) => _selectTrainingScene(i),
                    ),
                    if (i != _trainingScenePresets.length - 1) const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            Material(
              color: AppColors.sage.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${preset.title}训练',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                    ),
                    const SizedBox(height: 4),
                    Text(preset.subtitle, style: const TextStyle(color: AppColors.muted)),
                    const SizedBox(height: 10),
                    Text('目标：${preset.goal}', style: const TextStyle(height: 1.45)),
                    const SizedBox(height: 10),
                    const Text('预设流程', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    ...preset.flow.asMap().entries.map(
                          (e) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text('${e.key + 1}. ${e.value}', style: const TextStyle(height: 1.35)),
                          ),
                        ),
                    if (preset.parameters.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text('可变参数', style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      ...preset.parameters.map(
                        (p) => Text('• $p', style: const TextStyle(height: 1.35, color: AppColors.muted)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text('开场白（可选）', style: TextStyle(fontWeight: FontWeight.w600)),
            TextField(
              controller: _ttsIntroCtrl,
              enabled: !_trainingPreparingImages,
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                  child: Text('图片选项（至少一项）', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                TextButton.icon(
                  onPressed: _trainingPreparingImages
                      ? null
                      : () => setState(() => _applyTrainingScenePreset(_trainingSceneIndex)),
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                  label: const Text('恢复预设'),
                ),
              ],
            ),
            ..._optionCtrls.asMap().entries.map((e) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  controller: e.value,
                  enabled: !_trainingPreparingImages,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: '选项 ${e.key + 1}',
                    hintText: e.key < preset.options.length ? preset.options[e.key] : '可留空',
                  ),
                ),
              );
            }),
            const SizedBox(height: 8),
            Material(
              color: _trainingImagesReady
                  ? AppColors.sage.withValues(alpha: 0.12)
                  : AppColors.warning.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    if (_trainingPreparingImages)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        _trainingImagesReady ? Icons.check_circle_rounded : Icons.auto_awesome_rounded,
                        color: _trainingImagesReady ? AppColors.sage : AppColors.warning,
                        size: 20,
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _trainingImageStatus,
                        style: const TextStyle(height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _trainingPreparingImages ? null : _applyTrainingAssets,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('应用：先生成并存储当前场景图片'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: canStartTraining ? _startTraining : null,
              icon: const Icon(Icons.send_rounded),
              label: Text('${preset.startButton}并下发到星星机器人'),
            ),
            if (_trainingSessionId != null) ...[
              const SizedBox(height: 16),
              Text('${preset.title}会话 #$_trainingSessionId · ${_trainingPhase.name} · $_lastSessionState'),
              OutlinedButton(
                onPressed: () {
                  _stopPoll();
                  setState(() {
                    _trainingSessionId = null;
                    _trainingPhase = AutismTrainingPhase.parentSetup;
                    _lastSessionState = '';
                  });
                },
                child: const Text('清除会话显示'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDailyPlan() {
    final canSyncDailyPlan = _dailyPlanImagesReady && !_dailyPlanPreparingImages;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('孩子日常计划表', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
              '每一行可编辑时间、机器人要说的话和孩子可选择的图片选项。同步后云端会为每个选项生成 240×240 图片并下发星星机器人。',
              style: TextStyle(height: 1.45, color: AppColors.muted),
            ),
            const SizedBox(height: 16),
            ..._dailyPlanRows.asMap().entries.map((entry) {
              final index = entry.key;
              final row = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Material(
                  color: AppColors.sage.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Text(
                              '第 ${index + 1} 项',
                              style: const TextStyle(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(width: 12),
                            SizedBox(
                              width: 118,
                              child: DropdownButtonFormField<String>(
                                value: row.time,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  labelText: '时间',
                                ),
                                items: _dailyPlanTimeChoices
                                    .map(
                                      (t) => DropdownMenuItem<String>(
                                        value: t,
                                        child: Text(t),
                                      ),
                                    )
                                    .toList(),
                                onChanged: _dailyPlanPreparingImages
                                    ? null
                                    : (v) {
                                        if (v == null) return;
                                        row.time = v;
                                        _markDailyPlanDirty();
                                      },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: row.ttsCtrl,
                          enabled: !_dailyPlanPreparingImages,
                          maxLines: 2,
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: '星星机器人说',
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          '图片选项',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        ...row.optionCtrls.asMap().entries.map((optEntry) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: TextField(
                              controller: optEntry.value,
                              enabled: !_dailyPlanPreparingImages,
                              decoration: InputDecoration(
                                isDense: true,
                                labelText: '选项 ${optEntry.key + 1}',
                                hintText: optEntry.key == 2 ? '可留空' : null,
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
              );
            }),
            Material(
              color: _dailyPlanImagesReady
                  ? AppColors.sage.withValues(alpha: 0.12)
                  : AppColors.warning.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    if (_dailyPlanPreparingImages)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        _dailyPlanImagesReady ? Icons.check_circle_rounded : Icons.auto_awesome_rounded,
                        color: _dailyPlanImagesReady ? AppColors.sage : AppColors.warning,
                        size: 20,
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _dailyPlanImageStatus,
                        style: const TextStyle(height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _dailyPlanPreparingImages ? null : _applyDailyPlanAssets,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('应用：先生成并存储计划表图片'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: canSyncDailyPlan ? _postDailyPlan : null,
              child: const Text('同步到星星AI机器人'),
            ),
          ],
        ),
      ),
    );
  }
}
