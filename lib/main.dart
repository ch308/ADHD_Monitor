import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/login_page.dart';
import 'services/app_mode_store.dart';
import 'services/session_store.dart';
import 'teacher/teacher_shell.dart';
import 'theme/app_theme.dart';

void main() => runApp(const AppModeShell());

class AppModeShell extends StatefulWidget {
  const AppModeShell({super.key});

  @override
  State<AppModeShell> createState() => _AppModeShellState();
}

class _AppModeShellState extends State<AppModeShell> {
  bool _loading = true;
  AppMode? _mode;

  @override
  void initState() {
    super.initState();
    _restoreMode();
  }

  Future<void> _restoreMode() async {
    final mode = await AppModeStore.getMode();
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _loading = false;
    });
  }

  Future<void> _chooseMode(AppMode mode) async {
    await AppModeStore.saveMode(mode);
    if (!mounted) return;
    setState(() => _mode = mode);
  }

  Future<void> _resetMode() async {
    await AppModeStore.clearMode();
    if (!mounted) return;
    setState(() => _mode = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return switch (_mode) {
      AppMode.parent => FamilyShell(onSwitchMode: _resetMode),
      AppMode.teacher => MaterialApp(
          theme: AppTheme.light,
          home: TeacherShell(onSwitchMode: _resetMode),
        ),
      null => MaterialApp(
          theme: AppTheme.light,
          home: _ModeChoicePage(onChooseMode: _chooseMode),
        ),
    };
  }
}

class _ModeChoicePage extends StatelessWidget {
  const _ModeChoicePage({required this.onChooseMode});

  final void Function(AppMode mode) onChooseMode;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        '请选择使用身份',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          color: AppColors.ink,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '家长版和教师版的数据、设备绑定与功能彼此隔离。',
                        style: TextStyle(height: 1.5, color: AppColors.muted),
                      ),
                      const SizedBox(height: 24),
                      _ModeCard(
                        icon: Icons.family_restroom_rounded,
                        title: '家长版',
                        subtitle: '适合家庭使用，多名家长共同关注一个孩子。',
                        onTap: () => onChooseMode(AppMode.parent),
                      ),
                      const SizedBox(height: 12),
                      _ModeCard(
                        icon: Icons.school_rounded,
                        title: '教师版',
                        subtitle: '适合课堂使用，本地监测最多 3 名学生手环。',
                        onTap: () => onChooseMode(AppMode.teacher),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              CircleAvatar(
                radius: 25,
                backgroundColor: AppColors.surfaceSoft,
                child: Icon(icon, color: AppColors.sage),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(subtitle, style: const TextStyle(height: 1.4)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

/// 登录态与当前孩子；切换孩子时重建 [AdhdMonitorApp] 以刷新轮询数据
class FamilyShell extends StatefulWidget {
  const FamilyShell({super.key, this.onSwitchMode});

  final VoidCallback? onSwitchMode;

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
      return MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    if (_token == null || _token!.isEmpty) {
      return MaterialApp(
        theme: AppTheme.light,
        home: LoginPage(
          serverIp: _serverIp,
          onLoggedIn: _onLoggedIn,
        ),
      );
    }
    return MaterialApp(
      theme: AppTheme.light,
      home: AdhdMonitorApp(
        key: ValueKey<int>(_childId),
        serverIp: _serverIp,
        authToken: _token,
        activeChildId: _childId,
        onLogout: _logout,
        onSwitchChild: _switchChild,
        onSwitchMode: widget.onSwitchMode,
      ),
    );
  }
}
