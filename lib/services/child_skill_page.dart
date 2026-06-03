import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/parent_child_profile.dart';
import '../services/cloud_service.dart';

const Color _warmCanvas = Color(0xFFFBF7F1);
const Color _warmSurface = Color(0xFFFFFCF7);
const Color _warmBorder = Color(0xFFE9DED0);
const Color _ink = Color(0xFF283238);
const Color _mutedInk = Color(0xFF76806F);
const Color _sage = Color(0xFF5F8F7A);
const Color _coral = Color(0xFFE87962);

class ChildSkillPage extends StatefulWidget {
  const ChildSkillPage({
    super.key,
    required this.cloudService,
    required this.childId,
    this.fallbackProfile,
  });

  final CloudService cloudService;
  final int childId;
  final ParentChildProfile? fallbackProfile;

  @override
  State<ChildSkillPage> createState() => _ChildSkillPageState();
}

class _ChildSkillPageState extends State<ChildSkillPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _avatarController;
  final TextEditingController _questionController = TextEditingController();
  ChildSkillData? _skill;
  bool _loading = true;
  bool _asking = false;
  String? _errorText;
  final List<_SkillMessage> _messages = <_SkillMessage>[];

  @override
  void initState() {
    super.initState();
    _avatarController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    unawaited(_loadSkill());
  }

  @override
  void dispose() {
    _avatarController.dispose();
    _questionController.dispose();
    super.dispose();
  }

  Future<void> _loadSkill() async {
    setState(() {
      _loading = true;
      _errorText = null;
    });
    final data = await widget.cloudService.fetchChildSkill(widget.childId);
    if (!mounted) return;
    if (data == null) {
      final fallback = widget.fallbackProfile;
      final fallbackSkill = fallback == null ? null : _fallbackSkill(fallback);
      setState(() {
        _skill = fallbackSkill;
        _loading = false;
        _errorText = fallback == null ? '暂时无法从云端读取孩子 Skill。' : '云端暂不可用，正在展示本机缓存。';
        _messages
          ..clear()
          ..addAll(fallbackSkill == null
              ? const <_SkillMessage>[]
              : <_SkillMessage>[_SkillMessage.bot(fallbackSkill.selfIntroduction)]);
      });
      return;
    }
    setState(() {
      _skill = data;
      _loading = false;
      _messages
        ..clear()
        ..add(_SkillMessage.bot(data.selfIntroduction.isEmpty ? data.summary : data.selfIntroduction));
    });
  }

  ChildSkillData _fallbackSkill(ParentChildProfile profile) {
    final displayName = profile.displayName;
    final traits = <String>[
      if (profile.age != null) '${profile.age} 岁',
      if ((profile.gender ?? '').trim().isNotEmpty) profile.gender!.trim(),
      if ((profile.personality ?? '').trim().isNotEmpty) '性格：${profile.personality!.trim()}',
      if ((profile.interests ?? '').trim().isNotEmpty) '喜欢：${profile.interests!.trim()}',
    ];
    final intro = '你好呀，我是 $displayName。${traits.isEmpty ? '' : '我有这些小特点：${traits.join('，')}。'}你可以问问我最近感觉如何。';
    return ChildSkillData(
      childId: profile.childId,
      profile: profile,
      displayName: displayName,
      summary: intro,
      selfIntroduction: intro,
      conversationStyle: '本地缓存展示',
      avatar: const ChildSkillAvatar(
        theme: 'sunny',
        primaryColor: '#F2B35D',
        accentColor: '#6FAF8E',
      ),
      quickQuestions: const ['我可以怎样帮助你？', '你最近感觉如何？', '你可以介绍下自己吗？'],
    );
  }

  Future<void> _ask(String rawQuestion) async {
    final question = rawQuestion.trim();
    if (question.isEmpty || _asking) return;
    setState(() {
      _asking = true;
      _messages.add(_SkillMessage.parent(question));
      _questionController.clear();
    });
    final response = await widget.cloudService.askChildSkill(widget.childId, question);
    if (!mounted) return;
    setState(() {
      _asking = false;
      _messages.add(
        _SkillMessage.bot(
          response?.answer.trim().isNotEmpty == true
              ? response!.answer.trim()
              : '我现在有点连不上云端，等一下再问我好吗？',
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final skill = _skill;
    return Scaffold(
      backgroundColor: _warmCanvas,
      appBar: AppBar(
        title: Text(skill == null ? '孩子 Skill' : '${skill.displayName} 的 Skill'),
        backgroundColor: _warmSurface,
        foregroundColor: _ink,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : skill == null
              ? _ErrorState(message: _errorText ?? '孩子 Skill 暂不可用', onRetry: _loadSkill)
              : SafeArea(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _SkillHeroCard(
                        skill: skill,
                        animation: _avatarController,
                        errorText: _errorText,
                      ),
                      const SizedBox(height: 14),
                      _QuickQuestionBar(
                        questions: skill.quickQuestions,
                        onTap: _ask,
                      ),
                      const SizedBox(height: 14),
                      _ConversationCard(
                        messages: _messages,
                        asking: _asking,
                        controller: _questionController,
                        onSubmit: _ask,
                      ),
                    ],
                  ),
                ),
    );
  }
}

class _SkillHeroCard extends StatelessWidget {
  const _SkillHeroCard({
    required this.skill,
    required this.animation,
    this.errorText,
  });

  final ChildSkillData skill;
  final Animation<double> animation;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: _warmSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: _warmBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: _AnimatedChildAvatar(skill: skill, animation: animation)),
            const SizedBox(height: 16),
            Text(
              skill.displayName,
              style: const TextStyle(
                color: _ink,
                fontSize: 24,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              skill.summary.isEmpty ? skill.selfIntroduction : skill.summary,
              style: const TextStyle(color: _mutedInk, height: 1.45),
            ),
            if (errorText != null) ...[
              const SizedBox(height: 10),
              Text(errorText!, style: const TextStyle(color: _coral, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}

class _AnimatedChildAvatar extends StatelessWidget {
  const _AnimatedChildAvatar({
    required this.skill,
    required this.animation,
  });

  final ChildSkillData skill;
  final Animation<double> animation;

  Color _hexColor(String raw, Color fallback) {
    final value = raw.replaceAll('#', '').trim();
    if (value.length != 6) return fallback;
    final parsed = int.tryParse('FF$value', radix: 16);
    return parsed == null ? fallback : Color(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final primary = _hexColor(skill.avatar.primaryColor, const Color(0xFFF2B35D));
    final accent = _hexColor(skill.avatar.accentColor, _sage);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final bob = math.sin(animation.value * math.pi) * 8;
        return Transform.translate(
          offset: Offset(0, -bob),
          child: SizedBox(
            width: 164,
            height: 184,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  bottom: 0,
                  child: Container(
                    width: 128,
                    height: 34,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 22,
                  child: Container(
                    width: 102,
                    height: 96,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.82),
                      borderRadius: BorderRadius.circular(34),
                    ),
                  ),
                ),
                Positioned(
                  top: 14,
                  child: Container(
                    width: 116,
                    height: 116,
                    decoration: BoxDecoration(
                      color: primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 5),
                    ),
                  ),
                ),
                Positioned(top: 60, left: 50, child: _eye()),
                Positioned(top: 60, right: 50, child: _eye()),
                Positioned(
                  top: 84,
                  child: Container(
                    width: 30,
                    height: 14,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: _ink.withValues(alpha: 0.72),
                          width: 3,
                        ),
                      ),
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _eye() {
    return Container(
      width: 12,
      height: 12,
      decoration: const BoxDecoration(color: _ink, shape: BoxShape.circle),
    );
  }
}

class _QuickQuestionBar extends StatelessWidget {
  const _QuickQuestionBar({
    required this.questions,
    required this.onTap,
  });

  final List<String> questions;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: questions
          .map(
            (question) => ActionChip(
              label: Text(question),
              backgroundColor: _warmSurface,
              side: const BorderSide(color: _warmBorder),
              onPressed: () => onTap(question),
            ),
          )
          .toList(),
    );
  }
}

class _ConversationCard extends StatelessWidget {
  const _ConversationCard({
    required this.messages,
    required this.asking,
    required this.controller,
    required this.onSubmit,
  });

  final List<_SkillMessage> messages;
  final bool asking;
  final TextEditingController controller;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: _warmSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: _warmBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            for (final message in messages) _MessageBubble(message: message),
            if (asking)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: '问问孩子 Skill...',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: onSubmit,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: asking ? null : () => onSubmit(controller.text),
                  child: const Text('发送'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final _SkillMessage message;

  @override
  Widget build(BuildContext context) {
    final align = message.isParent ? Alignment.centerRight : Alignment.centerLeft;
    final color = message.isParent ? _sage.withValues(alpha: 0.16) : _warmCanvas;
    return Align(
      alignment: align,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        constraints: const BoxConstraints(maxWidth: 290),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _warmBorder),
        ),
        child: Text(message.text, style: const TextStyle(color: _ink, height: 1.35)),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, color: _coral, size: 42),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: _mutedInk)),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

class _SkillMessage {
  const _SkillMessage({
    required this.text,
    required this.isParent,
  });

  factory _SkillMessage.parent(String text) {
    return _SkillMessage(text: text, isParent: true);
  }

  factory _SkillMessage.bot(String text) {
    return _SkillMessage(text: text, isParent: false);
  }

  final String text;
  final bool isParent;
}
