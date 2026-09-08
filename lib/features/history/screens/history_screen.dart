import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/services/tts_service.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _tts = TtsService();
  String? _speakingId;
  String? _historyStreamUid;
  Stream<QuerySnapshot>? _historyStream;

  // สร้าง stream ใหม่เฉพาะตอน uid ของผู้ใช้ปัจจุบันเปลี่ยนไปจากตอนสร้าง stream
  // ล่าสุด (เช่น logout แล้ว login คนใหม่) แทนที่จะ cache ไว้ครั้งเดียวตอน
  // initState ซึ่งจะพลาดกรณี auth state เปลี่ยนหลังหน้านี้ถูกสร้างไปแล้ว
  Stream<QuerySnapshot>? get _currentHistoryStream {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != _historyStreamUid) {
      _historyStreamUid = uid;
      _historyStream = uid == null
          ? null
          : FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .collection('history')
              .orderBy('createdAt', descending: true)
              .snapshots();
    }
    return _historyStream;
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  Future<void> _speak(String id, String text, String emotion) async {
    if (_speakingId == id) {
      await _tts.stop();
      setState(() => _speakingId = null);
      return;
    }
    setState(() => _speakingId = id);
    await _tts.speak(text, emotion: emotion);
    _tts.setOnCompletionHandler(() {
      if (mounted) setState(() => _speakingId = null);
    });
  }

  void _showDeleteDialog(String id, String text) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('ลบประวัติ', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        content: Text('ต้องการลบ "$text"?',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ยกเลิก', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () { 
              // ลบข้อมูลออกจาก Firebase Firestore
              final userAuth = FirebaseAuth.instance.currentUser;
              if (userAuth != null) {
                FirebaseFirestore.instance
                  .collection('users')
                  .doc(userAuth.uid)
                  .collection('history')
                  .doc(id)
                  .delete();
              }
              Navigator.pop(ctx); 
            },
            child: const Text('ลบ', style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(String id, String initialText) {
    final textController = TextEditingController(text: initialText);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('แก้ไขข้อความ', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        content: TextField(
          controller: textController,
          decoration: InputDecoration(
            hintText: 'พิมพ์ข้อความใหม่',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppTheme.primary.withOpacity(0.3)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppTheme.primary, width: 2),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          autofocus: true,
          maxLines: null,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ยกเลิก', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () { 
              final newText = textController.text.trim();
              if (newText.isNotEmpty) {
                final userAuth = FirebaseAuth.instance.currentUser;
                if (userAuth != null) {
                  FirebaseFirestore.instance
                    .collection('users')
                    .doc(userAuth.uid)
                    .collection('history')
                    .doc(id)
                    .update({'text': newText});
                }
              }
              Navigator.pop(ctx); 
            },
            child: const Text('บันทึก', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userAuth = FirebaseAuth.instance.currentUser;

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
                child: userAuth == null 
                  ? const Center(child: Text('กรุณาล็อกอินเพื่อดูประวัติ', style: TextStyle(color: AppTheme.textHint)))
                  : StreamBuilder<QuerySnapshot>(
                    // ดึงข้อมูลประวัติจาก Firestore และจัดเรียงจากล่าสุดไปเก่าสุด
                    stream: _currentHistoryStream,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      
                      if (snapshot.hasError) {
                        return Center(child: Text('เกิดข้อผิดพลาด: ${snapshot.error}', style: const TextStyle(color: AppTheme.error)));
                      }

                      final docs = snapshot.data?.docs ?? [];
                      
                      if (docs.isEmpty) {
                        return const Center(
                          child: Text(
                            'ยังไม่มีประวัติคำพูด',
                            style: TextStyle(fontSize: 14, color: AppTheme.textHint),
                          ),
                        );
                      }

                      return ListView.separated(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                        itemCount: docs.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, i) {
                          final data = docs[i].data() as Map<String, dynamic>;
                          final id = docs[i].id;
                          final text = data['text'] ?? '';
                          final emotion = data['emotion'] ?? 'neutral';
                          
                          return _buildCard(id, text, emotion, i);
                        },
                      );
                    },
                  ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard(String id, String text, String emotion, int index) {
    final isSpeaking = _speakingId == id;

    return Container(
      padding: const EdgeInsets.only(left: 20, right: 8, top: 8, bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
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
              text,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: isSpeaking ? AppTheme.primary : AppTheme.textPrimary,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(
                  isSpeaking ? Icons.stop_circle_rounded : Icons.play_circle_fill_rounded,
                  color: isSpeaking ? AppTheme.error : AppTheme.primary,
                  size: 28,
                ),
                onPressed: () => _speak(id, text, emotion),
                tooltip: isSpeaking ? 'หยุด' : 'เล่นเสียง',
              ),
              IconButton(
                icon: const Icon(Icons.edit_rounded, color: AppTheme.textSecondary, size: 20),
                onPressed: () => _showEditDialog(id, text),
                tooltip: 'แก้ไข',
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, color: AppTheme.error, size: 20),
                onPressed: () => _showDeleteDialog(id, text),
                tooltip: 'ลบ',
              ),
            ],
          ),
        ],
      ),
    ).animate(delay: Duration(milliseconds: index * 50)).fadeIn().slideY(begin: 0.1);
  }
}