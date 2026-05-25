import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';

class XiaohongshuDraftPage extends StatefulWidget {
  const XiaohongshuDraftPage({
    super.key,
    required this.serverIp,
    required this.headers,
    this.logId,
    required this.observation,
    required this.advice,
    required this.conditionType,
    required this.bpm,
  });

  final String serverIp;
  final Map<String, String> headers;
  final int? logId;
  final String observation;
  final String advice;
  final String conditionType;
  final double bpm;

  @override
  State<XiaohongshuDraftPage> createState() => _XiaohongshuDraftPageState();
}

class _XiaohongshuDraftPageState extends State<XiaohongshuDraftPage> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();
  final TextEditingController _tagsController = TextEditingController();

  bool _loading = true;
  String? _error;
  String _privacyNotice =
      '草稿会尽量脱敏，但发布前仍建议再次检查姓名、学校、住址、医院等隐私信息。';

  @override
  void initState() {
    super.initState();
    _loadDraft();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  Future<void> _loadDraft() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await http.post(
        Uri.parse('http://${widget.serverIp}:11760/share/xiaohongshu_draft'),
        headers: widget.headers,
        body: json.encode({
          if (widget.logId != null) 'log_id': widget.logId,
          'observation': widget.observation,
          'advice': widget.advice,
          'condition_type': widget.conditionType,
          'bpm': widget.bpm,
        }),
      );
      if (!mounted) return;
      if (response.statusCode != 200) {
        setState(() {
          _error = '生成失败（${response.statusCode}）';
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
      final draft = decoded['draft'];
      if (draft is! Map) {
        setState(() {
          _error = '草稿内容为空';
          _loading = false;
        });
        return;
      }
      final tags = (draft['tags'] as List?)
              ?.map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .join(' ') ??
          '';
      setState(() {
        _titleController.text = draft['title']?.toString() ?? '';
        _contentController.text = draft['content']?.toString() ?? '';
        _tagsController.text = tags;
        _privacyNotice =
            decoded['privacy_notice']?.toString() ?? _privacyNotice;
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

  String _shareText() {
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    final tags = _tagsController.text
        .split(RegExp(r'\s+'))
        .map((e) => e.trim().replaceFirst(RegExp(r'^#+'), ''))
        .where((e) => e.isNotEmpty)
        .map((e) => '#$e')
        .join(' ');
    return [
      if (title.isNotEmpty) title,
      if (content.isNotEmpty) content,
      if (tags.isNotEmpty) tags,
    ].join('\n\n');
  }

  Future<void> _copyDraft() async {
    await Clipboard.setData(ClipboardData(text: _shareText()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('草稿已复制，可以粘贴到小红书')),
    );
  }

  Future<void> _shareDraft() async {
    final text = _shareText();
    if (text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('草稿为空，无法分享')),
      );
      return;
    }
    await Share.share(text, subject: _titleController.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('小红书树洞草稿'),
        backgroundColor: const Color(0xFFE91E63),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新生成',
            onPressed: _loading ? null : _loadDraft,
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
                          onPressed: _loadDraft,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    Card(
                      color: Colors.pink.shade50,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.privacy_tip_outlined,
                                color: Colors.pink.shade400),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _privacyNotice,
                                style: TextStyle(
                                  color: Colors.pink.shade900,
                                  height: 1.45,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _titleController,
                      decoration: const InputDecoration(
                        labelText: '标题',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _contentController,
                      decoration: const InputDecoration(
                        labelText: '正文',
                        alignLabelWithHint: true,
                        border: OutlineInputBorder(),
                      ),
                      minLines: 8,
                      maxLines: 14,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _tagsController,
                      decoration: const InputDecoration(
                        labelText: '标签，用空格分隔',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _copyDraft,
                      icon: const Icon(Icons.copy),
                      label: const Text('复制草稿'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFE91E63),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _shareDraft,
                      icon: const Icon(Icons.ios_share),
                      label: const Text('打开系统分享面板'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFE91E63),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '提示：系统分享面板会让家长自己选择小红书等 App，最终发布前仍可继续编辑。',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
    );
  }
}
