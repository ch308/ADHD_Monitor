import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/login_page.dart';
import 'services/session_store.dart';

void main() => runApp(const MaterialApp(home: FamilyShell()));

/// 登录态与当前孩子；切换孩子时重建 [AdhdMonitorApp] 以刷新轮询数据
class FamilyShell extends StatefulWidget {
  const FamilyShell({super.key});

  @override
  State<FamilyShell> createState() => _FamilyShellState();
}

class _FamilyShellState extends State<FamilyShell> {
  String _serverIp = SessionStore.defaultServerHost;

  bool _loadingPrefs = true;
  String? _token;
  int _childId = 1;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final t = await SessionStore.getToken();
    final c = await SessionStore.getChildId();
    final h = await SessionStore.getServerHost();
    if (!mounted) return;
    setState(() {
      _token = t;
      _childId = c;
      _serverIp = h;
      _loadingPrefs = false;
    });
  }

  Future<void> _onLoggedIn(String token, int childId) async {
    final h = await SessionStore.getServerHost();
    if (!mounted) return;
    setState(() {
      _token = token;
      _childId = childId;
      _serverIp = h;
    });
  }

  Future<void> _logout() async {
    await SessionStore.clear();
    if (!mounted) return;
    setState(() {
      _token = null;
      _childId = 1;
    });
  }

  Future<void> _switchChild(int id) async {
    await SessionStore.saveChildId(id);
    if (!mounted) return;
    setState(() => _childId = id);
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingPrefs) {
      return const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    if (_token == null || _token!.isEmpty) {
      return MaterialApp(
        home: LoginPage(
          serverIp: _serverIp,
          onLoggedIn: _onLoggedIn,
        ),
      );
    }
    return MaterialApp(
      home: AdhdMonitorApp(
        key: ValueKey<int>(_childId),
        serverIp: _serverIp,
        authToken: _token,
        activeChildId: _childId,
        onLogout: _logout,
        onSwitchChild: _switchChild,
      ),
    );
  }
}
