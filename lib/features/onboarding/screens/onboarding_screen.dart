import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';

/// หน้าแนะนำการใช้งานที่แสดงก่อนเข้าสู่ระบบทุกครั้งที่ยังไม่ได้ล็อกอิน
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageCtrl = PageController();
  int _page = 0;

  static const _pages = <_OnboardingPage>[
    // หน้าแรก บอกให้ชัดว่าแอปนี้คืออะไรและช่วยอะไรได้ — โลโก้จริงของแอปเป็น
    // ภาพหลักของหน้า ไม่ใช้ภาพประกอบคนวาดเอง (ลองแล้วผู้ใช้บอกว่าไม่สวย)
    _OnboardingPage(
      title: 'LipsLink',
      description: 'สื่อสารด้วยริมฝีปาก\nให้ทุกคำพูดถูกเข้าใจ',
      icon: Icons.record_voice_over_rounded,
      accent: AppTheme.primary,
      heroLogo: true,
    ),
    // หน้าสอง สอนวิธีใช้เป็นขั้นตอน อ่านแล้วทำตามได้ทันที
    _OnboardingPage(
      title: 'วิธีใช้งาน',
      icon: Icons.center_focus_strong_rounded,
      accent: AppTheme.secondary,
      showFaceScan: true,
      steps: [
        'หันหน้าเข้ากล้อง ให้ใบหน้าอยู่ในกรอบ',
        'พูดเป็นวลีสั้นๆ ช้าๆ และชัดเจน',
        'ข้อความจะทยอยขึ้นระหว่างที่คุณพูด',
      ],
    ),
    _OnboardingPage(
      title: 'ฟังเสียงและเก็บไว้ใช้ซ้ำ',
      description:
          'กดให้แอปอ่านออกเสียงแทนคุณได้ทันที\nและบันทึกวลีที่ใช้บ่อยไว้ดูย้อนหลังในประวัติ',
      icon: Icons.volume_up_rounded,
      accent: AppTheme.primaryDark,
      showVoiceHistory: true,
    ),
  ];

  bool get _isLastPage => _page == _pages.length - 1;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  void _finish() => context.go('/login');

  void _next() {
    if (_isLastPage) {
      _finish();
      return;
    }
    _pageCtrl.nextPage(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = _pages[_page].accent;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: Stack(
          children: [
            // วงกลมจางๆ ด้านหลังเพื่อไม่ให้พื้นหลังโล่งเป็นสีเรียบทั้งจอ
            _buildBlob(top: -70, right: -50, size: 220, color: accent),
            _buildBlob(bottom: -60, left: -70, size: 260, color: accent),
            SafeArea(
              child: Column(
                children: [
                  SizedBox(
                    height: 48,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: AnimatedOpacity(
                        opacity: _isLastPage ? 0 : 1,
                        duration: const Duration(milliseconds: 200),
                        child: TextButton(
                          onPressed: _isLastPage ? null : _finish,
                          child: const Text(
                            'ข้าม',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: PageView.builder(
                      controller: _pageCtrl,
                      itemCount: _pages.length,
                      onPageChanged: (i) => setState(() => _page = i),
                      itemBuilder: (context, i) => _buildCard(_pages[i]),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _buildDots(accent),
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
                    child: SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton(
                        onPressed: _next,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: Colors.white,
                          elevation: 3,
                          shadowColor: accent.withOpacity(0.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              _isLastPage ? 'เริ่มต้นใช้งาน' : 'ถัดไป',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              _isLastPage
                                  ? Icons.check_rounded
                                  : Icons.arrow_forward_rounded,
                              size: 20,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBlob({
    double? top,
    double? bottom,
    double? left,
    double? right,
    required double size,
    required Color color,
  }) {
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withOpacity(0.10),
        ),
      ),
    );
  }

  Widget _buildCard(_OnboardingPage page) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      child: Center(
        child: SingleChildScrollView(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(32),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withOpacity(0.13),
                  blurRadius: 30,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: page.steps != null
                // หน้าวิธีใช้งาน: หัวข้อขึ้นก่อนบนสุด แล้วค่อยภาพประกอบ ตามที่
                // ปรับจากดีไซน์อ้างอิง (เดิมภาพประกอบขึ้นก่อนหัวข้อ)
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        page.title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 24),
                      _buildArtwork(page),
                      const SizedBox(height: 28),
                      _buildSteps(page),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (page.heroLogo) ...[
                        _buildLogoHero(page),
                        const SizedBox(height: 20),
                      ] else ...[
                        _buildArtwork(page),
                        const SizedBox(height: 32),
                      ],
                      Text(
                        page.title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: page.heroLogo ? 28 : 24,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        page.description ?? '',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.6,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      if (page.showVoiceHistory) ...[
                        const SizedBox(height: 24),
                        CustomPaint(
                          size: const Size(180, 150),
                          painter: _VoiceHistoryPainter(accent: page.accent),
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  /// ขั้นตอนการใช้งานแบบมีเลขกำกับ อ่านแล้วทำตามได้เป็นลำดับ
  Widget _buildSteps(_OnboardingPage page) {
    final steps = page.steps!;
    return Column(
      children: List.generate(steps.length, (i) {
        return Padding(
          padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: page.accent.withOpacity(0.15),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${i + 1}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: page.accent,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    steps[i],
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.5,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  /// หน้าแรก: โลโก้จริงขนาดใหญ่ลอยอยู่บนวงแสงจางๆ แทนภาพประกอบวงกลม+ไอคอน
  Widget _buildLogoHero(_OnboardingPage page) {
    return Container(
      width: 176,
      height: 176,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [page.accent.withOpacity(0.14), page.accent.withOpacity(0)],
        ),
      ),
      alignment: Alignment.center,
      child: Image.asset(
        'assets/images/lipslinklogo.png',
        width: 128,
        height: 128,
        fit: BoxFit.contain,
      ),
    );
  }

  /// วงกลมนุ่มๆ ชั้นเดียวรองหลังภาพประกอบ ตามดีไซน์อ้างอิง (เดิมซ้อน 3 ชั้น
  /// พร้อมแผ่นขาว+เงาแยกต่างหาก ซึ่งดูรกเกินความจำเป็น)
  Widget _buildArtwork(_OnboardingPage page) {
    return Container(
      width: 190,
      height: 190,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: page.accent.withOpacity(0.10),
      ),
      alignment: Alignment.center,
      child: page.showFaceScan
          ? CustomPaint(
              size: const Size(190, 190),
              painter: _FaceScanPainter(color: page.accent),
            )
          : Icon(page.icon, size: 52, color: page.accent),
    );
  }

  Widget _buildDots(Color accent) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_pages.length, (i) {
        final active = i == _page;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: active ? 26 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: active ? accent : accent.withOpacity(0.28),
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}

/// ลำโพงปล่อยคลื่นเสียง พร้อมวลีที่บันทึกไว้ลอยอยู่ด้านหลัง — ตรงกับดีไซน์ที่
/// เลือกไว้ในแคนวาส แทนไอคอนลำโพงเดี่ยวๆ
class _VoiceHistoryPainter extends CustomPainter {
  final Color accent;

  const _VoiceHistoryPainter({required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // ── การ์ดพื้นหลัง ──
    final cardRect = Rect.fromLTWH(w * 0.11, h * 0.06, w * 0.42, h * 0.72);
    canvas.drawRRect(
      RRect.fromRectAndRadius(cardRect, Radius.circular(w * 0.09)),
      Paint()..color = accent.withOpacity(0.08),
    );

    // ── ไอคอนลำโพง ──
    final speaker = Path()
      ..moveTo(cardRect.left + w * 0.11, cardRect.top + h * 0.25)
      ..lineTo(cardRect.left + w * 0.11, cardRect.top + h * 0.39)
      ..lineTo(cardRect.left + w * 0.18, cardRect.top + h * 0.39)
      ..lineTo(cardRect.left + w * 0.28, cardRect.top + h * 0.47)
      ..lineTo(cardRect.left + w * 0.28, cardRect.top + h * 0.17)
      ..lineTo(cardRect.left + w * 0.18, cardRect.top + h * 0.25)
      ..close();
    canvas.drawPath(speaker, Paint()..color = accent);

    final waveStroke = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.018
      ..strokeCap = StrokeCap.round;
    final waveCenter = Offset(cardRect.left + w * 0.30, cardRect.top + h * 0.32);
    canvas.drawArc(
      Rect.fromCenter(center: waveCenter, width: w * 0.14, height: h * 0.18),
      -0.7,
      1.4,
      false,
      waveStroke,
    );
    canvas.drawArc(
      Rect.fromCenter(center: waveCenter, width: w * 0.22, height: h * 0.28),
      -0.7,
      1.4,
      false,
      waveStroke..color = accent.withOpacity(0.55),
    );

    // ── แถบเล่นเสียง ──
    final playBarRect = Rect.fromLTWH(
      cardRect.left + w * 0.08,
      cardRect.top + h * 0.53,
      w * 0.26,
      h * 0.065,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(playBarRect, Radius.circular(h * 0.03)),
      Paint()..color = accent.withOpacity(0.18),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(playBarRect.left, playBarRect.top, w * 0.15, playBarRect.height),
        Radius.circular(h * 0.03),
      ),
      Paint()..color = AppTheme.secondary,
    );

    // ── ชิปวลีที่บันทึกไว้ ลอยซ้อนด้านหลังการ์ด ──
    _drawChip(
      canvas,
      center: Offset(w * 0.72, h * 0.28),
      width: w * 0.38,
      height: h * 0.16,
      rotation: 0.07,
      dotColor: AppTheme.secondary,
    );
    _drawChip(
      canvas,
      center: Offset(w * 0.70, h * 0.68),
      width: w * 0.40,
      height: h * 0.16,
      rotation: -0.1,
      dotColor: accent,
    );
  }

  void _drawChip(
    Canvas canvas, {
    required Offset center,
    required double width,
    required double height,
    required double rotation,
    required Color dotColor,
  }) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation);

    final rect = Rect.fromCenter(center: Offset.zero, width: width, height: height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(height / 2)),
      Paint()..color = Colors.white,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(height / 2)),
      Paint()
        ..color = const Color(0xFFEAF6FF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );

    final dotCx = rect.left + height * 0.55;
    canvas.drawCircle(Offset(dotCx, 0), height * 0.22, Paint()..color = dotColor);

    final lineRect = Rect.fromLTWH(
      dotCx + height * 0.42,
      -height * 0.11,
      width - (dotCx - rect.left) - height * 0.55,
      height * 0.22,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(lineRect, Radius.circular(height * 0.11)),
      Paint()..color = const Color(0xFFD9EEFF),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _VoiceHistoryPainter oldDelegate) =>
      oldDelegate.accent != accent;
}

/// ใบหน้าอยู่ในกรอบสแกน — พอร์ตพิกัดมาจาก SVG ต้นฉบับใน design canvas
/// (viewBox 190x190) ตรงๆ แทนการกะประมาณเอง หลังจากเข้าใจภาพอ้างอิงผิดไปมา
/// หลายรอบ ต้นฉบับจริงมีกรอบ 2 ชั้น: กรอบเขียวเล็กแนบชิดปาก + กรอบฟ้ากว้าง
/// รอบขอบภาพทั้งหมด ไม่ใช่ชั้นเดียวแบบที่เข้าใจผิดไปก่อนหน้า
class _FaceScanPainter extends CustomPainter {
  final Color color;

  const _FaceScanPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    // ต้นฉบับออกแบบไว้บน viewBox 190x190 พอดี ปรับสเกลตามนี้เผื่อขนาดจริง
    // ที่ส่งเข้ามาไม่ใช่ 190x190
    final sx = size.width / 190;
    final sy = size.height / 190;
    Offset p(double x, double y) => Offset(x * sx, y * sy);

    // ── ศีรษะ ──
    canvas.drawOval(
      Rect.fromCenter(center: p(95, 98), width: 88 * sx, height: 100 * sy),
      Paint()..color = const Color(0xFFF7D5B4),
    );

    // ── ผม ──
    canvas.drawPath(
      Path()
        ..moveTo(53 * sx, 92 * sy)
        ..cubicTo(50 * sx, 62 * sy, 70 * sx, 40 * sy, 95 * sx, 40 * sy)
        ..cubicTo(120 * sx, 40 * sy, 140 * sx, 62 * sy, 137 * sx, 92 * sy)
        ..cubicTo(132 * sx, 76 * sy, 122 * sx, 66 * sy, 114 * sx, 78 * sy)
        ..cubicTo(106 * sx, 64 * sy, 84 * sx, 64 * sy, 76 * sx, 78 * sy)
        ..cubicTo(68 * sx, 66 * sy, 58 * sx, 76 * sy, 53 * sx, 92 * sy)
        ..close(),
      Paint()..color = const Color(0xFF3E3452),
    );

    // ── ตาโค้งยิ้ม ──
    final eyeStroke = Paint()
      ..color = const Color(0xFF3E3452)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4 * sx
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
      Path()
        ..moveTo(74 * sx, 92 * sy)
        ..cubicTo(78 * sx, 97 * sy, 86 * sx, 97 * sy, 90 * sx, 92 * sy),
      eyeStroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(100 * sx, 92 * sy)
        ..cubicTo(104 * sx, 97 * sy, 112 * sx, 97 * sy, 116 * sx, 92 * sy),
      eyeStroke,
    );

    // ── ริมฝีปาก ──
    canvas.drawPath(
      Path()
        ..moveTo(84 * sx, 118 * sy)
        ..cubicTo(90 * sx, 114 * sy, 100 * sx, 114 * sy, 106 * sx, 118 * sy)
        ..cubicTo(100 * sx, 124 * sy, 90 * sx, 124 * sy, 84 * sx, 118 * sy)
        ..close(),
      Paint()..color = const Color(0xFFF0556B),
    );

    // ── กรอบสแกนเล็กแนบชิดปาก (สีเขียว มิ้นต์) ──
    final innerStroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4 * sx
      ..strokeCap = StrokeCap.round;
    void innerCorner(double cx, double cy, double dx, double dy) {
      canvas.drawPath(
        Path()
          ..moveTo(p(cx, cy).dx, p(cx, cy).dy)
          ..lineTo(p(cx, cy + dy).dx, p(cx, cy + dy).dy)
          ..moveTo(p(cx, cy).dx, p(cx, cy).dy)
          ..lineTo(p(cx + dx, cy).dx, p(cx + dx, cy).dy),
        innerStroke,
      );
    }

    innerCorner(62, 100, 12, 12);
    innerCorner(128, 100, -12, 12);
    innerCorner(62, 138, 12, -12);
    innerCorner(128, 138, -12, -12);

    // ── กรอบวิวไฟน์เดอร์กว้างรอบขอบภาพ (สีฟ้าหลักของแอป) ──
    final outerStroke = Paint()
      ..color = AppTheme.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5 * sx
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
      Path()
        ..moveTo(8 * sx, 34 * sy)
        ..lineTo(8 * sx, 8 * sy)
        ..lineTo(34 * sx, 8 * sy),
      outerStroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(156 * sx, 8 * sy)
        ..lineTo(182 * sx, 8 * sy)
        ..lineTo(182 * sx, 34 * sy),
      outerStroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(182 * sx, 156 * sy)
        ..lineTo(182 * sx, 182 * sy)
        ..lineTo(156 * sx, 182 * sy),
      outerStroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(34 * sx, 182 * sy)
        ..lineTo(8 * sx, 182 * sy)
        ..lineTo(8 * sx, 156 * sy),
      outerStroke,
    );

  }

  @override
  bool shouldRepaint(covariant _FaceScanPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _OnboardingPage {
  final String title;

  /// ใช้กับหน้าที่เป็นคำบรรยายย่อหน้าเดียว
  final String? description;

  /// ใช้กับหน้าที่เป็นขั้นตอนการใช้งาน จะถูกแสดงเป็นรายการมีเลขกำกับ
  final List<String>? steps;

  final IconData icon;
  final Color accent;

  /// วาดภาพใบหน้าในกรอบสแกนแทนไอคอน สื่อการใช้งานได้ตรงกว่าไอคอนสำเร็จรูป
  final bool showFaceScan;

  /// หน้าแรก: โลโก้จริงของแอปเป็นภาพหลัก แทนภาพประกอบวงกลม+ไอคอน
  final bool heroLogo;

  /// วาดลำโพง+คลื่นเสียง+วลีที่บันทึกไว้ แทนไอคอนลำโพงเฉยๆ
  final bool showVoiceHistory;

  const _OnboardingPage({
    required this.title,
    required this.icon,
    required this.accent,
    this.description,
    this.steps,
    this.showFaceScan = false,
    this.heroLogo = false,
    this.showVoiceHistory = false,
  });
}
