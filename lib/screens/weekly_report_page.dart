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
    _PeriodOption('week', '周报', '上一周'),
    _PeriodOption('month', '月报', '上个月'),
    _PeriodOption('year', '年报', '上一年'),
  ];

  String _periodType = 'week';
  bool _loading = true;
  bool _generating = false;
  String? _error;
  Map<String, dynamic>? _latest;
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

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final latestFuture = http.get(
        Uri.parse(
          'http://${widget.serverIp}:11760/reports/latest?period_type=$_periodType',
        ),
        headers: widget.headers,
      );
      final historyFuture = http.get(
        Uri.parse(
          'http://${widget.serverIp}:11760/reports/history?period_type=$_periodType&limit=12',
        ),
        headers: widget.headers,
      );
      final responses = await Future.wait([latestFuture, historyFuture]);
      if (!mounted) return;

      Map<String, dynamic>? latest;
      if (responses[0].statusCode == 200) {
        final decoded = json.decode(responses[0].body);
        if (decoded is Map) latest = Map<String, dynamic>.from(decoded);
      } else if (responses[0].statusCode != 404) {
        throw Exception('加载最新报告失败（${responses[0].statusCode}）');
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
      } else {
        throw Exception('加载历史报告失败（${responses[1].statusCode}）');
      }

      setState(() {
        _latest = latest;
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

  Future<void> _generateLatestCompleted() async {
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
      );
      if (!mounted) return;
      if (response.statusCode != 200) {
        setState(() {
          _error = '生成失败（${response.statusCode}）';
          _generating = false;
        });
        return;
      }
      final decoded = json.decode(response.body);
      if (decoded is! Map) {
        setState(() {
          _error = '数据格式异常';
          _generating = false;
        });
        return;
      }
      final payload = Map<String, dynamic>.from(decoded);
      final status = payload['status']?.toString() ?? '';
      if (status == 'not_ready') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(payload['message']?.toString() ?? '周期尚未结束')),
        );
      } else {
        _latest = payload;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(status == 'exists'
                ? '这个周期已经生成过，已为你打开已有报告'
                : '${_current.label}已生成'),
          ),
        );
      }
      setState(() => _generating = false);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _generating = false;
      });
    }
  }

  Future<void> _openReport(int id) async {
    try {
      final response = await http.get(
        Uri.parse('http://${widget.serverIp}:11760/reports/$id'),
        headers: widget.headers,
      );
      if (!mounted) return;
      if (response.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载报告失败（${response.statusCode}）')),
        );
        return;
      }
      final decoded = json.decode(response.body);
      if (decoded is Map) {
        setState(() => _latest = Map<String, dynamic>.from(decoded));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载报告失败：$e')),
      );
    }
  }

  void _changePeriod(String type) {
    if (_periodType == type) return;
    setState(() {
      _periodType = type;
      _latest = null;
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
        backgroundColor: Colors.transparent,
        elevation: 0,
        flexibleSpace: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF5E35B1), Color(0xFF7E57C2)],
            ),
            boxShadow: [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
        ),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
            tooltip: '刷新',
          ),
        ],
      ),
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
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
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
        ),
        const SizedBox(height: 12),
        if (_error != null) _buildErrorCard(),
        if (_latest == null) _buildEmptyCard() else _buildReportCard(_latest!),
        const SizedBox(height: 12),
        _buildHistoryCard(),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '提示：报告为 AI 根据设备心率与家长记录生成的叙述性总结，不能替代医生或康复师面诊。相同孩子、相同周期只生成一次，后续会直接查看已有报告。',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500, height: 1.35),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorCard() {
    return Card(
      color: Colors.red.shade50,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red.shade700),
            const SizedBox(width: 10),
            Expanded(child: Text(_error!)),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyCard() {
    return Card(
      elevation: 2,
      shadowColor: Colors.black12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.article_outlined,
                    color: Colors.deepPurple.shade300, size: 22),
                const SizedBox(width: 8),
                Text(
                  '暂无${_current.label}',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '不会后台自动批量生成。你可以在${_current.generateTarget}结束后，点击下方按钮为当前绑定的孩子生成一次${_current.label}。',
              style: TextStyle(color: Colors.grey.shade600, height: 1.5),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _generating ? null : _generateLatestCompleted,
                icon: _generating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                label: Text(_generating
                    ? '正在生成...'
                    : '生成${_current.generateTarget}${_current.label}'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReportCard(Map<String, dynamic> report) {
    final start = report['period_start']?.toString() ??
        report['week_start']?.toString() ??
        '';
    final end = report['period_end']?.toString() ??
        report['week_end']?.toString() ??
        '';
    final created = report['created_at']?.toString() ?? '';
    final summary = report['summary']?.toString() ?? '';

    return Column(
      children: [
        Card(
          elevation: 1,
          shadowColor: Colors.black12,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.deepPurple.shade50,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(_current.icon,
                      color: Colors.deepPurple.shade400, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('统计周期',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade500)),
                      Text(
                        '$start ～ $end',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                    ],
                  ),
                ),
                if (created.isNotEmpty)
                  Text(
                    created.substring(0, created.length > 10 ? 10 : created.length),
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 2,
          shadowColor: Colors.black12,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          color: Colors.deepPurple.shade50,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: SelectableText(
              summary,
              style: const TextStyle(fontSize: 15, height: 1.6),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHistoryCard() {
    return Card(
      elevation: 1,
      shadowColor: Colors.black12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.history, size: 20),
                const SizedBox(width: 8),
                Text(
                  '历史${_current.label}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _generating ? null : _generateLatestCompleted,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('生成'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_history.isEmpty)
              Text(
                '还没有历史${_current.label}',
                style: TextStyle(color: Colors.grey.shade600),
              )
            else
              ..._history.map((item) {
                final id = int.tryParse('${item['id']}');
                final start = item['period_start']?.toString() ?? '';
                final end = item['period_end']?.toString() ?? '';
                final preview = item['summary_preview']?.toString() ?? '';
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('$start ～ $end'),
                  subtitle: preview.isEmpty
                      ? null
                      : Text(
                          preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: id == null ? null : () => _openReport(id),
                );
              }),
          ],
        ),
      ),
    );
  }
}

class _PeriodOption {
  const _PeriodOption(this.type, this.label, this.generateTarget);

  final String type;
  final String label;
  final String generateTarget;

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
