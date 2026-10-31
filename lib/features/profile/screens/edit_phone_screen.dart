import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/services/phone_index_service.dart';
import '../../../shared/widgets/gradient_button.dart';

class EditPhoneScreen extends StatefulWidget {
  const EditPhoneScreen({super.key});
  @override
  State<EditPhoneScreen> createState() => _EditPhoneScreenState();
}

class _EditPhoneScreenState extends State<EditPhoneScreen> {
  final _formKey = GlobalKey<FormState>();
  final _ctrl = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadCurrentPhone();
  }

  // 🟢 ฟังก์ชันดึงเบอร์โทรเดิมจาก Firebase Firestore
  Future<void> _loadCurrentPhone() async {
    final userAuth = FirebaseAuth.instance.currentUser;
    if (userAuth != null) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(userAuth.uid)
            .get();
            
        if (doc.exists && mounted) {
          setState(() {
            _ctrl.text = doc.data()?['phone'] ?? '';
          });
        }
      } catch (e) {
        debugPrint('โหลดเบอร์โทรไม่สำเร็จ: $e');
      }
    }
  }

  @override
  void dispose() { 
    _ctrl.dispose(); 
    super.dispose(); 
  }

  // 🟢 ฟังก์ชันอัปเดตเบอร์โทรขึ้น Firebase Firestore
  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    
    setState(() => _isLoading = true);
    
    try {
      final userAuth = FirebaseAuth.instance.currentUser;
      if (userAuth != null) {
        final newPhone = _ctrl.text.trim();
        if (await PhoneIndexService.isTakenByOther(newPhone, userAuth.uid)) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('เบอร์โทรศัพท์นี้มีบัญชีอื่นใช้แล้ว'),
                backgroundColor: AppTheme.error,
              ),
            );
          }
          return;
        }
        await PhoneIndexService.changePhone(userAuth, newPhone);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('อัปเดตเบอร์โทรศัพท์สำเร็จ! ✅'),
              backgroundColor: Colors.green,
            ),
          );
          context.pop(); // เปลี่ยนเบอร์เสร็จแล้วให้กลับหน้าเดิม
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('เกิดข้อผิดพลาด: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => _EditScaffold(
    title: 'แก้ไขเบอร์โทรศัพท์', // เปลี่ยนชื่อ Title ให้เป็นภาษาไทยและตรงบริบท
    child: Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 80, // ปรับความกว้างนิดหน่อยเพื่อให้ข้อความไม่เบียด
                child: Text(
                  'เบอร์โทรศัพท์',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
              ),
              Expanded(
                child: TextFormField(
                  controller: _ctrl,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    hintText: 'กรอกเบอร์โทรใหม่',
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    fillColor: AppTheme.inputBg,
                    filled: true, // เพิ่ม filled: true เพื่อให้สีพื้นหลังทำงาน
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  validator: (v) => (v?.isEmpty == true) ? '*' : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 40),
          Center(
            child: SizedBox(
              width: 150,
              child: GradientButton(
                label: 'ยืนยัน', 
                isLoading: _isLoading, 
                onPressed: _save,
                // เอา isSecondary ออก เพราะปกติคุณไม่ได้ใช้พารามิเตอร์นี้
              ).animate(delay: 100.ms).fadeIn(),
            ),
          ),
        ],
      ),
    ),
  );
}

// Shared scaffold for edit screens
class _EditScaffold extends StatelessWidget {
  final String title;
  final Widget child;
  const _EditScaffold({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        height: double.infinity,
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => context.pop(),
                        child: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: AppTheme.textSecondary),
                      ),
                      Expanded(
                        child: Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 20), // Balance
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(32),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 24, offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: child,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}