import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/session_store.dart';

/// 注册 / 登录后拉取「我的孩子」列表，并进入首页（默认选第一个孩子）
class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.serverIp,
    required this.onLoggedIn,
  });

  final String serverIp;
  final void Function(String token, int childId) onLoggedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final TextEditingController _serverHost;
  final _userLogin = TextEditingController();
  final _passLogin = TextEditingController();
  final _userReg = TextEditingController();
  final _passReg = TextEditingController();
  final _nameReg = TextEditingController();
  bool _busy = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _serverHost = TextEditingController(text: widget.serverIp);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _serverHost.dispose();
    _userLogin.dispose();
    _passLogin.dispose();
    _userReg.dispose();
    _passReg.dispose();
    _nameReg.dispose();
    super.dispose();
  }

  /// 当前请求使用的主机（域名或 IP），端口固定 11760
  String _host() {
    final t = _serverHost.text.trim();
    if (t.isEmpty) return widget.serverIp;
    return t;
  }

  String _apiBase() => 'http://${_host()}:11760';

  String _networkErrorHint(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') ||
        s.contains('Connection refused') ||
        s.contains('Failed host lookup') ||
        s.contains('Network is unreachable')) {
      return '无法连接服务器 ${_host()}:11760。\n'
          '请检查：① 手机/电脑与服务器网络是否互通；② 云主机安全组与本机防火墙是否放行 TCP 11760；'
          '③ 服务器上是否已运行 Flask（监听 0.0.0.0:11760）；'
          '④ Android 模拟器访问本机请填 10.0.2.2。';
    }
    return s;
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
    );
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
      );
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
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final r = await http.post(
        Uri.parse('${_apiBase()}/auth/login'),
        headers: _jsonHeaders(),
        body: json.encode({
          'username': _userLogin.text.trim().toLowerCase(),
          'password': _passLogin.text,
        }),
      );
      if (r.statusCode != 200) {
        setState(() => _err = '登录失败：${r.body}');
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
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final r = await http.post(
        Uri.parse('${_apiBase()}/auth/register'),
        headers: _jsonHeaders(),
        body: json.encode({
          'username': _userReg.text.trim().toLowerCase(),
          'password': _passReg.text,
          'display_name': _nameReg.text.trim().isEmpty
              ? _userReg.text.trim()
              : _nameReg.text.trim(),
        }),
      );
      if (r.statusCode == 409) {
        setState(() => _err = '该用户名已被使用，请换一个');
        return;
      }
      if (r.statusCode != 200) {
        setState(() => _err = '注册失败：${r.body}');
        return;
      }
      if (!mounted) return;
      await SessionStore.saveServerHost(_host());
      if (!mounted) return;
      _userLogin.text = _userReg.text.trim().toLowerCase();
      _passLogin.text = _passReg.text;
      _tabs.animateTo(0);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('注册成功，请使用同一密码登录')),
      );
    } catch (e) {
      setState(() => _err = _networkErrorHint(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF1A237E),
              Color(0xFF3949AB),
              Color(0xFF5C6BC0),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 24),
              // Logo area
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.favorite_rounded,
                    color: Colors.white, size: 40),
              ),
              const SizedBox(height: 12),
              const Text(
                'ADHD 专注精灵',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '家庭协作 · 共同守护',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 24),
              // Main card
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(28),
                      topRight: Radius.circular(28),
                    ),
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      // Tab bar
                      Container(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 48, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: TabBar(
                          controller: _tabs,
                          indicator: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF3949AB), Color(0xFF5C6BC0)],
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          indicatorSize: TabBarIndicatorSize.tab,
                          labelColor: Colors.white,
                          unselectedLabelColor: Colors.black54,
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
                      const SizedBox(height: 4),
                      // Server host field
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: TextField(
                          controller: _serverHost,
                          decoration: InputDecoration(
                            labelText: '服务器地址',
                            hintText: '域名或 IP（端口固定 11760）',
                            hintStyle: TextStyle(
                                color: Colors.grey.shade400, fontSize: 13),
                            prefixIcon: Icon(Icons.dns_outlined,
                                color: Colors.indigo.shade300, size: 20),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide:
                                  BorderSide(color: Colors.grey.shade300),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide:
                                  BorderSide(color: Colors.grey.shade200),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(
                                  color: Color(0xFF5C6BC0), width: 1.5),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            filled: true,
                            fillColor: Colors.grey.shade50,
                          ),
                          autocorrect: false,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Form content
                      Expanded(
                        child: TabBarView(
                          controller: _tabs,
                          children: [
                            _buildForm(
                              username: _userLogin,
                              password: _passLogin,
                              submitLabel: '进入家庭空间',
                              onSubmit: _doLogin,
                            ),
                            _buildForm(
                              username: _userReg,
                              password: _passReg,
                              extra: TextField(
                                controller: _nameReg,
                                decoration: InputDecoration(
                                  labelText: '显示昵称（可选）',
                                  prefixIcon: Icon(Icons.badge_outlined,
                                      color: Colors.indigo.shade300,
                                      size: 20),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: BorderSide(
                                        color: Colors.grey.shade200),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: const BorderSide(
                                        color: Color(0xFF5C6BC0), width: 1.5),
                                  ),
                                  contentPadding:
                                      const EdgeInsets.symmetric(
                                          horizontal: 14, vertical: 12),
                                  filled: true,
                                  fillColor: Colors.grey.shade50,
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
    Widget? extra,
    required String submitLabel,
    required VoidCallback onSubmit,
  }) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        Text(
          '多个家长可用各自账号登录\n共同关注同一个孩子',
          style: TextStyle(
              color: Colors.grey.shade600, height: 1.4, fontSize: 13),
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
                color: Colors.indigo.shade300, size: 20),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade200),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
                  const BorderSide(color: Color(0xFF5C6BC0), width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 12),
            filled: true,
            fillColor: Colors.grey.shade50,
          ),
          autocorrect: false,
        ),
        const SizedBox(height: 14),
        TextField(
          controller: password,
          decoration: InputDecoration(
            labelText: '密码',
            prefixIcon: Icon(Icons.lock_outline,
                color: Colors.indigo.shade300, size: 20),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade200),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
                  const BorderSide(color: Color(0xFF5C6BC0), width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 12),
            filled: true,
            fillColor: Colors.grey.shade50,
          ),
          obscureText: true,
        ),
        if (extra != null) ...[const SizedBox(height: 14), extra],
        if (_err != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline,
                    color: Colors.red.shade400, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child:
                      Text(_err!, style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF3949AB), Color(0xFF5C6BC0)],
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF3949AB).withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _busy ? null : onSubmit,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 15),
                child: Center(
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          submitLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
