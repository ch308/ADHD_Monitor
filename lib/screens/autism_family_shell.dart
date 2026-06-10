import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
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

  int? _trainingSessionId;
  AutismTrainingPhase _trainingPhase = AutismTrainingPhase.parentSetup;
  Timer? _pollTimer;
  String _lastSessionState = '';
  final List<TextEditingController> _optionCtrls = List.generate(
    3,
    (_) => TextEditingController(),
  );
  final TextEditingController _ttsIntroCtrl = TextEditingController(
    text: '我们来选一个你更喜欢的东西吧。',
  );

  String? _boundXiaozhiDeviceId;

  @override
  void initState() {
    super.initState();
    _optionCtrls[0].text = '苹果';
    _optionCtrls[1].text = '香蕉';
    _optionCtrls[2].text = '橙子';
    _cloud = CloudService(serverHost: widget.serverIp)
      ..authToken = widget.authToken
      ..childId = widget.activeChildId;
    _refreshEspBindings();
    _loadNeeds();
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
      _trainingSessionId = null;
      _trainingPhase = AutismTrainingPhase.parentSetup;
      _refreshEspBindings();
      _loadNeeds();
    }
  }

  @override
  void dispose() {
    _stopPoll();
    for (final c in _optionCtrls) {
      c.dispose();
    }
    _ttsIntroCtrl.dispose();
    super.dispose();
  }

  void _stopPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
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

  Future<void> _loadNeeds() async {
    setState(() => _loadingNeeds = true);
    final list = await _cloud.fetchAutismPendingNeeds(widget.activeChildId);
    if (!mounted) return;
    setState(() {
      _pendingNeeds = list;
      _loadingNeeds = false;
    });
  }

  Future<void> _confirmNeed(int id) async {
    final ok = await _cloud.confirmAutismNeed(widget.activeChildId, id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '已确认' : '确认失败，请稍后再试')),
    );
    await _loadNeeds();
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

  Future<void> _startTraining() async {
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
      sceneId: AutismTrainingSceneIds.preferenceChoice,
      options: options,
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
          '已排队下发（设备数：${(res['queued_devices'] as List?)?.length ?? 0}）',
        ),
      ),
    );
  }

  Future<void> _postDailyPlan() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在生成图片并同步，可能需要一两分钟…')),
    );
    final res = await _cloud.postAutismDailyPlan(widget.activeChildId);
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
              ButtonSegment(value: 0, label: Text('孩子发起'), icon: Icon(Icons.front_hand_outlined)),
              ButtonSegment(value: 1, label: Text('训练'), icon: Icon(Icons.psychology_outlined)),
              ButtonSegment(value: 2, label: Text('日常计划'), icon: Icon(Icons.calendar_today_outlined)),
            ],
            selected: {_section},
            onSelectionChanged: (s) => setState(() => _section = s.first),
          ),
          const SizedBox(height: 16),
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
                  ? '星星已绑定（$_boundXiaozhiDeviceId）。孩子在设备上摇晃并双击确认需求后，会在此列出待确认项。'
                  : '尚未检测到已绑定的星星机器人，请先在菜单中配网并绑定。',
              style: const TextStyle(height: 1.45, color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _loadingNeeds ? null : _loadNeeds,
                  icon: _loadingNeeds
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('刷新待确认'),
                ),
              ],
            ),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('家长开启训练', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
              '首场景：偏好选择。填写选项后下发，星星会通过语音引导孩子；可在下方查看会话状态。',
              style: TextStyle(height: 1.45, color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            const Text('开场白（可选）', style: TextStyle(fontWeight: FontWeight.w600)),
            TextField(controller: _ttsIntroCtrl, maxLines: 2),
            const SizedBox(height: 12),
            const Text('选项（至少一项）', style: TextStyle(fontWeight: FontWeight.w600)),
            ..._optionCtrls.map((c) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(controller: c, decoration: const InputDecoration(isDense: true)),
                )),
            const SizedBox(height: 8),
            FilledButton(onPressed: _startTraining, child: const Text('下发到星星机器人')),
            if (_trainingSessionId != null) ...[
              const SizedBox(height: 16),
              Text('会话 #$_trainingSessionId · ${_trainingPhase.name} · $_lastSessionState'),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('日常计划（五条）', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
              '07:00 起床穿鞋 · 11:00 午饭选择 · 13:00 午睡 · 14:00 起床玩耍 · 18:00 晚饭菜品。\n'
              '云端会为各选项调用智谱生图，并把完整计划 JSON 推入星星队列。',
              style: TextStyle(height: 1.45, color: AppColors.muted),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _postDailyPlan,
              child: const Text('同步到机器人'),
            ),
          ],
        ),
      ),
    );
  }
}
