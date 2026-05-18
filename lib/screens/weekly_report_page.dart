import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Kimi 根据本周心率与家长记录生成的长文周报（供复盘与就医沟通参考）
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
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _data;

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
        Uri.parse('http://${widget.serverIp}:11760/weekly_report/latest'),
        headers: widget.headers,
      );
      if (!mounted) return;
      if (response.statusCode == 404) {
        setState(() {
          _data = null;
          _error = null;
          _loading = false;
        });
        return;
      }
      if (response.statusCode != 200) {
        setState(() {
          _error = '加载失败（${response.statusCode}）';
          _loading = false;
        });
        return;
      }
      final decoded = json.decode(response.body);
      if (decoded is! Map) {
        setState(() {
          _error = '数据格式异常';
          _loading = false;
        });
        return;
      }
      setState(() {
        _data = Map<String, dynamic>.from(decoded);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 深度洞察 · 周报',
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
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: _load, child: const Text('重试')),
        ],
      );
    }
    if (_data == null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          Card(
            elevation: 2,
            shadowColor: Colors.black12,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.article_outlined,
                          color: Colors.deepPurple.shade300, size: 22),
                      const SizedBox(width: 8),
                      Text(
                        '暂无周报',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '服务器会在每周日 21:00 左右，自动汇总本周心率与家长记录并调用 Kimi 生成周报。\n\n'
                    '也可由管理员在服务器上手动触发生成接口（需配置 MOONSHOT_API_KEY）。\n\n'
                    '有数据后下拉本页即可看到最新一篇。',
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

    final week = '${_data!['week_start'] ?? ''} ～ ${_data!['week_end'] ?? ''}';
    final created = _data!['created_at']?.toString() ?? '';
    final summary = _data!['summary']?.toString() ?? '';

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
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
                  child: Icon(Icons.calendar_month_rounded,
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
                        week,
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
              style: const TextStyle(
                fontSize: 15,
                height: 1.6,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '提示：周报为 AI 根据设备与记录生成的叙述性总结，不能替代医生或康复师面诊。',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500, height: 1.35),
          ),
        ),
      ],
    );
  }
}
