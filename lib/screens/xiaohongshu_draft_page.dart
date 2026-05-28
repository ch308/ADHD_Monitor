import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

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
  // X3: 记录用户是否手动编辑过内容
  bool _isDirty = false;

  // AI 配图相关状态
  Uint8List? _imageBytes;
  bool _generatingImage = false;
  String? _imageError;

  @override
  void initState() {
    super.initState();
    _loadDraft();
    // X3: 监听内容变化以设置脟硬标记
    _contentController.addListener(() {
      if (!_loading && !_isDirty) {
        setState(() => _isDirty = true);
      }
    });
    _titleController.addListener(() {
      if (!_loading && !_isDirty) {
        setState(() => _isDirty = true);
      }
    });
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
      ).timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (response.statusCode != 200) {
        // X1: 友好的错误提示
        String errMsg;
        final s = response.statusCode;
        if (s == 500 || s == 503) {
          errMsg = 'AI 服务暂时不可用，请稍后重试';
        } else if (s == 401 || s == 403) {
          errMsg = '登录已过期，请重新登录';
        } else {
          errMsg = '草稿生成失败，请稍后重试';
        }
        setState(() {
          _error = errMsg;
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
        _isDirty = false; // X3: 重新生成后清除脟硬标记
      });
    } catch (e) {
      if (!mounted) return;
      // X1: 网络错误用友好文案
      final s = e.toString();
      final msg = (s.contains('SocketException') ||
              s.contains('Connection refused') ||
              s.contains('Failed host lookup') ||
              s.contains('TimeoutException'))
          ? '无法连接服务器，请检查网络连接'
          : 'AI 服务暂时不可用，请稍后重试';
      setState(() {
        _error = msg;
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
      const SnackBar(content: Text('草稿已复制到剪贴板')),
    );
  }

  /// 复制文案 → 弹确认弹窗 → 用 URL Scheme 唤起小红书
  /// 小红书打开后，用户在发布框长按即可粘贴。
  /// 这是目前（2026）主流 App 分享到小红书的标准做法：
  /// 小红书未注册接收 text/plain 的 Android Intent，故系统分享面板无法直达。
  Future<void> _goToXiaohongshu() async {
    final text = _shareText();
    if (text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('草稿为空，请先填写内容')),
      );
      return;
    }

    // 1. 先复制到剪贴板
    await Clipboard.setData(ClipboardData(text: text));

    if (!mounted) return;

    // 2. 弹确认引导弹窗
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Color(0xFF4ECDC4), size: 22),
            SizedBox(width: 8),
            Text('文案已复制', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ],
        ),
        content: const Text(
          '点击「去小红书」后：\n\n'
          '① 小红书将自动打开\n'
          '② 点击右下角 ＋ 新建笔记\n'
          '③ 在正文区域长按 → 粘贴\n\n'
          '发布前请再次检查脱敏是否完整。',
          style: TextStyle(height: 1.6, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE91E63),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('去小红书'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    // 3. 尝试通过 URL Scheme 唤起小红书（iOS & Android 通用）
    const xhsScheme = 'xhsdiscover://';
    // Android 备用：Intent URI（直接调 Package）
    const xhsAndroidIntent =
        'intent://#Intent;package=com.xingin.xhs;action=android.intent.action.MAIN;end';

    bool launched = false;

    try {
      launched = await launchUrl(
        Uri.parse(xhsScheme),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}

    if (!launched) {
      try {
        launched = await launchUrl(
          Uri.parse(xhsAndroidIntent),
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {}
    }

    if (!launched && mounted) {
      // 4. 小红书未安装：引导跳应用市场
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('未检测到小红书', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          content: const Text(
            '文案已保存在剪贴板。\n请先安装小红书，或打开小红书后手动粘贴。',
            style: TextStyle(height: 1.55),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await launchUrl(
                  Uri.parse('https://www.xiaohongshu.com/'),
                  mode: LaunchMode.externalApplication,
                );
              },
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE91E63),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('打开小红书官网'),
            ),
          ],
        ),
      );
    }
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

  /// 生成 AI 配图
  Future<void> _generateImage() async {
    if (_generatingImage) return;
    setState(() {
      _generatingImage = true;
      _imageError = null;
    });
    try {
      final resp = await http.post(
        Uri.parse('http://${widget.serverIp}:11760/share/generate_image'),
        headers: widget.headers,
        body: json.encode({
          if (widget.logId != null) 'log_id': widget.logId,
          'observation': widget.observation,
          'advice': widget.advice,
          'condition_type': widget.conditionType,
        }),
      ).timeout(const Duration(seconds: 90));
      if (!mounted) return;
      if (resp.statusCode == 503) {
        final body = json.decode(resp.body);
        setState(() {
          _imageError = (body is Map ? body['message'] : null) ?? 'AI 配图功能未配置，请联系服务器管理员';
          _generatingImage = false;
        });
        return;
      }
      if (resp.statusCode != 200) {
        setState(() {
          _imageError = '配图生成失败，请稍后重试';
          _generatingImage = false;
        });
        return;
      }
      final decoded = json.decode(resp.body);
      final b64 = decoded['image_base64'] as String?;
      if (b64 == null || b64.isEmpty) {
        setState(() {
          _imageError = '服务器返回空图像，请重试';
          _generatingImage = false;
        });
        return;
      }
      setState(() {
        _imageBytes = base64Decode(b64);
        _imageError = null;
        _generatingImage = false;
      });
    } catch (e) {
      if (!mounted) return;
      final s = e.toString();
      setState(() {
        _imageError = (s.contains('SocketException') ||
                s.contains('Connection refused') ||
                s.contains('TimeoutException'))
            ? '无法连接服务器，请检查网络连接'
            : '配图生成失败，请稍后重试';
        _generatingImage = false;
      });
    }
  }

  /// 分享当前配图
  Future<void> _shareImage() async {
    final bytes = _imageBytes;
    if (bytes == null) return;
    try {
      final tmp = File('${Directory.systemTemp.path}/xhs_cover_${DateTime.now().millisecondsSinceEpoch}.png');
      await tmp.writeAsBytes(bytes);
      await Share.shareXFiles(
        [XFile(tmp.path, mimeType: 'image/png')],
        subject: '小红书配图',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('分享失败，请重试')),
      );
    }
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
            onPressed: _loading
                ? null
                : () async {
                    // X3: 用户手动编辑过内容，重新生成前确认
                    if (_isDirty) {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('重新生成草稿？'),
                          content: const Text('重新生成会覆盖你对内容的手动修改，确认继续吗？'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('重新生成'),
                            ),
                          ],
                        ),
                      );
                      if (ok != true) return;
                    }
                    await _loadDraft();
                  },
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
                    // ── 生成依据：展示原始行为记录，便于家长核验 ──
                    Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: const BorderSide(color: Color(0xFFEEF0F8)),
                      ),
                      child: ExpansionTile(
                        leading: const Icon(Icons.document_scanner_outlined,
                            color: Color(0xFF5B67CA), size: 22),
                        title: const Text(
                          '生成依据（点击展开核验）',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF5B67CA)),
                        ),
                        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                        expandedCrossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _SourceRow(
                            label: '行为记录',
                            value: widget.observation,
                            valueColor: const Color(0xFF1E2235),
                          ),
                          const SizedBox(height: 8),
                          _SourceRow(
                            label: 'AI 建议摘要',
                            value: widget.advice,
                            valueColor: Colors.grey.shade700,
                          ),
                          const SizedBox(height: 8),
                          _SourceRow(
                            label: '类型',
                            value: widget.conditionType == 'adhd' ? 'ADHD 多动症' : '自闭症谱系',
                            valueColor: Colors.grey.shade700,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    // ── 隐私提示 ──
                    Card(
                      color: Colors.pink.shade50,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
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
                    // ── AI 配图区域 ──
                    _buildImageSection(),
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
                        // X2: 小红书正文 1000 字限制，显示字数提示
                        counterText: '',
                      ),
                      minLines: 8,
                      maxLines: 14,
                      maxLength: 1000,
                      buildCounter: (ctx, {required currentLength, required isFocused, maxLength}) {
                        final remaining = (maxLength ?? 1000) - currentLength;
                        return Text(
                          '$currentLength / $maxLength，还可输入 $remaining 字',
                          style: TextStyle(
                            fontSize: 11,
                            color: remaining < 50 ? Colors.red.shade400 : Colors.grey.shade400,
                          ),
                        );
                      },
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
                    // ── 主操作：去小红书（复制 + URL Scheme 唤起）──
                    FilledButton.icon(
                      onPressed: _goToXiaohongshu,
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const Text('去小红书发布'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFE91E63),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // ── 次操作行：仅复制 / 系统分享 ──
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _copyDraft,
                            icon: const Icon(Icons.copy_rounded, size: 18),
                            label: const Text('仅复制'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFE91E63),
                              side: const BorderSide(color: Color(0xFFE91E63)),
                              padding: const EdgeInsets.symmetric(vertical: 13),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _shareDraft,
                            icon: const Icon(Icons.ios_share, size: 18),
                            label: const Text('其他 App'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.grey.shade600,
                              side: BorderSide(color: Colors.grey.shade300),
                              padding: const EdgeInsets.symmetric(vertical: 13),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '「去小红书发布」会自动复制文案并唤起小红书，进入后在发布页长按粘贴即可。',
                      style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
    );
  }

  /// 配图区域：未生成 → 按钮；生成中 → 菊花；已生成 → 图片 + 操作按钮；失败 → 错误提示
  Widget _buildImageSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 区域标题行
        Row(
          children: [
            const Icon(Icons.image_outlined, size: 16, color: Color(0xFF5B67CA)),
            const SizedBox(width: 6),
            const Text('AI 配图',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF5B67CA))),
            const Spacer(),
            if (_imageBytes != null && !_generatingImage)
              TextButton.icon(
                onPressed: _generateImage,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重新生成', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                    foregroundColor: Colors.grey.shade600,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
              ),
          ],
        ),
        const SizedBox(height: 8),

        // ── 状态：生成中 ──
        if (_generatingImage)
          Container(
            height: 200,
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF5B67CA)),
                  SizedBox(height: 12),
                  Text('AI 正在绘图，约 10–20 秒…',
                      style: TextStyle(color: Colors.black54, fontSize: 13)),
                ],
              ),
            ),
          ),

        // ── 状态：已生成图片 ──
        if (!_generatingImage && _imageBytes != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: 3 / 4,
              child: Image.memory(_imageBytes!, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _shareImage,
            icon: const Icon(Icons.ios_share, size: 18),
            label: const Text('保存 / 分享配图'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF5B67CA),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],

        // ── 状态：未生成 或 出错 ──
        if (!_generatingImage && _imageBytes == null) ...[
          if (_imageError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 14, color: Colors.red.shade400),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(_imageError!,
                        style: TextStyle(
                            fontSize: 12, color: Colors.red.shade600)),
                  ),
                ],
              ),
            ),
          OutlinedButton.icon(
            onPressed: _generateImage,
            icon: const Icon(Icons.auto_awesome_rounded, size: 18),
            label: const Text('生成 AI 配图'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF5B67CA),
              side: const BorderSide(color: Color(0xFF5B67CA)),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 4),
          Text('由阿里百炼·通义万象生成·3:4 竖版·适合小红书配图',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
              textAlign: TextAlign.center),
        ],
      ],
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Color(0xFF8A8FA8),
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value.isEmpty ? '（无）' : value,
          style: TextStyle(fontSize: 13, color: valueColor, height: 1.5),
        ),
      ],
    );
  }
}
