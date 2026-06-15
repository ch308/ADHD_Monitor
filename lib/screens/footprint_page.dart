import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../theme/app_theme.dart';
import 'weekly_report_page.dart';

/// 今日记录次数、AI 建议列表、建议前后心率粗对比（价值呈现页）
class FootprintPage extends StatefulWidget {
  const FootprintPage({
    super.key,
    required this.serverIp,
    required this.headers,
  });

  final String serverIp;
  final Map<String, String> headers;

  @override
  State<FootprintPage> createState() => _FootprintPageState();
}

class _FootprintPageState extends State<FootprintPage> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _payload;

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
      final response = await http.get(
        Uri.parse('http://${widget.serverIp}:11760/footprint/today'),
        headers: widget.headers,
      ).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (response.statusCode != 200) {
        setState(() {
          _error = '这页内容暂时没打开成功，请稍后再试';
          _loading = false;
        });
        return;
      }
      final decoded = json.decode(response.body);
      if (decoded is! Map) {
        setState(() {
          _error = '这次内容没能读出来，请再试一次';
          _loading = false;
        });
        return;
      }
      setState(() {
        _payload = Map<String, dynamic>.from(decoded);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // F2: 友好的网络错误提示
      final s = e.toString();
      String msg;
      if (s.contains('SocketException') ||
          s.contains('Connection refused') ||
          s.contains('Failed host lookup') ||
          s.contains('Network is unreachable') ||
          s.contains('TimeoutException')) {
        msg = '网络好像不太稳定，请确认网络后再试';
      } else {
        msg = '这页内容暂时没打开成功，请稍后再试';
      }
      setState(() {
        _error = msg;
        _loading = false;
      });
    }
  }

  Color _trendColor(String code) {
    switch (code) {
      case 'improving':
        return Colors.green.shade700;
      case 'worsen':
        return Colors.deepOrange.shade700;
      case 'steady':
        return Colors.blueGrey.shade600;
      default:
        return Colors.grey.shade600;
    }
  }

  String _trendChipLabel(String code) {
    switch (code) {
      case 'improving':
        return '建议后缓和';
      case 'worsen':
        return '仍偏高';
      case 'steady':
        return '相对平稳';
      default:
        return '待观察';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: const Text('今日观察',
            style: TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: AppColors.canvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: AppColors.ink,
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_stories_outlined),
            tooltip: 'AI 报告',
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => WeeklyReportPage(
                    serverIp: widget.serverIp,
                    headers: widget.headers,
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
            tooltip: '刷新',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _load,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _buildBody(),
                ),
    );
  }

  Widget _buildBody() {
    final p = _payload!;
    final date = p['date']?.toString() ?? '';
    final focus = p['report_focus']?.toString() ?? 'adhd';
    final isAutism = focus == 'autism';
    final count = (p['log_count'] is int)
        ? p['log_count'] as int
        : int.tryParse('${p['log_count']}') ?? 0;
    final evCount = (p['training_event_count'] is int)
        ? p['training_event_count'] as int
        : int.tryParse('${p['training_event_count']}') ?? 0;
    final needCount = (p['child_need_count'] is int)
        ? p['child_need_count'] as int
        : int.tryParse('${p['child_need_count']}') ?? 0;
    final summary = p['trend_summary'];
    final logs = p['logs'];
    final autismEvents = p['autism_training_events'];
    final needs = p['child_initiated_needs'];

    final bool emptyAdhd = !isAutism && (count == 0 || logs is! List || logs.isEmpty);
    final bool emptyAutism = isAutism &&
        count == 0 &&
        evCount == 0 &&
        needCount == 0 &&
        (logs is! List || logs.isEmpty);

    if (emptyAdhd || emptyAutism) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          Card(
            elevation: 2,
            shadowColor: Colors.black12,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.today_rounded,
                          color: AppColors.sage, size: 22),
                      const SizedBox(width: 8),
                      Text(
                        date.isEmpty ? '今日' : date,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isAutism
                        ? '今天还没有孤独症相关的家长笔记、训练事件或主动发起记录。\n可在「孤独症」主页做日常训练、查看计划表，或使用「孤独症」类家长笔记记录。'
                        : '今天还没有行为记录。\n在首页心率报警时，使用「多动症 / 自闭症」入口记录一次，即可在这里看到 AI 建议与建议后的心率变化提示。',
                    style: TextStyle(
                        color: Colors.grey.shade600, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    int s(String k) {
      if (summary is! Map) return 0;
      final v = summary[k];
      if (v is int) return v;
      return int.tryParse('$v') ?? 0;
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Card(
          elevation: 2,
          shadowColor: Colors.black12,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          color: AppColors.surface,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.date_range_rounded,
                      color: AppColors.sage, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '$date · 今日记录',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: AppColors.ink,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  isAutism
                      ? '今日孤独症相关：家长笔记 $count 条 · 训练/计划事件 $evCount 条 · 主动发起 $needCount 条'
                      : '共 $count 次行为观察',
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink),
                ),
                const SizedBox(height: 14),
                if (!isAutism)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _SummaryChip(
                        label: '建议后缓和',
                        value: s('improving'),
                        color: Colors.green,
                      ),
                      _SummaryChip(
                        label: '相对平稳',
                        value: s('steady'),
                        color: Colors.blueGrey,
                      ),
                      _SummaryChip(
                        label: '仍偏高',
                        value: s('worsen'),
                        color: Colors.deepOrange,
                      ),
                      _SummaryChip(
                        label: '采样不足',
                        value: s('unknown'),
                        color: Colors.grey,
                      ),
                    ],
                  )
                else
                  Text(
                    '本页不对比心率；多动症孩子仍可在首页使用心率与行为足迹。',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.35),
                  ),
                const SizedBox(height: 10),
                if (!isAutism)
                  Text(
                    '说明：对比每条记录「提交前 15 分钟」与「提交后 20 分钟」内心率均值（需设备持续上报心率）。',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.35),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          isAutism ? '家长笔记（孤独症）' : '记录与 AI 建议',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 8),
        if (logs is List && logs.isNotEmpty)
          ...logs.map<Widget>((raw) {
          final item = raw is Map ? Map<String, dynamic>.from(raw) : {};
          final time = item['time']?.toString() ?? '';
          final label = item['condition_label']?.toString() ?? '';
          final obs = item['observation']?.toString() ?? '';
          final advice = item['ai_advice']?.toString() ?? '';
          final trend = item['trend_after']?.toString() ?? 'unknown';
          final trendText = item['trend_label']?.toString() ?? '';
          final bpm = item['bpm'];
          final avgB = item['avg_bpm_before'];
          final avgA = item['avg_bpm_after'];

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            elevation: 1.5,
            shadowColor: Colors.black12,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
            clipBehavior: Clip.antiAlias,
            child: IntrinsicHeight(
              child: Row(
                children: [
                  Container(
                    width: 4,
                    color: label.contains('自闭')
                        ? Colors.teal.shade400
                        : Colors.orange.shade400,
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                time,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: label.contains('自闭')
                                      ? Colors.teal.shade50
                                      : Colors.orange.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  label,
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      color: label.contains('自闭')
                                          ? Colors.teal.shade700
                                          : Colors.orange.shade700),
                                ),
                              ),
                              const Spacer(),
                              if (!isAutism)
                                Chip(
                                label: Text(_trendChipLabel(trend)),
                                backgroundColor:
                                    _trendColor(trend).withValues(alpha: 0.1),
                                side: BorderSide(
                                    color: _trendColor(trend)
                                        .withValues(alpha: 0.4)),
                                labelStyle: TextStyle(
                                  color: _trendColor(trend),
                                  fontWeight: FontWeight.w600,
                                  fontSize: 11,
                                ),
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ),
                          if (!isAutism && bpm != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                '记录时心率：$bpm BPM'
                                '${avgB != null && avgA != null ? '  （前均 $avgB → 后均 $avgA）' : ''}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ),
                          const SizedBox(height: 8),
                          Text('观察：$obs',
                              style: const TextStyle(fontSize: 14)),
                          const SizedBox(height: 6),
                          Text(
                            'AI 建议：$advice',
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.sage,
                            ),
                          ),
                          if (!isAutism && trendText.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              trendText,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade700,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
        if (isAutism && (logs is! List || logs.isEmpty))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '今日暂无「孤独症」类家长笔记。',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
          ),
        if (isAutism && autismEvents is List && autismEvents.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '训练与计划事件',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 6),
          ...autismEvents.map<Widget>((raw) {
            final e = raw is Map ? Map<String, dynamic>.from(raw) : {};
            final ts = (e['timestamp'] ?? e['ts'])?.toString() ?? '';
            final summaryZh = (e['summary_zh'] ?? '').toString().trim();
            final scene = e['scene']?.toString() ?? '';
            final phase = e['phase']?.toString() ?? '';
            final pl = e['payload'];
            var label = '';
            if (pl is Map) {
              label = pl['label']?.toString() ?? '';
            }
            if (label.isEmpty) {
              label = e['label']?.toString() ?? '';
            }
            final timePart =
                ts.contains(' ') ? ts.split(' ').skip(1).join(' ') : ts;
            final subtitle = summaryZh.isNotEmpty
                ? summaryZh
                : [
                    if (timePart.isNotEmpty) timePart,
                    if (label.isNotEmpty) label,
                  ].join(' · ');
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                dense: true,
                title: Text(
                  summaryZh.isNotEmpty ? '训练 / 计划记录' : '$scene · $phase',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ),
            );
          }),
        ],
        if (isAutism && needs is List && needs.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '孩子主动发起',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 6),
          ...needs.map<Widget>((raw) {
            final n = raw is Map ? Map<String, dynamic>.from(raw) : {};
            final lab = n['label']?.toString() ?? '';
            final st = n['status']?.toString() ?? '';
            final ca = n['created_at']?.toString() ?? '';
            final summaryZh = (n['summary_zh'] ?? '').toString().trim();
            final subtitle = summaryZh.isNotEmpty
                ? '$summaryZh · $st'
                : '$ca · $st';
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                dense: true,
                title: Text(
                  summaryZh.isNotEmpty ? '孩子主动选择' : (lab.isEmpty ? '（无标题）' : lab),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ),
            );
          }),
        ],
      ],
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: CircleAvatar(
        backgroundColor: color,
        child: Text(
          '$value',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      label: Text(label),
    );
  }
}
