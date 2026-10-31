import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/services/phone_index_service.dart';
import '../../../shared/widgets/gradient_button.dart';

class LinkEmailScreen extends StatefulWidget {
  const LinkEmailScreen({super.key});

  @override
  State<LinkEmailScreen> createState() => _LinkEmailScreenState();
}

class _LinkEmailScreenState extends State<LinkEmailScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  bool _isLoading = false;
  bool _obscurePass = true;

  // สถานะ Provider ที่เชื่อมต่ออยู่
  bool _hasEmailProvider = false;
  bool _hasGoogleProvider = false;
  bool _hasFacebookProvider = false;
  String _currentEmail = '';
  int _providerCount = 0;

  @override
  void initState() {
    super.initState();
    _loadProviders();
  }

  /// โหลดข้อมูล Provider ที่เชื่อมต่ออยู่จาก Firebase Auth
  void _loadProviders() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    bool hasEmail = false;
    bool hasGoogle = false;
    bool hasFacebook = false;

    for (final provider in user.providerData) {
      switch (provider.providerId) {
        case 'password':
          hasEmail = true;
          break;
        case 'google.com':
          hasGoogle = true;
          break;
        case 'facebook.com':
          hasFacebook = true;
          break;
      }
    }

    if (mounted) {
      setState(() {
        _hasEmailProvider = hasEmail;
        _hasGoogleProvider = hasGoogle;
        _hasFacebookProvider = hasFacebook;
        _currentEmail = user.email ?? '';
        _emailCtrl.text = _currentEmail;
        _providerCount = user.providerData.length;
      });
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  // ─── Helper: แสดง SnackBar ─────────────────────────────────────────────

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppTheme.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppTheme.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ─── ฟังก์ชัน: เชื่อมต่ออีเมล ─────────────────────────────────────────────

  void _showLinkEmailDialog() {
    _emailCtrl.clear();
    _passwordCtrl.clear();
    bool obscureText = true;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text('เชื่อมต่ออีเมล', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'กรุณากำหนดอีเมลและรหัสผ่านเพื่อใช้ล็อกอินในครั้งถัดไป',
                    style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      hintText: 'อีเมล',
                      prefixIcon: const Icon(Icons.email_outlined, color: AppTheme.primary, size: 20),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passwordCtrl,
                    obscureText: obscureText,
                    decoration: InputDecoration(
                      hintText: 'รหัสผ่าน (อย่างน้อย 6 ตัวอักษร)',
                      prefixIcon: const Icon(Icons.lock_outline_rounded, color: AppTheme.primary, size: 20),
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscureText ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                          color: AppTheme.textSecondary,
                          size: 20,
                        ),
                        onPressed: () => setDialogState(() => obscureText = !obscureText),
                      ),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('ยกเลิก', style: TextStyle(color: AppTheme.textSecondary)),
                ),
                TextButton(
                  onPressed: () {
                    final email = _emailCtrl.text.trim();
                    final password = _passwordCtrl.text;
                    if (email.isEmpty || password.length < 6) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('กรุณากรอกข้อมูลให้ครบและรหัสผ่านต้อง 6 ตัวขึ้นไป')),
                      );
                      return;
                    }
                    Navigator.pop(ctx);
                    _linkEmail(email, password);
                  },
                  child: const Text('เชื่อมต่อ', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _linkEmail(String email, String password) async {
    setState(() => _isLoading = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        _showError('ไม่พบข้อมูลผู้ใช้');
        return;
      }

      final credential = EmailAuthProvider.credential(email: email, password: password);
      await user.linkWithCredential(credential);

      // อัปเดต Firestore
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'email': email,
      });
      // ให้ล็อกอินด้วยเบอร์โทรชี้มาที่อีเมลที่เพิ่งเชื่อม
      await PhoneIndexService.ensureIndexed(user);

      _showSuccess('เชื่อมต่ออีเมลสำเร็จแล้ว!');
      _loadProviders();
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        _showError('อีเมลนี้ถูกใช้งานโดยบัญชีอื่นแล้ว');
      } else if (e.code == 'invalid-email') {
        _showError('รูปแบบอีเมลไม่ถูกต้อง');
      } else {
        _showError('ข้อผิดพลาด: ${e.message}');
      }
    } catch (e) {
      _showError('เกิดข้อผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─── ฟังก์ชัน: เชื่อมต่อ Google ────────────────────────────────────────

  Future<void> _linkWithGoogle() async {
    setState(() => _isLoading = true);
    try {
      final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      await FirebaseAuth.instance.currentUser!.linkWithCredential(credential);
      _showSuccess('เชื่อมต่อ Google สำเร็จ!');
      _loadProviders();
    } on FirebaseAuthException catch (e) {
      if (e.code == 'credential-already-in-use') {
        _showError('บัญชี Google นี้ถูกเชื่อมโยงกับบัญชีอื่นแล้ว');
      } else if (e.code == 'provider-already-linked') {
        _showError('บัญชีนี้เชื่อมต่อ Google อยู่แล้ว');
      } else {
        _showError('ข้อผิดพลาด: ${e.message}');
      }
    } catch (e) {
      _showError('เกิดข้อผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─── ฟังก์ชัน: ยกเลิกเชื่อมต่อ Google ─────────────────────────────────

  Future<void> _unlinkGoogle() async {
    if (_providerCount <= 1) {
      _showCannotUnlinkDialog();
      return;
    }

    final confirmed = await _showUnlinkConfirmDialog('Google');
    if (confirmed != true) return;

    setState(() => _isLoading = true);
    try {
      await FirebaseAuth.instance.currentUser!.unlink('google.com');
      _showSuccess('ยกเลิกเชื่อมต่อ Google สำเร็จ');
      _loadProviders();
    } on FirebaseAuthException catch (e) {
      _showError('ข้อผิดพลาด: ${e.message}');
    } catch (e) {
      _showError('เกิดข้อผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─── ฟังก์ชัน: เชื่อมต่อ Facebook ──────────────────────────────────────

  Future<void> _linkWithFacebook() async {
    setState(() => _isLoading = true);
    try {
      final LoginResult result = await FacebookAuth.instance.login(
        permissions: ['email', 'public_profile'],
      );

      if (result.status == LoginStatus.success) {
        final OAuthCredential credential =
            FacebookAuthProvider.credential(result.accessToken!.tokenString);
        await FirebaseAuth.instance.currentUser!.linkWithCredential(credential);
        _showSuccess('เชื่อมต่อ Facebook สำเร็จ!');
        _loadProviders();
      } else if (result.status == LoginStatus.cancelled) {
        // ผู้ใช้กดยกเลิก
      } else {
        _showError('ข้อผิดพลาด Facebook: ${result.message}');
      }
    } on FirebaseAuthException catch (e) {
      if (e.code == 'credential-already-in-use') {
        _showError('บัญชี Facebook นี้ถูกเชื่อมโยงกับบัญชีอื่นแล้ว');
      } else if (e.code == 'provider-already-linked') {
        _showError('บัญชีนี้เชื่อมต่อ Facebook อยู่แล้ว');
      } else {
        _showError('ข้อผิดพลาด: ${e.message}');
      }
    } catch (e) {
      _showError('เกิดข้อผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─── ฟังก์ชัน: ยกเลิกเชื่อมต่อ Facebook ───────────────────────────────

  Future<void> _unlinkFacebook() async {
    if (_providerCount <= 1) {
      _showCannotUnlinkDialog();
      return;
    }

    final confirmed = await _showUnlinkConfirmDialog('Facebook');
    if (confirmed != true) return;

    setState(() => _isLoading = true);
    try {
      await FirebaseAuth.instance.currentUser!.unlink('facebook.com');
      _showSuccess('ยกเลิกเชื่อมต่อ Facebook สำเร็จ');
      _loadProviders();
    } on FirebaseAuthException catch (e) {
      _showError('ข้อผิดพลาด: ${e.message}');
    } catch (e) {
      _showError('เกิดข้อผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─── Dialog: แจ้งเตือนไม่สามารถยกเลิก Provider สุดท้าย ────────────────

  void _showCannotUnlinkDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.warning_amber_rounded, color: AppTheme.warning, size: 48),
        title: const Text(
          'ไม่สามารถยกเลิกได้',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
        ),
        content: const Text(
          'คุณมีช่องทางเข้าสู่ระบบเพียงช่องทางเดียว หากยกเลิกจะไม่สามารถเข้าสู่ระบบได้อีก\n\nกรุณาเชื่อมต่อช่องทางอื่นก่อน เช่น อีเมล+รหัสผ่าน, Google หรือ Facebook',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('เข้าใจแล้ว', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ─── Dialog: ยืนยันก่อนยกเลิกการเชื่อมต่อ ─────────────────────────────

  Future<bool?> _showUnlinkConfirmDialog(String providerName) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'ยกเลิกเชื่อมต่อ $providerName?',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
        ),
        content: Text(
          'คุณจะไม่สามารถเข้าสู่ระบบด้วย $providerName ได้อีก จนกว่าจะเชื่อมต่อใหม่',
          style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('ยกเลิก', style: TextStyle(color: AppTheme.textHint, fontWeight: FontWeight.w600)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('ยืนยันยกเลิก', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  UI BUILD
  // ═══════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        leading: GestureDetector(
          onTap: () => context.pop(),
          child: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: AppTheme.textSecondary),
        ),
        title: const Text(
          'จัดการการเชื่อมต่อบัญชี',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
        ),
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: AppTheme.primary))
            : SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── ส่วนหัว: คำอธิบาย ──────────────────────
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline_rounded, color: AppTheme.primary, size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'เชื่อมต่อหลายช่องทางเพื่อให้คุณสามารถเข้าสู่ระบบได้สะดวกยิ่งขึ้น',
                              style: TextStyle(fontSize: 12, color: AppTheme.primary.withOpacity(0.9), height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    ).animate().fadeIn(duration: 300.ms),

                    const SizedBox(height: 28),

                    // ── Section: ช่องทางเข้าสู่ระบบ ─────────────
                    const Text(
                      'ช่องทางเข้าสู่ระบบ',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
                    ),
                    const SizedBox(height: 16),

                    // ── Card: Email / Password ──────────────────
                    _buildProviderCard(
                      icon: Icons.email_outlined,
                      iconColor: AppTheme.primary,
                      title: 'อีเมลและรหัสผ่าน',
                      subtitle: _hasEmailProvider ? _currentEmail : 'ยังไม่ได้เชื่อมต่อ',
                      isLinked: _hasEmailProvider,
                      onLink: _hasEmailProvider ? null : _showLinkEmailDialog,
                      onUnlink: null, // ไม่ให้ unlink email/password ตรงนี้
                      delay: 0,
                    ),

                    const SizedBox(height: 12),

                    // ── Card: Google ─────────────────────────────
                    _buildProviderCard(
                      icon: Icons.g_mobiledata_rounded,
                      iconColor: const Color(0xFFDB4437),
                      title: 'Google',
                      subtitle: _hasGoogleProvider
                          ? 'เชื่อมต่อแล้ว'
                          : 'ยังไม่ได้เชื่อมต่อ',
                      isLinked: _hasGoogleProvider,
                      onLink: _linkWithGoogle,
                      onUnlink: _unlinkGoogle,
                      delay: 50,
                    ),

                    const SizedBox(height: 12),

                    // ── Card: Facebook ───────────────────────────
                    _buildProviderCard(
                      icon: Icons.facebook_rounded,
                      iconColor: const Color(0xFF1877F2),
                      title: 'Facebook',
                      subtitle: _hasFacebookProvider
                          ? 'เชื่อมต่อแล้ว'
                          : 'ยังไม่ได้เชื่อมต่อ',
                      isLinked: _hasFacebookProvider,
                      onLink: _linkWithFacebook,
                      onUnlink: _unlinkFacebook,
                      delay: 100,
                    ),

                    const SizedBox(height: 32),


                    const SizedBox(height: 40),
                  ],
                ),
              ),
      ),
    );
  }

  // ─── Widget: Provider Card ──────────────────────────────────────────────

  Widget _buildProviderCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required bool isLinked,
    VoidCallback? onLink,
    VoidCallback? onUnlink,
    int delay = 0,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isLinked ? AppTheme.success.withOpacity(0.4) : Colors.grey.shade200,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          // ไอคอน Provider
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 26),
          ),
          const SizedBox(width: 14),

          // ข้อความ
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (isLinked)
                      Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: const BoxDecoration(
                          color: AppTheme.success,
                          shape: BoxShape.circle,
                        ),
                      ),
                    Flexible(
                      child: Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: isLinked ? AppTheme.success : AppTheme.textHint,
                          fontWeight: isLinked ? FontWeight.w500 : FontWeight.w400,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ปุ่มเชื่อมต่อ / ยกเลิก
          if (isLinked && onUnlink != null)
            _buildActionChip(
              label: 'ยกเลิก',
              color: AppTheme.error,
              onTap: onUnlink,
            )
          else if (!isLinked && onLink != null)
            _buildActionChip(
              label: 'เชื่อมต่อ',
              color: AppTheme.primary,
              onTap: onLink,
            ),
        ],
      ),
    ).animate(delay: Duration(milliseconds: delay)).fadeIn().slideX(begin: 0.05);
  }

  // ─── Widget: ปุ่ม Chip (เชื่อมต่อ / ยกเลิก) ────────────────────────────

  Widget _buildActionChip({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
        ),
      ),
    );
  }


}
