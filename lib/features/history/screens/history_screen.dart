import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/models/phrase_model.dart';
import '../../../shared/services/tts_service.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _tts = TtsService();
  String? _speakingId;

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  Future<void> _speak(PhraseModel phrase) async {
    if (_speakingId == phrase.id) {
      await _tts.stop();
      setState(() => _speakingId = null);
      return;
    }
    setState(() => _speakingId = phrase.id);
    await _tts.speak(phrase.text, emotion: phrase.emotion);
    _tts.setOnCompletionHandler(() {
      if (mounted) setState(() => _speakingId = null);
    });
  }

  void _showDeleteDialog(PhraseModel phrase) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('ลบประวัติ', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        content: Text('ต้องการลบ "${phrase.text}"?',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ยกเลิก', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () { phrase.delete(); Navigator.pop(ctx); },
            child: const Text('ลบ', style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 16),
              const Text(
                'History',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: ValueListenableBuilder(
                  valueListenable: Hive.box<PhraseModel>('phrases').listenable(),
                  builder: (context, box, _) {
                    final all = box.values.toList()
                      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
                    return _buildList(all);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList(List<PhraseModel> phrases) {
    if (phrases.isEmpty) {
      return const Center(
        child: Text(
          'ยังไม่มีประวัติคำพูด',
          style: TextStyle(fontSize: 14, color: AppTheme.textHint),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      itemCount: phrases.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) => _buildCard(phrases[i], i),
    );
  }

  Widget _buildCard(PhraseModel phrase, int index) {
    final isSpeaking = _speakingId == phrase.id;

    return GestureDetector(
      onLongPress: () => _showDeleteDialog(phrase),
      onTap: () => _speak(phrase),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: isSpeaking ? AppTheme.primary.withOpacity(0.5) : AppTheme.primary.withOpacity(0.15),
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                phrase.text,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: isSpeaking ? AppTheme.primary : AppTheme.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Container(
              width: 28, height: 28,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.primary,
              ),
              child: const Icon(Icons.chevron_right_rounded, color: Colors.white, size: 20),
            ),
          ],
        ),
      ),
    ).animate(delay: Duration(milliseconds: index * 50)).fadeIn().slideY(begin: 0.1);
  }
}
