import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// AI 周/月/年周期报告页。
///
/// 保留类名 [WeeklyReportPage] 以兼容现有入口；页面内部已升级为周报、月报、年报。
class WeeklyReportPage extends StatefulWidget {
  const WeeklyReportPage({
    super.key,
    required this.serverIp,
    required this.headers,
  });

  final String serverIp;
  final Map<String, String> headers;

  @override
  State<WeeklyReportPage> createState() => _WeeklyReportPageState();
}

class _WeeklyReportPageState extends State<WeeklyReportPage> {
  static const List<_PeriodOption> _periods = [
    _PeriodOption('week', '周报', '本周'),
    _PeriodOption('month', '月报', '本月'),
    _PeriodOption('year', '年报', '今年'),
  ];

  String _periodType = 'week';
  bool _loading = true;
  bool _generating = false;
  String? _error;
  // R1: 点击历史报告后自动滚动到顶部
  final ScrollController _scrollCtrl = ScrollController();

  // /reports/status 返回的数据
  Map<String, dynamic>? _status;
  // 当前查看的完整报告（latest 或点击历史加载）
  Map<String, dynamic>? _viewingReport;
  // 历史列表
  List<Map<String, dynamic>> _history = const [];

  _PeriodOption get _current =>
      _periods.firstWhere((p) => p.type == _periodType);

  Map<String, String> get _jsonHeaders => {
        ...widget.headers,
        'Content-Type': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final statusFuture = http.get(
        Uri.parse(
          'http://${widget.serverIp}:11760/reports/status?period_type=$_periodType',
        ),
        headers: widget.headers,
      ).timeout(const Duration(seconds: 10));
      final historyFuture = http.get(
        Uri.parse(
          'http://${widget.serverIp}:11760/reports/history?period_type=$_periodType&limit=12',
        ),
        headers: widget.headers,
      ).timeout(const Duration(seconds: 10));
      final responses = await Future.wait([statusFuture, historyFuture]);
      if (!mounted) return;

      Map<String, dynamic>? status;
      if (responses[0].statusCode == 200) {
        final decoded = json.decode(responses[0].body);
        if (decoded is Map) status = Map<String, dynamic>.from(decoded);
      } else {
        throw Exception('加载状态失败（${responses[0].statusCode}）');
      }

      List<Map<String, dynamic>> history = const [];
      if (responses[1].statusCode == 200) {
        final decoded = json.decode(responses[1].body);
        final raw = decoded is Map ? decoded['reports'] : null;
        if (raw is List) {
          history = raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      }

      // 如果上个周期已生成且当前没在查看别的报告，自动加载最新报告
      Map<String, dynamic>? viewing = _viewingReport;
      final lastPeriod = status?['last_period'];
      if (viewing == null &&
          lastPeriod is Map &&
          lastPeriod['status'] == 'generated') {
        viewing = await _fetchReport(lastPeriod['report_id']);
      }

      if (!mounted) return;
      setState(() {
        _status = status;
        _viewingReport = viewing;
        _history = history;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<Map<String, dynamic>?> _fetchReport(dynamic id) async {
    if (id == null) return null;
    try {
      final response = await http.get(
        Uri.parse('http://${widget.serverIp}:11760/reports/$id'),
        headers: widget.headers,
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  Future<void> _generate() async {
    if (_generating) return;
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final response = await http.post(
        Uri.parse('http://${widget.serverIp}:11760/reports/generate'),
        headers: _jsonHeaders,
        body: json.encode({'period_type': _periodType}),
      ).timeout(const Duration(seconds: 60));
      if (!mounted) return;
      if (response.statusCode != 200) {
        String errMsg = '生成失败';
        try {
          final body = json.decode(response.body);
          if (body is Map && body['message'] != null) {
            errMsg = '${body['message']}';
          }
        } catch (_) {}
        setState(() {
          _error = errMsg;
          _generating = false;
        });
        return;
      }
      final decoded = json.decode(response.body);
      if (decoded is! Map) {
        setState(() {
          _error = '返回数据格式异常';
          _generating = false;
        });
        return;
      }
      final payload = Map<String, dynamic>.from(decoded);
      final status = payload['status']?.toString() ?? '';
      if (status == 'not_ready') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(payload['message']?.toString() ?? '该周期尚未结束'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } else {
        setState(() => _viewingReport = payload);
      }
      setState(() => _generating = false);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '网络异常，请稍后重试';
        _generating = false;
      });
    }
  }

  Future<void> _openReport(int id) async {
    final report = await _fetchReport(id);
    if (!mounted) return;
    if (report != null) {
      setState(() => _viewingReport = report);
      // R1: 滚动到页面顶部让用户即刻看到报告内容
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            0,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut,
          );
        }
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('加载报告失败，请稍后重试'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _changePeriod(String type) {
    if (_periodType == type) return;
    setState(() {
      _periodType = type;
      _status = null;
      _viewingReport = null;
      _history = const [];
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 深度洞察',
            style: TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: const Color(0xFF5B67CA),
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _load,
            tooltip: '刷新',
          ),
        ],
      ),
      backgroundColor: const Color(0xFFF8F9FE),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _buildBody(),
            ),
    );
  }

  Widget _buildBody() {
    return ListView(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
      children: [
        // ── 周期切换 ──
        SegmentedButton<String>(
          segments: _periods
              .map(
                (p) => ButtonSegment<String>(
                  value: p.type,
                  label: Text(p.label),
                  icon: Icon(p.icon),
                ),
              )
              .toList(),
          selected: {_periodType},
          onSelectionChanged: (v) => _changePeriod(v.first),
          style: SegmentedButton.styleFrom(
            selectedBackgroundColor: const Color(0xFF5B67CA),
            selectedForegroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 14),

        // ── 错误提示 ──
        if (_error != null) ...[
          _buildErrorCard(),
          const SizedBox(height: 10),
        ],

        // ── ❶ 当前进行中周期 ──
        _buildCurrentPeriodCard(),
        const SizedBox(height: 10),

        // ── ❷ 上个周期状态 ──
        _buildLastPeriodCard(),
        const SizedBox(height: 14),

        // ── ❸ 正在查看的报告 ──
        if (_viewingReport != null) ...[
          _buildReportContent(_viewingReport!),
          const SizedBox(height: 14),
        ],

        // ── ❹ 历史列表 ──
        if (_history.isNotEmpty) _buildHistoryList(),

        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '报告由 AI 基于设备心率与家长记录生成，仅供家庭参考，不能替代医生或康复师面诊。',
            style: TextStyle(
                fontSize: 11, color: Colors.grey.shade500, height: 1.4),
          ),
        ),
      ],
    );
  }

  // ─────────────────── 错误卡片 ───────────────────

  Widget _buildErrorCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4F3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFCDD2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline_rounded,
                  color: Color(0xFFE53935), size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _error!,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFFB71C1C), height: 1.4),
                ),
              ),
            ],
          ),
          // R2: 错误卡片内联重试按鈕
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFE53935),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────── ❶ 当前进行中 ───────────────────

  Widget _buildCurrentPeriodCard() {
    final cur = _status?['current_period'];
    if (cur is! Map) return const SizedBox.shrink();

    final start = cur['start']?.toString() ?? '';
    final end = cur['end']?.toString() ?? '';
    final daysCollected = cur['days_collected'] ?? 0;
    final logCount = cur['log_count'] ?? 0;
    final daysRemaining = cur['days_remaining'] ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFEEF0F8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFF4ECDC4),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${_current.currentLabel}进行中',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Color(0xFF1E2235),
                ),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8FBF9),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '还剩 $daysRemaining 天',
                  style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF26A69A),
                      fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '$start ~ $end',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _MiniStat(
                  icon: Icons.favorite_rounded,
                  label: '心率天数',
                  value: '$daysCollected'),
              const SizedBox(width: 20),
              _MiniStat(
                  icon: Icons.edit_note_rounded,
                  label: '行为记录',
                  value: '$logCount'),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '${_current.currentLabel}结束后即可生成报告，期间持续佩戴设备和记录行为，报告内容会更完整哦～',
            style: TextStyle(
                fontSize: 12, color: Colors.grey.shade500, height: 1.4),
          ),
        ],
      ),
    );
  }

  // ─────────────────── ❷ 上个周期 ───────────────────

  Widget _buildLastPeriodCard() {
    final last = _status?['last_period'];
    if (last is! Map) return const SizedBox.shrink();

    final start = last['start']?.toString() ?? '';
    final end = last['end']?.toString() ?? '';
    final status = last['status']?.toString() ?? '';

    if (status == 'generated') {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFEEF0F8)),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle_rounded,
                color: Color(0xFF4ECDC4), size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_current.lastLabel}（$start ~ $end）',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '报告已生成，可在下方查看',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (status == 'ready') {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE8E0F7)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome_rounded,
                    color: Color(0xFF5B67CA), size: 20),
                const SizedBox(width: 8),
                Text(
                  '${_current.lastLabel}数据已就绪',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '$start ~ $end 的数据已收集完毕，可以生成 AI ${_current.label}了',
              style: TextStyle(
                  fontSize: 12, color: Colors.grey.shade600, height: 1.4),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _generating ? null : _generate,
                icon: _generating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.auto_awesome_rounded, size: 18),
                label: Text(
                    _generating ? '正在生成，请稍候…' : '生成 AI ${_current.label}'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF5B67CA),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // no_data
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFEEF0F8)),
      ),
      child: Row(
        children: [
          Icon(Icons.hourglass_empty_rounded,
              color: Colors.grey.shade400, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_current.lastLabel}（$start ~ $end）',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  '该周期没有收集到心率或行为数据，无法生成报告',
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade500, height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────── ❸ 报告内容（数据概览 + AI 洞察）───────────────────

  Widget _buildReportContent(Map<String, dynamic> report) {
    final start = report['period_start']?.toString() ?? '';
    final end = report['period_end']?.toString() ?? '';
    final summary = report['summary']?.toString() ?? '';
    final digest = report['digest'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 10),
          child: Row(
            children: [
              const Icon(Icons.insights_rounded,
                  size: 18, color: Color(0xFF5B67CA)),
              const SizedBox(width: 6),
              Text(
                '$start ~ $end ${_current.label}',
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: Color(0xFF1E2235)),
              ),
            ],
          ),
        ),

        // 数据概览卡
        if (digest is Map) _buildDigestCard(Map<String, dynamic>.from(digest)),

        const SizedBox(height: 10),

        // AI 洞察文字
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFEEF0F8)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.psychology_rounded,
                      size: 18, color: Colors.deepPurple.shade300),
                  const SizedBox(width: 6),
                  const Text(
                    'AI 洞察与建议',
                    style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SelectableText(
                summary,
                style: const TextStyle(
                    fontSize: 14, height: 1.7, color: Color(0xFF333333)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDigestCard(Map<String, dynamic> digest) {
    final heartCount = digest['heart_sample_count'] ?? 0;
    final heartAvg = digest['heart_avg_bpm'];
    final heartMin = digest['heart_min_bpm'];
    final heartMax = digest['heart_max_bpm'];
    final alertCount = digest['heart_alert_count'] ?? 0;
    final logs = digest['parent_logs'];
    final logCount = logs is List ? logs.length : 0;

    final hourlyStress = digest['hourly_stress_ranked'];
    String peakHint = '';
    if (hourlyStress is List && hourlyStress.isNotEmpty) {
      final top = hourlyStress.first;
      final bucket = top['bucket']?.toString() ?? '';
      if (bucket.length >= 13) {
        peakHint = '${bucket.substring(11, 13)}:00 时段';
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFF5F3FF), Color(0xFFEDE7F6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE8E0F7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '数据概览',
            style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Color(0xFF4A148C)),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _DataTile(
                  label: '平均心率',
                  value: heartAvg != null ? '${(heartAvg as num).round()}' : '-',
                  unit: 'BPM'),
              _DataTile(
                  label: '范围',
                  value: (heartMin != null && heartMax != null)
                      ? '${(heartMin as num).round()}~${(heartMax as num).round()}'
                      : '-',
                  unit: 'BPM'),
              _DataTile(
                  label: '报警',
                  value: '$alertCount',
                  unit: '次',
                  highlight: (alertCount as num) > 0),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _DataTile(
                  label: '心率采样', value: '$heartCount', unit: '条'),
              _DataTile(
                  label: '行为记录', value: '$logCount', unit: '次'),
              if (peakHint.isNotEmpty)
                _DataTile(label: '高峰时段', value: peakHint, unit: ''),
            ],
          ),
        ],
      ),
    );
  }

  // ─────────────────── ❹ 历史列表 ───────────────────

  Widget _buildHistoryList() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFEEF0F8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history_rounded,
                  size: 18, color: Color(0xFF5B67CA)),
              const SizedBox(width: 6),
              Text(
                '历史${_current.label}',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ],
          ),
          const Divider(height: 20),
          ..._history.map((item) {
            final id = int.tryParse('${item['id']}');
            final start = item['period_start']?.toString() ?? '';
            final end = item['period_end']?.toString() ?? '';
            final preview = item['summary_preview']?.toString() ?? '';
            final isViewing = _viewingReport != null &&
                '${_viewingReport!['id']}' == '${item['id']}';

            return InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: id == null ? null : () => _openReport(id),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                decoration: BoxDecoration(
                  color: isViewing
                      ? const Color(0xFFF3F0FF)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 4,
                      height: 32,
                      decoration: BoxDecoration(
                        color: isViewing
                            ? const Color(0xFF5B67CA)
                            : const Color(0xFFE0E0E0),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$start ~ $end',
                            style: TextStyle(
                              fontWeight: isViewing
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              fontSize: 13,
                              color: isViewing
                                  ? const Color(0xFF5B67CA)
                                  : const Color(0xFF1E2235),
                            ),
                          ),
                          if (preview.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                preview,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade500),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded,
                        size: 20, color: Colors.grey.shade400),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ═══════════════════ 辅助 Widget ═══════════════════

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: const Color(0xFF5B67CA)),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        const SizedBox(width: 4),
        Text(value,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1E2235))),
      ],
    );
  }
}

class _DataTile extends StatelessWidget {
  const _DataTile({
    required this.label,
    required this.value,
    required this.unit,
    this.highlight = false,
  });

  final String label;
  final String value;
  final String unit;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          const SizedBox(height: 3),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: highlight
                        ? const Color(0xFFFF7F72)
                        : const Color(0xFF1E2235),
                  ),
                ),
                if (unit.isNotEmpty)
                  TextSpan(
                    text: ' $unit',
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade500),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════ 数据类 ═══════════════════

class _PeriodOption {
  const _PeriodOption(this.type, this.label, this.currentLabel);

  final String type;
  final String label;
  final String currentLabel;

  String get lastLabel {
    switch (type) {
      case 'week':
        return '上周';
      case 'month':
        return '上月';
      case 'year':
        return '去年';
      default:
        return '上一周期';
    }
  }

  IconData get icon {
    switch (type) {
      case 'month':
        return Icons.calendar_month_rounded;
      case 'year':
        return Icons.event_note_rounded;
      default:
        return Icons.view_week_rounded;
    }
  }
}
