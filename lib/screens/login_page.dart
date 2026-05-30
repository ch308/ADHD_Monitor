import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/session_store.dart';
import '../theme/app_theme.dart';

/// 注册 / 登录后拉取「我的孩子」列表，并进入首页（默认选第一个孩子）
class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.serviceHost,
    required this.onLoggedIn,
  });

  final String serviceHost;
  final void Function(String token, int childId) onLoggedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _userLogin = TextEditingController();
  final _passLogin = TextEditingController();
  final _userReg = TextEditingController();
  final _passReg = TextEditingController();
  final _nameReg = TextEditingController();
  bool _busy = false;
  String? _err;
  // L1: 密码显示/隐藏开关
  bool _obscurePassLogin = true;
  bool _obscurePassReg = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _userLogin.dispose();
    _passLogin.dispose();
    _userReg.dispose();
    _passReg.dispose();
    _nameReg.dispose();
    super.dispose();
  }

  String _host() => widget.serviceHost;

  String _apiBase() => 'http://${_host()}:11760';

  String _sanitizeUserError(String? raw, String fallback) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return fallback;

    final containsAddress = RegExp(
      r'(https?://)|((\d{1,3}\.){3}\d{1,3})|(:\d{2,5})|([a-z0-9-]+\.)+[a-z]{2,}',
      caseSensitive: false,
    ).hasMatch(text);

    if (containsAddress) return fallback;
    return text;
  }

  String _networkErrorHint(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') ||
        s.contains('Connection refused') ||
        s.contains('Failed host lookup') ||
        s.contains('Network is unreachable') ||
        s.contains('TimeoutException')) {
      return '暂时连不上服务，请确认网络正常后稍后再试。';
    }
    return _sanitizeUserError(s, '现在暂时没能连上服务，请稍后再试。');
  }

  // L4: 从服务器响应体中提取可读的错误信息
  String _parseServerError(String body, String fallback) {
    try {
      final decoded = json.decode(body);
      if (decoded is Map) {
        final msg = decoded['message'] ?? decoded['error'] ?? decoded['detail'];
        if (msg != null && msg.toString().isNotEmpty) {
          return _sanitizeUserError(msg.toString(), fallback);
        }
      }
    } catch (_) {}
    return fallback;
  }

  Map<String, String> _jsonHeaders([String? bearer]) {
    final h = <String, String>{'Content-Type': 'application/json'};
    if (bearer != null && bearer.isNotEmpty) {
      h['Authorization'] = 'Bearer $bearer';
    }
    return h;
  }

  Future<int> _resolveChildIdAfterLogin(String token) async {
    final base = _apiBase();
    var r = await http.get(
      Uri.parse('$base/my/children'),
      headers: _jsonHeaders(token),
    ).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw Exception('拉取孩子列表失败 ${r.statusCode}');
    }
    final data = json.decode(r.body);
    final list = (data is Map && data['children'] is List) ? data['children'] as List : [];
    if (list.isEmpty) {
      final cr = await http.post(
        Uri.parse('$base/my/children'),
        headers: _jsonHeaders(token),
        body: json.encode({'nickname': '我的孩子'}),
      ).timeout(const Duration(seconds: 10));
      if (cr.statusCode != 200) {
        throw Exception('创建默认孩子失败 ${cr.statusCode}');
      }
      final cj = json.decode(cr.body);
      return (cj['child_id'] as num).toInt();
    }
    final first = list.first as Map<String, dynamic>;
    return (first['id'] as num).toInt();
  }

  Future<void> _doLogin() async {
    // L2: 客户端表单验证
    final user = _userLogin.text.trim();
    final pass = _passLogin.text;
    if (user.isEmpty) {
      setState(() => _err = '请输入用户名');
      return;
    }
    if (pass.isEmpty) {
      setState(() => _err = '请输入密码');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final r = await http.post(
        Uri.parse('${_apiBase()}/auth/login'),
        headers: _jsonHeaders(),
        body: json.encode({
          'username': user.toLowerCase(),
          'password': pass,
        }),
      ).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        // L4: 解析服务端错误信息
        setState(() => _err = _parseServerError(r.body, '用户名或密码不正确'));
        return;
      }
      final body = json.decode(r.body) as Map<String, dynamic>;
      final token = body['token']?.toString() ?? '';
      if (token.isEmpty) throw Exception('无 token');
      final cid = await _resolveChildIdAfterLogin(token);
      await SessionStore.saveToken(token);
      await SessionStore.saveChildId(cid);
      if (!mounted) return;
      await SessionStore.saveServerHost(_host());
      widget.onLoggedIn(token, cid);
    } catch (e) {
      setState(() => _err = _networkErrorHint(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doRegister() async {
    // L2: 客户端表单验证
    final user = _userReg.text.trim();
    final pass = _passReg.text;
    if (user.isEmpty) {
      setState(() => _err = '请输入用户名');
      return;
    }
    if (user.length < 3) {
      setState(() => _err = '用户名至少需要 3 位');
      return;
    }
    if (pass.isEmpty) {
      setState(() => _err = '请输入密码');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final r = await http.post(
        Uri.parse('${_apiBase()}/auth/register'),
        headers: _jsonHeaders(),
        body: json.encode({
          'username': user.toLowerCase(),
          'password': pass,
          'display_name': _nameReg.text.trim().isEmpty ? user : _nameReg.text.trim(),
        }),
      ).timeout(const Duration(seconds: 10));
      if (r.statusCode == 409) {
        setState(() => _err = '该用户名已被使用，请换一个');
        return;
      }
      if (r.statusCode != 200) {
        setState(() => _err = _parseServerError(r.body, '注册失败'));
        return;
      }
      if (!mounted) return;
      await SessionStore.saveServerHost(_host());
      if (!mounted) return;
      // L3: 注册成功后直接自动登录，无需手动切换 tab
      _userLogin.text = user.toLowerCase();
      _passLogin.text = pass;
      await _doLogin();
    } catch (e) {
      setState(() => _err = _networkErrorHint(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.canvas, AppColors.canvasAlt],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 24),
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.border,
                    width: 1.5,
                  ),
                ),
                child: const Icon(Icons.favorite_rounded,
                    color: AppColors.sage, size: 40),
              ),
              const SizedBox(height: 12),
              const Text(
                '专注陪伴',
                style: TextStyle(
                  color: AppColors.ink,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '家庭协作 · 共同守护',
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 13,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(28),
                      topRight: Radius.circular(28),
                    ),
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      Container(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 48, vertical: 12),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceSoft,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: TabBar(
                          controller: _tabs,
                          indicator: BoxDecoration(
                            color: AppColors.sage,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          indicatorSize: TabBarIndicatorSize.tab,
                          labelColor: Colors.white,
                          unselectedLabelColor: AppColors.muted,
                          labelStyle: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14),
                          dividerColor: Colors.transparent,
                          splashBorderRadius: BorderRadius.circular(10),
                          tabs: const [
                            Tab(text: '登录', height: 38),
                            Tab(text: '注册', height: 38),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Form content
                      Expanded(
                        child: TabBarView(
                          controller: _tabs,
                          children: [
                            _buildForm(
                              username: _userLogin,
                              password: _passLogin,
                              obscurePass: _obscurePassLogin,
                              onToggleObscure: () => setState(() => _obscurePassLogin = !_obscurePassLogin),
                              submitLabel: '进入家庭空间',
                              onSubmit: _doLogin,
                            ),
                            _buildForm(
                              username: _userReg,
                              password: _passReg,
                              obscurePass: _obscurePassReg,
                              onToggleObscure: () => setState(() => _obscurePassReg = !_obscurePassReg),
                              extra: TextField(
                                controller: _nameReg,
                                decoration: InputDecoration(
                                  labelText: '显示昵称（可选）',
                                  prefixIcon: Icon(Icons.badge_outlined,
                                      color: AppColors.sage,
                                      size: 20),
                                ),
                              ),
                              submitLabel: '注册账号',
                              onSubmit: _doRegister,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildForm({
    required TextEditingController username,
    required TextEditingController password,
    required bool obscurePass,
    required VoidCallback onToggleObscure,
    Widget? extra,
    required String submitLabel,
    required VoidCallback onSubmit,
  }) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        Text(
          '多个家长可用各自账号登录\n共同关注同一个孩子',
          style: const TextStyle(
              color: AppColors.muted, height: 1.4, fontSize: 13),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: username,
          decoration: InputDecoration(
            labelText: '用户名',
            hintText: '3–40 位，小写字母、数字、下划线',
            hintStyle:
                TextStyle(color: Colors.grey.shade400, fontSize: 12),
            prefixIcon: Icon(Icons.person_outline,
                color: AppColors.sage, size: 20),
          ),
          autocorrect: false,
        ),
        const SizedBox(height: 14),
        TextField(
          controller: password,
          obscureText: obscurePass,
          decoration: InputDecoration(
            labelText: '密码',
            prefixIcon: Icon(Icons.lock_outline,
                color: AppColors.sage, size: 20),
            // L1: 密码显示/隐藏切换按鈕
            suffixIcon: IconButton(
              icon: Icon(
                obscurePass ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                color: AppColors.muted,
                size: 20,
              ),
              onPressed: onToggleObscure,
              tooltip: obscurePass ? '显示密码' : '隐藏密码',
            ),
          ),
        ),
        if (extra != null) ...[const SizedBox(height: 14), extra],
        if (_err != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF0EA),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.coral.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded,
                    color: AppColors.coral, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child:
                      Text(_err!, style: const TextStyle(color: Color(0xFF8A493E), fontSize: 12, height: 1.35)),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _busy ? null : onSubmit,
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(submitLabel),
          ),
        ),
      ],
    );
  }
}
