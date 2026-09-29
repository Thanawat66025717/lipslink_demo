import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
// 🟢 เพิ่ม Firebase 
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../app/theme/app_theme.dart';
import '../../../shared/services/tts_service.dart';
import '../../../shared/services/lip_reading_api_service.dart';

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen>
    with TickerProviderStateMixin {
  // ─── Camera ───────────────────────────────────────────────────────────────
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _cameraReady = false;
  bool _isFrontCamera = true;

  // ─── ML Kit ───────────────────────────────────────────────────────────────
  // ไม่ใช่ final แล้ว เพราะต้องสร้างตัวใหม่ทดแทนได้ถ้าตัวเดิมค้าง (ดู
  // _rebuildFaceDetector) — เจอมาแล้วว่า native call ของตัวตรวจจับค้างได้
  // จริง แล้วเรียกซ้ำบนตัวเดิมที่ยังค้างอยู่เสี่ยงพังกว่าเดิม จึงปิดตัวเก่าทิ้ง
  // แล้วสร้างใหม่แทนที่จะพยายามเรียกตัวเดิมต่อ
  FaceDetector _faceDetector = _newFaceDetector();

  static FaceDetector _newFaceDetector() => FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true,
          enableLandmarks: true,
          // ต้องเปิดไว้ เพราะ _estimateMouthOpen วัดช่องว่างริมฝีปากจากจุด
          // contour ถ้าปิดจะตรวจไม่เจอว่าอ้าปาก แล้วระบบจะไม่เริ่มบันทึกเลย
          // แลกกับที่มันกินเวลาราวครึ่งหนึ่งของงานต่อเฟรมทั้งหมด
          enableContours: true,
          performanceMode: FaceDetectorMode.fast,
        ),
      );
  bool _isProcessingFrame = false;

  // ─── Face Overlay ─────────────────────────────────────────────────────────
  // ข้อมูลชุดนี้เปลี่ยนทุกเฟรมกล้อง แต่มีแค่ overlay ที่ใช้ จึงเก็บไว้ใน
  // ValueNotifier เพื่อให้วาดใหม่เฉพาะ overlay ไม่ลาก setState ทั้งหน้าจอ
  final ValueNotifier<_FaceOverlayData> _overlayData =
      ValueNotifier(const _FaceOverlayData());

  // ─── Mouth state ──────────────────────────────────────────────────────────
  // ค่าเริ่มต้นสำหรับ mouth-aspect-ratio (ช่องปาก/ความกว้างปาก) แบบใหม่ —
  // ปิดปากสนิทควรใกล้ 0, พูด/อ้าปากเบาๆ มักอยู่แถว 0.15-0.3 ค่านี้เป็นค่า
  // เริ่มต้นที่ต้อง fine-tune ต่อจากค่าจริงที่ debugPrint ออกมา
  static const double _mouthOpenThreshold = 0.15;

  // ─── Mouth ROI (ต้องตรงกับตอนเทรนโมเดลเป๊ะ) ───────────────────────────────
  //
  // ค่าสามตัวนี้เป็นของโมเดล ไม่ใช่ของแอป เปลี่ยนได้ทุกครั้งที่เปลี่ยนไฟล์โมเดล
  // จึงถามจาก server ตอนเริ่ม (ดู _syncModelConfig) แทนการฝังตายตัว — ไม่งั้น
  // วันที่โมเดลรุ่นใหม่ใช้ค่าอื่น แอปจะส่งของผิดขนาดไปแล้วทำนายมั่วเงียบๆ
  //
  // ค่าที่ตั้งไว้ตรงนี้เป็นค่าสำรองของโมเดลปัจจุบัน ใช้ตอนที่ยังถาม server ไม่ได้

  // ครอปกว้างกว่ากรอบริมฝีปากจริงเท่านี้เท่า ตามค่า MOUTH_SCALE ที่ใช้ตอนสร้าง
  // training cache ครอปแคบหรือกว้างกว่านี้ โมเดลจะเห็นบริบทไม่เท่าที่เคยเห็นมา
  //
  // ⚠️ ค่านี้ยังไม่ได้ยืนยันกับผู้เทรน checkpoint ไม่ได้บอกมาด้วย จะอัปเดตเองได้
  // ก็ต่อเมื่อผู้เทรนใส่ mouth_scale ลงใน preprocessing ของ checkpoint ให้
  double _mouthScale = 2.4;
  // ขนาดภาพที่โมเดลรับ ย่อตั้งแต่ฝั่งแอปเลย จะได้ไม่ต้องส่งภาพใหญ่เกินจำเป็น
  // ข้ามเน็ตไปให้ server ย่อทีหลัง
  int _roiSize = 112;
  // จำนวนเฟรมที่โมเดลรับต่อหนึ่งคลิป
  int _modelFrameCount = 16;

  // ช่วงเวลาที่คลิปหนึ่งควรครอบคลุม ราวหนึ่งคำพูด — ตอนเทรน 16 เฟรมมาจาก
  // วิดีโอต่อเนื่องซึ่งกินเวลาราวเท่านี้ ถ้าเก็บนานกว่านี้ โมเดลจะเห็นปากขยับ
  // ช้ากว่าที่เรียนรู้มา และคำจริงจะถูกเจือจางด้วยช่วงที่ปากขยับหลังพูดจบ
  static const int _targetCaptureMs = 900;

  // กรอบปากล่าสุดที่ ML Kit ตรวจได้ ใช้ครอปเฟรมระหว่างรอการตรวจรอบถัดไป
  Rect? _lastMouthRoi;
  DateTime? _lastMouthRoiAt;
  // เก่ากว่านี้ถือว่าเชื่อไม่ได้แล้ว เพราะหน้าอาจเลื่อนไปไกลจนครอปผิดที่
  //
  // ต้องยาวพอคลุมทั้งประโยค (ราว 1 วินาที) เพราะระหว่างเก็บเฟรมเราหยุดตรวจหน้า
  // กรอบจึงไม่ถูกรีเฟรชเลยตลอดช่วงนั้น หัวคนขยับไม่กี่พิกเซลในเวลาเท่านี้
  static const Duration _mouthRoiMaxAge = Duration(milliseconds: 1500);
  // กันไม่ให้การครอปซ้อนกัน และทำให้เฟรมเรียงตามเวลาเสมอ
  bool _isCollecting = false;
  DateTime? _lastCollectAt;
  // เว้นจังหวะระหว่างเฟรมที่เก็บ ไม่งั้นพอครอปเสร็จก็ครอปต่อทันทีไม่มีหยุด
  // กลายเป็น busy loop ที่กิน isolate จนหมด ML Kit คืนผลไม่ได้ และ UI ค้าง
  // (เห็นใน log ว่า "Skipped 718 frames") 50 ms = 20 เฟรม/วินาที ซึ่งพอให้
  // 16 เฟรมกินเวลาราว 0.8 วินาที ใกล้เคียงตอนเทรนอยู่แล้ว ไม่ต้องเร็วกว่านี้
  static const Duration _minCollectInterval = Duration(milliseconds: 50);

  // ขนาดด้านของกรอบครอป เฉลี่ยแบบถ่วงน้ำหนักตลอดหนึ่งประโยค (null = เริ่มใหม่)
  //
  // กรอบดิบที่คำนวณจาก contour ทุกเฟรมมีขนาดแกว่งแรงมาก: มันโตตามตอนอ้าปาก
  // และกระโดดเป็นเท่าตัวเวลา ML Kit จับ contour พลาดไปเฟรมหนึ่ง ผลคือโมเดล
  // เห็นภาพซูมเข้าๆ ออกๆ สลับกันภายในคลิปเดียว ซึ่งตอนเทรนไม่มีแบบนั้น
  double? _roiSideEma;

  // ─── Speaking state machine ────────────────────────────────────────────────
  _SpeakingState _state = _SpeakingState.idle;
  Timer? _silenceTimer; 
  Timer? _wordTimer; 
  Duration _silenceGap = const Duration(milliseconds: 800);
  int _consecutiveSilenceFrames = 0;
  int _consecutiveSpeakFrames = 0;
  // ต้องตรวจเจอปากอ้ากี่ครั้งติดกันถึงจะถือว่าเริ่มพูด — นับเป็น "ครั้งที่ตรวจ"
  // ไม่ใช่เฟรมกล้อง และการตรวจทำได้ราว 3 ครั้งต่อวินาที ค่า 3 จึงแปลว่ารอเกือบ
  // หนึ่งวินาทีก่อนเริ่มเก็บ ซึ่งคำพูดอาจจบไปแล้ว ลดเหลือ 2 เพื่อให้เริ่มทัน
  // แลกกับการเริ่มเก็บผิดบ้างเวลาผู้ใช้อ้าปากโดยไม่ได้พูด ซึ่ง motion gate
  // และเกณฑ์ confidence ฝั่ง server คัดออกให้อยู่แล้ว
  static const int _speakFrameThreshold = 2;
  static const int _silenceFrameThreshold = 8;

  // ─── Output ───────────────────────────────────────────────────────────────
  List<String> _words = [];
  String get _displayText => _words.join(' ');

  // ข้อความที่ขึ้นแทนคำ เมื่อโมเดลเดาได้แต่ไม่มั่นใจพอ โมเดลถูกบังคับให้เลือก
  // 1 ใน 44 คำเสมอ แม้ผู้ใช้จะพูดคำนอกชุดหรือกล้องจับปากไม่ติด การโชว์คำที่
  // มันเดามั่วๆ ทำให้ผู้ใช้เข้าใจผิดว่าระบบอ่านได้ ทั้งที่ยังไม่ได้อ่าน
  static const String _unreadableMessage =
      'ไม่สามารถประมวลผลได้ (ลองใหม่อีกครั้ง)';

  /// true เมื่อข้อความที่แสดงอยู่เป็นคำที่อ่านได้จริง ไม่ใช่ข้อความแจ้งปัญหา
  ///
  /// ใช้คุมปุ่มบันทึก/อ่านออกเสียง จะได้ไม่มีข้อความแจ้งปัญหาหลุดไปอยู่ใน
  /// ประวัติ หรือถูก TTS อ่านออกมาดังๆ
  bool _hasWord = false;
  String _currentEmotion = 'neutral';

  // ─── AI Lip Reading ────────────────────────────────────────────────────────
  List<Uint8List> _collectedLipFrames = [];
  bool _isApiAvailable = false;
  bool _isPredicting = false;

  // ทำนายผลระหว่างที่ยังพูดอยู่ทุกๆ เท่านี้เฟรม แล้วอัปเดตข้อความทันที
  // ผู้ใช้จึงเห็นผลคืบหน้าไปเรื่อยๆ แทนที่จะจ้องจอว่างจนกว่าจะพูดจบ
  static const int _partialPredictEveryFrames = 6;
  int _framesAtLastPartial = 0;
  Future<void>? _partialInFlight;
  // เวลาที่เริ่มเก็บเฟรมของประโยคปัจจุบัน ใช้คำนวณว่ากล้องเก็บได้กี่เฟรม/วินาที
  DateTime? _captureStartedAt;
  Timer? _apiStatusTimer;
  static const Duration _apiStatusRecheckInterval = Duration(seconds: 20);
  // จำนวน frames สูงสุดที่เก็บต่อการพูด 1 รอบ
  //
  // ⚠️ ค่าเดิม 75 ทำให้ server บนแพลน Free ของ Render (0.1 CPU / 512MB RAM)
  // ล่มจริง — ทดสอบยิง 75 เฟรมแล้วได้ 502 กลับมา และ instance ต้อง restart
  // เองอยู่หลายนาทีกว่าจะกลับมาใช้ได้ ส่วน 40 เฟรมยังตอบ 200 ปกติ จึงลดเพดาน
  // ลงมาให้ต่ำกว่าจุดที่ล่ม และช่วยลดเวลารอไปด้วย (เวลาประมวลผลแปรผันตาม
  // จำนวนภาพที่ส่ง) การใช้งานจึงควรพูดเป็นวลีสั้นๆ ทีละช่วง
  static const int _maxCollectFrames = 40;

  static const List<List<String>> _wordPool = [
    ['สวัสดี', 'ครับ'],
    ['ขอบคุณ', 'มาก', 'ครับ'],
    ['ผม', 'เข้าใจ', 'แล้ว'],
    ['ช่วย', 'ด้วย', 'ครับ'],
    ['ผม', 'หิว', 'ข้าว', 'ครับ'],
    ['ไม่', 'เป็น', 'ไร', 'ครับ'],
    ['ผม', 'รัก', 'คุณ'],
    ['ขอโทษ', 'นะ', 'ครับ'],
    ['ใช่', 'ครับ'],
    ['โอเค', 'ครับ'],
    ['รอ', 'สักครู่', 'นะ', 'ครับ'],
    ['ดี', 'มาก', 'เลย', 'ครับ'],
    ['ผม', 'ต้องการ', 'ความ', 'ช่วยเหลือ'],
    ['ขอ', 'น้ำ', 'หน่อย', 'ครับ'],
    ['ผม', 'อยาก', 'กลับ', 'บ้าน'],
  ];

  static const List<String> _emotionPool = [
    'happy',
    'neutral',
    'neutral',
    'sad',
    'neutral',
    'neutral',
    'happy',
    'sad',
    'neutral',
    'neutral',
    'neutral',
    'happy',
    'sad',
    'neutral',
    'sad',
  ];

  List<String> _currentWordList = [];
  int _wordIndex = 0;

  // ─── TTS ──────────────────────────────────────────────────────────────────
  final _tts = TtsService();
  bool _isTtsSpeaking = false;

  // ─── Animation ────────────────────────────────────────────────────────────
  late AnimationController _pulseCtrl;
  late AnimationController _waveCtrl;

  // ป้ายสถานะมีข้อความคงที่แค่สองแบบ สร้าง+จัดเลย์เอาต์ครั้งเดียวตอนเปิดจอ
  // แล้วส่งต่อให้ painter ใช้ซ้ำทุกเฟรม ไม่ใช่สร้าง TextPainter ใหม่แล้ว
  // layout() ใหม่ทุกครั้งที่ paint() ทำงาน (ซึ่งตอนนี้ทำงานที่ 60 fps ตามรอบ
  // แอนิเมชันวงแสง — layout() ข้อความรัว 60 ครั้ง/วินาทีคือของแพงที่ไม่จำเป็น)
  late final TextPainter _foundLabelPainter = _buildStatusLabel('เจอหน้าคุณแล้ว');
  late final TextPainter _listeningLabelPainter =
      _buildStatusLabel('กำลังฟังอยู่...');

  // เดิมใช้ AnimatedBuilder ฟัง _pulseCtrl/_waveCtrl ตรงๆ ซึ่งวิ่งที่ 60 fps
  // ตาม vsync ของจอ ปัญหาคือมันบังคับให้ทั้งต้นไม้ widget (ValueListenableBuilder
  // + CustomPaint + _FaceOverlayPainter object ใหม่) ถูกสร้างใหม่ 60 ครั้ง/
  // วินาที ไม่ว่าข้างในจะเบาแค่ไหนก็ตาม — วัดแล้วทำให้ GC ทำงานถี่เกือบ 3
  // ครั้ง/วินาทีตลอดเวลา แม้ไม่ได้ทำอะไรเลย (แก้แค่เนื้อหาข้างใน paint() ให้
  // เบาลงไม่ช่วยเลย เพราะปัญหาไม่ได้อยู่ตรงนั้น) จึงลดอัตรามาใช้ Timer ที่นี่
  // แทน ยังคงอ่านค่าจาก _pulseCtrl/_waveCtrl ได้ตามปกติ (มันคำนวณค่าต่อเนื่อง
  // อยู่แล้วไม่ว่าจะมีใครอ่านบ่อยแค่ไหน) แค่ลดความถี่ที่จะสร้าง widget ใหม่
  // เหลือ ~12 ครั้ง/วินาที ซึ่งยังลื่นพอสำหรับแอนิเมชันจังหวะช้าแบบนี้
  final ValueNotifier<int> _overlayTick = ValueNotifier(0);
  Timer? _overlayTickTimer;

  static TextPainter _buildStatusLabel(String text) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  // ─── User ─────────────────────────────────────────────────────────────────
  final _uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    // ดูเหตุผลที่ _overlayTick — จำกัดอัตราสร้าง widget overlay ใหม่ไว้ที่
    // ~12 ครั้ง/วินาที แทนที่จะปล่อยให้วิ่งตาม vsync 60 fps ของ _pulseCtrl/
    // _waveCtrl ตรงๆ
    _overlayTickTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      _overlayTick.value++;
    });
    _initCamera();
    _checkApiStatus();
    _apiStatusTimer = Timer.periodic(
      _apiStatusRecheckInterval,
      (_) => _checkApiStatus(),
    );
  }

  Future<void> _checkApiStatus() async {
    // อย่า re-check ระหว่างที่กำลังเก็บ frame/ทำนายผลอยู่ เพื่อไม่ให้ค่า
    // _isApiAvailable เปลี่ยนกลางคันขณะ flow กำลังทำงาน
    if (_isPredicting) return;
    final available = await LipReadingApiService.checkHealth();
    if (!mounted) return;

    if (available != _isApiAvailable) {
      setState(() => _isApiAvailable = available);
      debugPrint(available ? '✅ API Server พร้อมใช้งาน' : '⚠️ API Server ไม่พร้อม — ใช้โหมดสุ่มคำแทน');
    }
    if (available) await _syncModelConfig();
  }

  /// ถามค่า preprocessing จาก server แล้วใช้ค่านั้นแทนค่าสำรองที่ฝังไว้
  ///
  /// ถามซ้ำทุกครั้งที่เช็ก health เพราะ server เปลี่ยนไฟล์โมเดลได้ระหว่างที่
  /// แอปยังเปิดอยู่ ถามไม่ได้ก็ใช้ค่าเดิมต่อไป ไม่ต้องทำอะไร
  Future<void> _syncModelConfig() async {
    final config = await LipReadingApiService.fetchWordModelConfig();
    if (config == null || !mounted) return;

    final scale = config.mouthScale ?? _mouthScale;
    if (config.frames == _modelFrameCount &&
        config.roi == _roiSize &&
        scale == _mouthScale) {
      return;
    }

    debugPrint('⚙️ ปรับค่าตามโมเดลบน server: $config '
        '(เดิม frames=$_modelFrameCount roi=$_roiSize scale=$_mouthScale)');
    _modelFrameCount = config.frames;
    _roiSize = config.roi;
    _mouthScale = scale;
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return;
      await _startCamera(
        _cameras.length > 1 && _isFrontCamera ? 1 : 0,
      );
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  Future<void> _startCamera(int index) async {
    if (_cameras.isEmpty || index >= _cameras.length) return;

    final controller = CameraController(
      _cameras[index],
      // ทุกเฟรมต้องถูกแปลง YUV เป็น NV21 ด้วยลูปวนทีละพิกเซลใน Dart ก่อนส่งให้
      // ML Kit ต้นทุนจึงแปรผันตรงกับจำนวนพิกเซล ลดความละเอียดลงหนึ่งขั้นทำให้
      // ประมวลผลได้ถี่ขึ้นมาก ซึ่งสำคัญกว่าความคมชัดสำหรับการครอปภาพปาก
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: defaultTargetPlatform == TargetPlatform.android
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888,
    );

    await controller.initialize();
    if (!mounted) {
      controller.dispose();
      return;
    }

    _cameraController?.dispose();
    _cameraController = controller;

    if (!kIsWeb) {
      await controller.startImageStream(_onCameraFrame);
    }

    setState(() {
      _cameraReady = true;
      _isFrontCamera = index == 1;
    });
  }

  Future<void> _flipCamera() async {
    if (_cameras.length < 2) return;
    await _cameraController?.stopImageStream();
    final nextIndex = _isFrontCamera ? 0 : 1;
    await _startCamera(nextIndex);
  }

  Future<void> _onCameraFrame(CameraImage image) async {
    final camera = _cameras[_isFrontCamera ? 1 : 0];

    // ─── เส้นทางเร็ว: เก็บภาพปากทุกเฟรมกล้อง ไม่ต้องรอ ML Kit ───────────────
    //
    // ML Kit ตรวจใบหน้าได้แค่ราว 2 เฟรม/วินาทีบนมือถือจริง (วัดแล้ว) ถ้าผูก
    // การเก็บภาพไว้กับมัน 16 เฟรมจะกินเวลา 7.5 วินาที ขณะที่ 16 เฟรมตอนเทรน
    // กินราว 0.6 วินาที โมเดลจึงเห็นปากขยับช้ากว่าที่เรียนรู้มาสิบกว่าเท่า
    // ซึ่งเป็นข้อมูลหลักที่มันใช้ตัดสิน
    //
    // ทำได้เพราะกรอบปากเลื่อนช้ากว่าการอ้า-หุบปากมาก ใช้กรอบที่ ML Kit ตรวจได้
    // ล่าสุดครอปเฟรมระหว่างทางจึงยอมรับได้ ส่วนจังหวะอ้า-หุบเก็บครบทุกเฟรม
    _maybeCollectFrame(image, camera.sensorOrientation);

    // ─── เส้นทางช้า: ML Kit ทำได้ทีละงาน เฟรมที่มาระหว่างนั้นข้ามไป ──────────
    //
    // ระหว่างที่กำลังเก็บเฟรมของประโยคหนึ่งอยู่ ให้หยุดตรวจหน้าไปเลย เพราะเรา
    // มีกรอบปากอยู่แล้วและไม่ได้ใช้ผลตรวจทำอะไรในช่วงนั้น (การจบประโยคใช้เวลา
    // เป็นเกณฑ์ ไม่ได้รอให้ตรวจเจอว่าหุบปาก)
    //
    // การตรวจหนึ่งรอบต้องแปลงทั้งเฟรมเป็น NV21 ก่อน ซึ่งวนทุกพิกเซลใน Dart
    // และบล็อก isolate จนการเก็บภาพปากแทรกไม่ได้ ผลคือเก็บได้จริงราว 5 เฟรม
    // ต่อวินาทีทั้งที่ตั้งเพดานไว้ 20 พอหยุดตรวจชั่วคราว เวลาทั้งหมดในช่วงนั้น
    // จึงเหลือให้การเก็บภาพอย่างเดียว
    if (_state == _SpeakingState.speaking &&
        _collectedLipFrames.length < _modelFrameCount) {
      return;
    }

    if (_isProcessingFrame) return;
    _isProcessingFrame = true;

    try {
      final inputImage = _buildInputImage(image, camera);
      if (inputImage == null) {
        _isProcessingFrame = false;
        return;
      }

      // ใส่ timeout ไว้กันไม่ให้ตรวจจับตายถาวร — ถ้า native call ของ ML Kit
      // ค้างแม้แต่ครั้งเดียว (เจอมาแล้วจริงว่าเกิดได้ ทั้งเซสชันไม่มี log
      // ตรวจจับสำเร็จเลยสักครั้ง) โค้ดเดิมจะไม่มีวันไปถึง _isProcessingFrame
      // = false อีกเลย เพราะรอ await อยู่ตรงนี้ตลอดไป ทุกเฟรมหลังจากนั้นจะ
      // โดน `if (_isProcessingFrame) return;` เงียบๆ ไปตลอดชีวิตแอป โดยไม่มี
      // error ให้เห็นเลยด้วยซ้ำ ต้องปิดเปิดแอปใหม่เท่านั้นถึงจะกลับมาใช้ได้
      //
      // เมื่อ timeout ต้องปิดตัวตรวจจับเดิมแล้วสร้างใหม่ด้วย ไม่ใช่แค่ข้าม
      // เฟรมไปเฉยๆ เพราะ native call ที่ค้างอยู่อาจยังไม่จบจริง การเรียก
      // processImage() ซ้ำบนตัวเดิมที่ยังมีงานค้างอยู่ข้างในเสี่ยงพังยิ่งกว่า
      // เดิม ปิดของเก่าทิ้งตัดปัญหาให้เด็ดขาดดีกว่า
      final faces = await _faceDetector
          .processImage(inputImage)
          .timeout(const Duration(seconds: 2), onTimeout: () {
        debugPrint('⚠️ ML Kit ค้างเกิน 2 วินาที กำลังสร้างตัวตรวจจับใหม่');
        final old = _faceDetector;
        _faceDetector = _newFaceDetector();
        old.close();
        return <Face>[];
      });
      if (!mounted) {
        _isProcessingFrame = false;
        return;
      }

      // 🟢 เก็บข้อมูลใบหน้าสำหรับวาด Overlay (ไม่ setState — ดู _overlayData)
      // ประทับเวลาไว้ทุกครั้งที่ตรวจจบหนึ่งรอบ ไม่ว่าจะเจอหน้าหรือไม่ก็ตาม —
      // ใช้บอกทีหลังว่าข้อมูลชุดนี้ยังใหม่พอให้เชื่อมั้ย ถ้าการตรวจจับค้าง
      // (เช่นตอนอีมูเลเตอร์กระตุก) จะได้ไม่โชว์ป้าย "เจอหน้าคุณแล้ว" ค้างเก่า
      final rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation) ?? InputImageRotation.rotation0deg;
      _overlayData.value = _overlayData.value.copyWith(
        faces: faces,
        imageSize: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        detectedAt: DateTime.now(),
      );

      if (faces.isEmpty) {
        _updateMouthState(0.0, faceDetected: false);
        _overlayData.value = _overlayData.value.copyWithMouthCenter(null);
      } else {
        final face = faces.first;
        final prob = face.smilingProbability ?? 0.0;
        final mouthOpen = _estimateMouthOpen(face);
        _updateMouthState(mouthOpen, faceDetected: true, smiling: prob > 0.6);

        // เก็บกรอบปากไว้ให้เส้นทางเร็วใช้ครอปเฟรมถัดๆ ไปจนกว่าจะตรวจรอบใหม่
        final roi = _mouthRoiRect(face);
        if (roi != null) {
          _lastMouthRoi = roi;
          _lastMouthRoiAt = DateTime.now();
        }

        // คำนวณจุดกึ่งกลางปาก "ตอนนี้เลย" — ครั้งเดียวต่อการตรวจจับหนึ่งรอบ
        // (ราวไม่กี่ครั้ง/วินาที) แทนที่จะให้ painter คำนวณใหม่ทุกเฟรมแอนิเมชัน
        // ของวงแสง (60 ครั้ง/วินาที) ดูเหตุผลเต็มๆ ที่ _mouthCenterRaw
        _overlayData.value =
            _overlayData.value.copyWithMouthCenter(_mouthCenterRaw(face));
      }
    } catch (e) {
      debugPrint('ML Kit error: $e');
    }

    _isProcessingFrame = false;
  }

  /// เก็บภาพปากจากเฟรมกล้องนี้ ถ้ากรอบปากที่ ML Kit ตรวจไว้ยังใหม่พอ
  ///
  /// ไม่ await เพราะถูกเรียกจาก callback ของสตรีมกล้องที่ยิงมาเรื่อยๆ —
  /// ใช้ธงกันไม่ให้ซ้อนกันแทน เฟรมที่มาระหว่างที่ยังเข้ารหัสไม่เสร็จก็ข้ามไป
  void _maybeCollectFrame(CameraImage image, int rotationDegrees) {
    if (_isCollecting) return;
    if (_state != _SpeakingState.speaking) return;
    if (!_isApiAvailable) return;
    if (_collectedLipFrames.length >= _maxCollectFrames) return;

    final now = DateTime.now();
    final last = _lastCollectAt;
    if (last != null && now.difference(last) < _minCollectInterval) return;

    final roi = _lastMouthRoi;
    final detectedAt = _lastMouthRoiAt;
    if (roi == null || detectedAt == null) return;
    // กรอบเก่าเกินไปแปลว่าหน้าอาจเลื่อนไปแล้ว รอ ML Kit ตรวจใหม่ดีกว่าครอปมั่ว
    if (now.difference(detectedAt) > _mouthRoiMaxAge) return;

    _isCollecting = true;
    _lastCollectAt = now;
    try {
      final rgb = _cropMouthToRgb(image, roi, rotationDegrees);
      if (rgb != null) _collectedLipFrames.add(rgb);
    } catch (e) {
      debugPrint('Lip frame collection error: $e');
    } finally {
      _isCollecting = false;
    }

    if (!mounted || _state != _SpeakingState.speaking) return;
    if (_shouldFinalizeCapture()) {
      _finalizeUtterance();
    } else {
      _maybePredictPartial();
    }
  }

  /// เก็บครบสำหรับหนึ่งคำแล้วหรือยัง
  ///
  /// ตัดสินด้วย "ช่วงเวลา" เป็นหลัก ไม่ใช่จำนวนเฟรม เพราะอัตราเฟรมต่างกันมาก
  /// ระหว่างเครื่อง (วัดได้ 2 fps บนมือถือจริง กับ 7 fps บนอีมูเลเตอร์) ถ้าใช้
  /// จำนวนเฟรมเป็นเกณฑ์ ช่วงเวลาที่โมเดลเห็นจะไม่เท่ากันในแต่ละเครื่อง ทั้งที่
  /// มันต้องใกล้เคียงกับตอนเทรน (16 เฟรมต่อคำ ราว 0.6 วินาที)
  bool _shouldFinalizeCapture() {
    if (_collectedLipFrames.length >= _maxCollectFrames) return true;
    if (_collectedLipFrames.length < _modelFrameCount) return false;
    final elapsed = _captureMs;
    return elapsed != null && elapsed >= _targetCaptureMs;
  }

  /// จุดกึ่งกลางริมฝีปาก ในพิกัดดิบของ ML Kit (ยังไม่ scale ไปที่ผืนวาด) —
  /// เฉลี่ยแบบให้เส้น contour ทั้งสี่เส้นมีน้ำหนักเท่ากัน (หาจุดกึ่งกลางของ
  /// แต่ละเส้นก่อน แล้วค่อยเฉลี่ยรวม 4 จุดนั้นอีกที) ไม่งั้นเส้นที่มีจำนวนจุด
  /// เยอะกว่า (เส้นรอบนอก) จะดึงผลลัพธ์เอนไปทางตัวเองโดยไม่ตั้งใจ
  ///
  /// ⚠️ ต้องเรียกจากจุดที่ตรวจจับเสร็จเท่านั้น (ราวไม่กี่ครั้ง/วินาที) ห้ามเรียก
  /// จาก paint() ของ _FaceOverlayPainter ซึ่งวิ่งที่ 60 fps ตามรอบแอนิเมชัน
  /// ของวงแสง — เคยพลาดมาแล้ว: การไล่จุด contour ทั้งหมดใหม่ทุกเฟรมแอนิเมชัน
  /// ทำให้ GC ทำงานถี่ขึ้นเป็นเกือบ 2 ครั้ง/วินาทีตลอดเวลา แม้ตอนแอปไม่ได้
  /// ทำอะไรเลย จนแย่งเวลา CPU ที่ ML Kit/กล้องต้องใช้ กลายเป็นสาเหตุที่ทำให้
  /// ตรวจจับหน้าดูค้าง/ช้าลงจริง ไม่ใช่แค่ปัญหาของอีมูเลเตอร์อย่างที่คิดตอนแรก
  Offset? _mouthCenterRaw(Face face) {
    const types = [
      FaceContourType.upperLipTop,
      FaceContourType.upperLipBottom,
      FaceContourType.lowerLipTop,
      FaceContourType.lowerLipBottom,
    ];
    final lineCenters = <Offset>[];
    for (final type in types) {
      final points = face.contours[type]?.points;
      if (points == null || points.isEmpty) continue;
      double sumX = 0, sumY = 0;
      for (final p in points) {
        sumX += p.x;
        sumY += p.y;
      }
      lineCenters.add(Offset(sumX / points.length, sumY / points.length));
    }
    if (lineCenters.isEmpty) return null;

    double avgX = 0, avgY = 0;
    for (final c in lineCenters) {
      avgX += c.dx;
      avgY += c.dy;
    }
    return Offset(avgX / lineCenters.length, avgY / lineCenters.length);
  }

  /// กรอบจัตุรัสรอบปาก ในระบบพิกัดเดียวกับที่ ML Kit คืนค่ามา
  /// (คือภาพที่หมุนตั้งขึ้นแล้ว ไม่ใช่บัฟเฟอร์ดิบของกล้อง)
  ///
  /// คืน null เมื่อหาตำแหน่งปากไม่ได้ ซึ่งแปลว่าเฟรมนั้นข้ามไปดีกว่าเดา
  Rect? _mouthRoiRect(Face face) {
    double? minX, minY, maxX, maxY;

    void include(num x, num y) {
      minX = (minX == null || x < minX!) ? x.toDouble() : minX;
      maxX = (maxX == null || x > maxX!) ? x.toDouble() : maxX;
      minY = (minY == null || y < minY!) ? y.toDouble() : minY;
      maxY = (maxY == null || y > maxY!) ? y.toDouble() : maxY;
    }

    for (final type in const [
      FaceContourType.upperLipTop,
      FaceContourType.upperLipBottom,
      FaceContourType.lowerLipTop,
      FaceContourType.lowerLipBottom,
    ]) {
      final points = face.contours[type]?.points;
      if (points == null) continue;
      for (final p in points) {
        include(p.x, p.y);
      }
    }

    // เผื่อบางเฟรมที่ ML Kit ให้ contour ไม่ครบ ยังพอถูไถด้วยจุดมุมปากได้
    if (minX == null) {
      for (final type in const [
        FaceLandmarkType.leftMouth,
        FaceLandmarkType.rightMouth,
        FaceLandmarkType.bottomMouth,
      ]) {
        final landmark = face.landmarks[type];
        if (landmark != null) {
          include(landmark.position.x, landmark.position.y);
        }
      }
    }
    if (minX == null) return null;

    // ใช้ด้านที่ยาวกว่าเป็นด้านของจัตุรัส เพราะกรอบปากแบนมาก (กว้าง >> สูง)
    // ถ้าใช้ความสูงจะได้ครอปที่เล็กจนไม่เหลือบริบทรอบปากเลย
    final rawSide = max(maxX! - minX!, maxY! - minY!) * _mouthScale;
    if (rawSide <= 0) return null;

    // จุดกึ่งกลางยังตามปากทุกเฟรมเหมือนเดิม ปรับให้นิ่งเฉพาะ "ขนาด" เพราะขนาด
    // คือสิ่งที่กระโดดจนภาพซูมเข้าออก ส่วนตำแหน่งต้องตามหัวที่ขยับอยู่แล้ว
    final ema = _roiSideEma;
    final double side;
    if (ema == null) {
      side = rawSide;
    } else {
      // จำกัดช่วงก่อนเอาไปเฉลี่ย เพื่อไม่ให้เฟรมที่ตรวจพลาดเฟรมเดียวลากขนาด
      // ของทั้งประโยคตามไปด้วย
      side = ema * 0.8 + rawSide.clamp(ema * 0.75, ema * 1.33) * 0.2;
    }
    _roiSideEma = side;

    return Rect.fromCenter(
      center: Offset((minX! + maxX!) / 2, (minY! + maxY!) / 2),
      width: side,
      height: side,
    );
  }

  /// ครอปบริเวณปากจากบัฟเฟอร์ YUV420 ของกล้องออกมาเป็น RGBA ขนาด 112x112
  ///
  /// สุ่มจุดแบบ nearest-neighbour ทีละพิกเซลปลายทาง จึงไม่ต้องสร้างภาพสีเต็ม
  /// เฟรมกลางทาง — เสียเวลาแค่ราว 12,500 พิกเซลต่อเฟรมแทนที่จะเป็นหลักแสน
  Uint8List? _cropMouthToRgb(
      CameraImage image, Rect roi, int rotationDegrees) {
    final planes = image.planes;
    if (planes.isEmpty) return null;

    final int rawW = image.width;
    final int rawH = image.height;

    final yBytes = planes[0].bytes;
    final int yRowStride = planes[0].bytesPerRow;
    final int yPixelStride = planes[0].bytesPerPixel ?? 1;

    final Uint8List uBytes, vBytes;
    final int uvRowStride, uvPixelStride, uOffset, vOffset;

    if (planes.length >= 3) {
      uBytes = planes[1].bytes;
      vBytes = planes[2].bytes;
      uvRowStride = planes[1].bytesPerRow;
      uvPixelStride = planes[1].bytesPerPixel ?? 1;
      uOffset = 0;
      vOffset = 0;
    } else {
      // บางเครื่องส่ง NV21 มาเป็น plane เดียว: Y ทั้งภาพ แล้วต่อด้วย V,U สลับกัน
      uBytes = yBytes;
      vBytes = yBytes;
      uvRowStride = yRowStride;
      uvPixelStride = 2;
      vOffset = rawH * yRowStride;
      uOffset = vOffset + 1;
    }

    final out = Uint8List(_roiSize * _roiSize * 3);
    int o = 0;

    for (int oy = 0; oy < _roiSize; oy++) {
      final double upY = roi.top + (oy + 0.5) * roi.height / _roiSize;
      for (int ox = 0; ox < _roiSize; ox++) {
        final double upX = roi.left + (ox + 0.5) * roi.width / _roiSize;

        // ย้อนการหมุนที่ ML Kit ทำไว้ กลับไปเป็นพิกัดในบัฟเฟอร์ดิบ
        final int rx, ry;
        switch (rotationDegrees) {
          case 90:
            rx = upY.round();
            ry = rawH - 1 - upX.round();
            break;
          case 180:
            rx = rawW - 1 - upX.round();
            ry = rawH - 1 - upY.round();
            break;
          case 270:
            rx = rawW - 1 - upY.round();
            ry = upX.round();
            break;
          default:
            rx = upX.round();
            ry = upY.round();
        }

        final int cx = rx.clamp(0, rawW - 1);
        final int cy = ry.clamp(0, rawH - 1);

        final int yIdx = cy * yRowStride + cx * yPixelStride;
        final int uvIdx = (cy >> 1) * uvRowStride + (cx >> 1) * uvPixelStride;

        final int luma = yIdx < yBytes.length ? yBytes[yIdx] : 0;
        final int uIdx = uOffset + uvIdx;
        final int vIdx = vOffset + uvIdx;
        // 128 คือค่ากลางของ chroma = ไม่มีสี ใช้เมื่ออ่านนอกขอบบัฟเฟอร์
        final int u = (uIdx < uBytes.length ? uBytes[uIdx] : 128) - 128;
        final int v = (vIdx < vBytes.length ? vBytes[vIdx] : 128) - 128;

        // YUV -> RGB ตามสูตร BT.601 ซึ่งเป็นสูตรที่กล้อง Android ใช้
        out[o++] = (luma + 1.402 * v).round().clamp(0, 255);
        out[o++] = (luma - 0.344136 * u - 0.714136 * v).round().clamp(0, 255);
        out[o++] = (luma + 1.772 * u).round().clamp(0, 255);
      }
    }

    return out;
  }

  // เดิมตรงนี้เข้ารหัสพิกเซลเป็นไฟล์ PNG ก่อนส่ง แล้ว server ก็ถอดกลับมาเป็น
  // พิกเซลชุดเดิม เป็นงานหนักทั้งสองฝั่งที่ไม่ได้อะไรกลับมา — และหนักพอที่จะ
  // ทำให้ UI thread ค้างจน ML Kit ตรวจหน้าไม่ได้ ตอนนี้ส่งพิกเซลดิบไปตรงๆ

  /// เลือกเฟรมให้เหลือ 16 เฟรมกระจายเท่าๆ กันก่อนส่ง
  ///
  /// server เลือกให้เองได้อยู่แล้ว แต่ทำตรงนี้ก่อนช่วยลดขนาดที่ต้องส่งข้ามเน็ต
  /// ลงเกินครึ่งเมื่อเก็บมาเต็ม 40 เฟรม ซึ่งมีผลกับเวลารอโดยตรง
  List<Uint8List> _framesForModel(List<Uint8List> frames) {
    if (frames.length <= _modelFrameCount) return frames;
    final step = (frames.length - 1) / (_modelFrameCount - 1);
    return List.generate(
      _modelFrameCount,
      (i) => frames[(i * step).round()],
    );
  }

  InputImage? _buildInputImage(CameraImage image, CameraDescription camera) {
    try {
      Uint8List bytes;
      InputImageFormat format;
      int bytesPerRow;

      if (defaultTargetPlatform == TargetPlatform.android) {
        bytes = _convertCameraImageToNv21(image);
        format = InputImageFormat.nv21;
        bytesPerRow = image.width; // Padding removed
      } else {
        // iOS
        final WriteBuffer allBytes = WriteBuffer();
        for (final Plane plane in image.planes) {
          allBytes.putUint8List(plane.bytes);
        }
        bytes = allBytes.done().buffer.asUint8List();
        
        format = InputImageFormatValue.fromRawValue(image.format.raw) ?? InputImageFormat.bgra8888;
        bytesPerRow = image.planes.isNotEmpty ? image.planes[0].bytesPerRow : image.width;
      }

      final rotation =
          InputImageRotationValue.fromRawValue(camera.sensorOrientation) ??
              InputImageRotation.rotation0deg;

      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: bytesPerRow,
        ),
      );
    } catch (e) {
      debugPrint('Error building InputImage: $e');
      return null;
    }
  }

  Uint8List _convertCameraImageToNv21(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final expectedSize = (width * height * 1.5).toInt();
    final nv21 = Uint8List(expectedSize);

    if (image.planes.length == 1) {
      final plane = image.planes[0];
      final bytesPerRow = plane.bytesPerRow;
      if (bytesPerRow == width) {
        if (plane.bytes.length == expectedSize) return plane.bytes;
        return plane.bytes.sublist(0, expectedSize);
      }
      
      int dstIndex = 0;
      for (int y = 0; y < height; y++) {
        final srcOffset = y * bytesPerRow;
        for (int x = 0; x < width; x++) {
          nv21[dstIndex++] = plane.bytes[srcOffset + x];
        }
      }
      final uvHeight = height ~/ 2;
      final uvOffset = height * bytesPerRow;
      for (int y = 0; y < uvHeight; y++) {
        final srcOffset = uvOffset + (y * bytesPerRow);
        for (int x = 0; x < width; x++) {
          nv21[dstIndex++] = plane.bytes[srcOffset + x];
        }
      }
      return nv21;
    } else if (image.planes.length == 3) {
      final yPlane = image.planes[0];
      final uPlane = image.planes[1];
      final vPlane = image.planes[2];
      
      final yRowStride = yPlane.bytesPerRow;
      final uvRowStride = uPlane.bytesPerRow;
      final uvPixelStride = uPlane.bytesPerPixel ?? 1;

      int dstIndex = 0;
      
      for (int y = 0; y < height; y++) {
        final srcOffset = y * yRowStride;
        for (int x = 0; x < width; x++) {
          nv21[dstIndex++] = yPlane.bytes[srcOffset + x];
        }
      }
      
      final uvHeight = height ~/ 2;
      final uvWidth = width ~/ 2;
      for (int y = 0; y < uvHeight; y++) {
        final srcOffset = y * uvRowStride;
        for (int x = 0; x < uvWidth; x++) {
          final uvIndex = srcOffset + (x * uvPixelStride);
          nv21[dstIndex++] = vPlane.bytes[uvIndex];
          nv21[dstIndex++] = uPlane.bytes[uvIndex];
        }
      }
      return nv21;
    }
    
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    return allBytes.done().buffer.asUint8List();
  }

  double _estimateMouthOpen(Face face) {
    // วัดช่องว่างระหว่างริมฝีปากบน-ล่างจริงๆ (mouth aspect ratio) แทนระยะจาก
    // จมูกถึงริมฝีปากล่าง — ค่าเดิมมีระยะฐาน (baseline) สูงอยู่แล้วแม้ปิดปากสนิท
    // (วัดได้ ~0.65 ทั้งที่ threshold เปิดปากตั้งไว้ 0.45) เลยไม่เคยตกลงมาต่ำกว่า
    // threshold ให้ตรวจจับว่า "หยุดพูดแล้ว" ได้เลย
    final upperLipBottom = face.contours[FaceContourType.upperLipBottom]?.points;
    final lowerLipTop = face.contours[FaceContourType.lowerLipTop]?.points;
    final leftMouth = face.landmarks[FaceLandmarkType.leftMouth];
    final rightMouth = face.landmarks[FaceLandmarkType.rightMouth];

    if (upperLipBottom != null &&
        upperLipBottom.isNotEmpty &&
        lowerLipTop != null &&
        lowerLipTop.isNotEmpty &&
        leftMouth != null &&
        rightMouth != null) {
      final midUpper = upperLipBottom[upperLipBottom.length ~/ 2];
      final midLower = lowerLipTop[lowerLipTop.length ~/ 2];
      final gap = (midLower.y - midUpper.y).abs().toDouble();

      final mouthWidth = (rightMouth.position.x - leftMouth.position.x).abs();
      if (mouthWidth <= 0) return 0.0;

      final ratio = gap / mouthWidth;
      return ratio.clamp(0.0, 1.0);
    }
    return 0.0;
  }

  void _updateMouthState(double mouthOpen,
      {required bool faceDetected, bool smiling = false}) {
    if (!mounted) return;

    // เดิมเป็น setState ทั้งหน้าจอทุกเฟรมกล้อง ทั้งที่ค่าพวกนี้มีแค่ overlay
    // ที่ใช้ ย้ายมาแจ้งผ่าน notifier ให้วาดใหม่เฉพาะส่วนที่เปลี่ยนจริง
    if (smiling) _currentEmotion = 'happy';
    _overlayData.value = _overlayData.value.copyWith(
      mouthOpenProb: mouthOpen,
      faceDetected: faceDetected,
      isSpeaking: _state == _SpeakingState.speaking,
    );

    final isMouthOpen = mouthOpen >= _mouthOpenThreshold;

    switch (_state) {
      case _SpeakingState.idle:
        if (faceDetected && isMouthOpen) {
          _consecutiveSpeakFrames++;
          if (_consecutiveSpeakFrames >= _speakFrameThreshold) {
            _startUtterance();
          }
        } else {
          _consecutiveSpeakFrames = 0;
        }
        break;

      case _SpeakingState.speaking:
        if (isMouthOpen) {
          _consecutiveSilenceFrames = 0;
          _silenceTimer?.cancel();
        } else {
          _consecutiveSilenceFrames++;
          if (_consecutiveSilenceFrames >= _silenceFrameThreshold) {
            _onSilenceDetected();
          }
        }
        break;

      case _SpeakingState.paused:
        if (isMouthOpen) {
          _resumeUtterance();
        }
        break;

      default:
        break;
    }
  }

  void _startUtterance() {
    _consecutiveSpeakFrames = 0;
    _consecutiveSilenceFrames = 0;

    // 🟢 เคลียร์ frames ที่เก็บไว้
    _collectedLipFrames = [];
    _framesAtLastPartial = 0;
    _captureStartedAt = DateTime.now();

    if (!_isApiAvailable) {
      // Fallback: ใช้คำสุ่มเมื่อ API ไม่พร้อม
      final rng = Random();
      final idx = rng.nextInt(_wordPool.length);
      _currentWordList = _wordPool[idx];
      _currentEmotion = _emotionPool[idx];
      _wordIndex = 0;
    }

    setState(() {
      _state = _SpeakingState.speaking;
      _words = [];
      _hasWord = false;
    });
    // เริ่มประโยคใหม่ก็เริ่มวัดขนาดกรอบใหม่ ไม่ลากค่าจากประโยคก่อนมา เพราะ
    // ผู้ใช้อาจขยับเข้าออกจากกล้องระหว่างนั้น
    _roiSideEma = null;

    if (!_isApiAvailable) {
      _scheduleNextWord();
    }
    // ถ้า API พร้อม จะรอเก็บ frames แล้วส่งตอน finalize
  }

  void _scheduleNextWord() {
    if (_wordIndex >= _currentWordList.length) {
      _finalizeUtterance();
      return;
    }
    _wordTimer?.cancel();
    _wordTimer = Timer(const Duration(milliseconds: 380), () {
      if (!mounted) return;
      if (_state != _SpeakingState.speaking) return;

      final word = _currentWordList[_wordIndex++];
      setState(() => _words = [..._words, word]);

      _speakWordRealtime(word);

      _scheduleNextWord();
    });
  }

  Future<void> _speakWordRealtime(String word) async {
    final tts = TtsService();
    await tts.speakWord(word, emotion: _currentEmotion);
  }

  /// ยิง prediction ระหว่างพูดเป็นระยะ เพื่อให้ข้อความทยอยขึ้นระหว่างที่ยัง
  /// พูดอยู่ ไม่ต้องรอจนพูดจบ
  void _maybePredictPartial() {
    if (_isPredicting) return;

    // ยังไม่ครบจำนวนเฟรมที่โมเดลรับ ก็ยังไม่ต้องยิง — ถ้ายิงไปตอนนี้ server
    // จะเติมเฟรมสุดท้ายซ้ำจนครบ ซึ่งเฟรมที่ซ้ำกันไม่มีการขยับ ค่า motion เลย
    // ตกลงเกือบสี่เท่า (วัดได้ 0.047 -> 0.013) และ confidence ตกตาม
    // ผลระหว่างทางเลยถูกปฏิเสธเกือบทุกครั้ง เสียเวลาเปล่าทั้งสองฝั่ง
    if (_collectedLipFrames.length < _modelFrameCount) return;

    if (_collectedLipFrames.length - _framesAtLastPartial <
        _partialPredictEveryFrames) {
      return;
    }
    _framesAtLastPartial = _collectedLipFrames.length;
    _partialInFlight = _predictPartial();
  }

  /// เวลาที่ใช้เก็บเฟรมชุดปัจจุบัน ส่งไปให้ server บันทึกไว้ดูอัตราเฟรมต่อวินาที
  int? get _captureMs => _captureStartedAt == null
      ? null
      : DateTime.now().difference(_captureStartedAt!).inMilliseconds;

  Future<void> _predictPartial() async {
    if (_isPredicting) return;
    _isPredicting = true;

    // สำเนา ณ ขณะนี้ เพราะรายการจริงยังโตต่อระหว่างที่รอผลอยู่
    final snapshot = _framesForModel(List<Uint8List>.of(_collectedLipFrames));
    final captureMs = _captureMs;

    try {
      final result = await LipReadingApiService.predictWord(
        snapshot,
        roiSize: _roiSize,
        captureMs: captureMs,
        collectedFrames: _collectedLipFrames.length,
        isFinal: false,
      );

      // แสดงเฉพาะตอนที่ยังพูดอยู่ ถ้าจบไปแล้วปล่อยให้ผลสุดท้ายเป็นตัวตัดสิน
      //
      // ผลระหว่างทางที่ไม่มั่นใจจะเงียบไว้เฉยๆ ไม่ขึ้นข้อความแจ้งปัญหา เพราะ
      // ตอนพูดยังไม่จบมันเดาไม่ออกเป็นเรื่องปกติ ถ้าขึ้นแล้วหายไปๆ มาๆ ระหว่าง
      // พูดจะกวนสายตา ปล่อยให้ผลสุดท้ายเป็นคนบอกว่าอ่านไม่ได้จริงหรือเปล่า
      if (mounted &&
          result != null &&
          !result.lowConfidence &&
          result.word.isNotEmpty &&
          _state == _SpeakingState.speaking) {
        setState(() {
          _words = [result.word];
          _hasWord = true;
        });
      }
    } catch (e) {
      // ผลระหว่างทางพลาดได้ ไม่ต้องรบกวนผู้ใช้ เดี๋ยวรอบหน้าหรือผลสุดท้ายก็มาแทน
      debugPrint('partial prediction skipped: $e');
    } finally {
      _isPredicting = false;
    }
  }

  void _onSilenceDetected() {
    if (_state != _SpeakingState.speaking) return;
    setState(() => _state = _SpeakingState.paused);
    _silenceTimer = Timer(_silenceGap, _finalizeUtterance);
  }

  void _resumeUtterance() {
    _silenceTimer?.cancel();
    _consecutiveSilenceFrames = 0;
    setState(() => _state = _SpeakingState.speaking);
    _scheduleNextWord();
  }

  void _finalizeUtterance() {
    _wordTimer?.cancel();
    _silenceTimer?.cancel();

    // 🟢 ถ้า API พร้อม → ส่ง frames ไปทำ prediction
    if (_isApiAvailable && _collectedLipFrames.isNotEmpty) {
      _predictWithApi();
      return;
    }

    if (_words.isEmpty) {
      setState(() => _state = _SpeakingState.idle);
      return;
    }
    setState(() => _state = _SpeakingState.finalizing);

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _state = _SpeakingState.idle);
    });
  }

  /// 🟢 ส่ง lip frames ไป API แล้วรับข้อความกลับมา
  Future<void> _predictWithApi() async {
    // รอผลระหว่างทางที่อาจกำลังวิ่งอยู่ให้จบก่อน ไม่งั้นรอบสุดท้ายจะถูกข้าม
    // เพราะติด _isPredicting แล้วประโยคนั้นจะจบลงด้วยผลที่ยังไม่สมบูรณ์
    await _partialInFlight;
    if (!mounted || _isPredicting) return;

    setState(() {
      _isPredicting = true;
      _state = _SpeakingState.finalizing;
      // ถ้ามีผลระหว่างทางขึ้นอยู่แล้ว คงไว้ให้ผู้ใช้อ่านต่อระหว่างรอผลสุดท้าย
      // ดีกว่าล้างทิ้งแล้วโชว์ข้อความรอซึ่งเหมือนถอยหลัง
      if (_words.isEmpty) _words = ['กำลังอ่านปาก...'];
    });

    try {
      final result = await LipReadingApiService.predictWord(
        _framesForModel(_collectedLipFrames),
        roiSize: _roiSize,
        captureMs: _captureMs,
        collectedFrames: _collectedLipFrames.length,
        isFinal: true,
      );

      // ดู top-3 เต็มๆ ได้ที่ console ของ server เมื่อเปิด VOCALIP_DEBUG=1
      if (result != null) debugPrint('🔮 $result');

      if (!mounted) return;

      // ปากไม่ได้ขยับจริง (ติดแค่ motion gate) ถือว่ายังไม่มีใครพูดอะไร จึงกลับ
      // ไปรอเฉยๆ ไม่ขึ้นข้อความว่าอ่านไม่ได้ เพราะไม่มีอะไรให้อ่านตั้งแต่แรก
      // การขึ้นข้อความตรงนี้จะกลายเป็นเตือนผิดทุกครั้งที่ผู้ใช้แค่ขยับหน้า
      final idleOnly = result != null &&
          result.lowConfidence &&
          result.rejectReasons.length == 1 &&
          result.rejectReasons.first == 'motion';

      // เดาได้แต่ไม่มั่นใจพอ ให้บอกตรงๆ ว่าอ่านไม่ได้ ดีกว่าโชว์คำที่เดามั่ว
      // ซึ่งผู้ใช้แยกไม่ออกว่าอันไหนอ่านได้จริง
      final word = (result != null &&
              result.word.isNotEmpty &&
              !result.lowConfidence)
          ? result.word
          : null;

      setState(() {
        _words = word != null
            ? [word]
            : (idleOnly ? <String>[] : [_unreadableMessage]);
        _hasWord = word != null;
      });

      if (word != null) {
        await _tts.speak(word, emotion: _currentEmotion);
      }
    } catch (e) {
      debugPrint('❌ API prediction error: $e');
      if (mounted) {
        setState(() {
          _words = [_unreadableMessage];
          _hasWord = false;
        });
      }
    } finally {
      _collectedLipFrames = [];
      if (mounted) {
        setState(() => _isPredicting = false);
        // กลับไปพร้อมรับคำถัดไปให้เร็ว ผลที่แสดงยังอยู่บนจอต่อไปจนกว่าจะมีคำใหม่
        // เดิมรอ 4 วินาที ซึ่งเป็นช่วงที่พูดคำต่อไปแล้วแอปไม่รับรู้เลย
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted) setState(() => _state = _SpeakingState.idle);
        });
      }
    }
  }

  // ─── Save phrase to Firebase ──────────────────────────────────────────────
  Future<void> _savePhrase() async {
    // กันไว้อีกชั้นนอกเหนือจากที่ปุ่มปิดไว้ ข้อความแจ้งว่าอ่านไม่ได้ไม่ควร
    // หลุดลงประวัติไม่ว่าจะถูกเรียกจากทางไหน
    if (!_hasWord || _displayText.isEmpty) return;

    final userAuth = FirebaseAuth.instance.currentUser;
    if (userAuth == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรุณาล็อกอินเพื่อบันทึกประวัติ'), backgroundColor: Colors.red),
      );
      return;
    }

    try {
      final phraseId = _uuid.v4();
      
      // 🟢 บันทึกขึ้น Firebase Firestore โดยตรง
      await FirebaseFirestore.instance
          .collection('users')
          .doc(userAuth.uid) 
          .collection('history') 
          .doc(phraseId) 
          .set({
        'id': phraseId,
        'text': _displayText,
        'emotion': _currentEmotion,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(children: [
              const Icon(Icons.cloud_done, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text('บันทึก "$_displayText" ลงคลาวด์แล้ว'),
            ]),
            backgroundColor: AppTheme.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('❌ Firebase Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ บันทึกไม่สำเร็จ: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  // ─── Replay full sentence ─────────────────────────────────────────────────
  Future<void> _replayFull() async {
    if (!_hasWord || _displayText.isEmpty) return;
    setState(() => _isTtsSpeaking = true);
    await _tts.speak(_displayText, emotion: _currentEmotion);
    _tts.setOnCompletionHandler(() {
      if (mounted) setState(() => _isTtsSpeaking = false);
    });
  }

  @override
  void dispose() {
    _wordTimer?.cancel();
    _silenceTimer?.cancel();
    _apiStatusTimer?.cancel();
    _overlayData.dispose();
    _pulseCtrl.dispose();
    _waveCtrl.dispose();
    _overlayTickTimer?.cancel();
    _overlayTick.dispose();
    // ปล่อยกล้องโดยรอให้หยุดสตรีมก่อนจริงๆ ของเดิมเรียก dispose() ทับทันทีทั้งที่
    // stopImageStream() ยังไม่จบ เฟรมที่ค้างอยู่จึงถูกส่งมาหลัง engine ถอดตัวไป
    // แล้ว ทำให้แอป crash ตอนปิด (FlutterJNI is not attached to native)
    final camera = _cameraController;
    _cameraController = null;
    if (camera != null) {
      Future(() async {
        try {
          // เช็กก่อนเรียก เพราะ stopImageStream() โยน exception ถ้าไม่ได้สตรีมอยู่
          if (camera.value.isStreamingImages) await camera.stopImageStream();
        } catch (_) {
          // ปิดแอปอยู่แล้ว ไม่มีใครต้องรู้ ขอแค่ให้ไปถึง dispose() ให้ได้
        }
        await camera.dispose();
      });
    }
    _faceDetector.close();
    _tts.stop();
    super.dispose();
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
                'Lip Reading',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  child: Column(
                    children: [
                      if (!_isApiAvailable) ...[
                        _buildApiFallbackBanner(),
                        const SizedBox(height: 16),
                      ],
                      _buildCameraCard(),
                      const SizedBox(height: 24),
                      _buildSpeechBubble(),
                      const SizedBox(height: 32),
                      _buildActionRow(),
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

  Widget _buildApiFallbackBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.4)),
      ),
      child: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'เชื่อมต่อ AI server ไม่ได้ — กำลังใช้โหมดจำลองคำ (ไม่ใช่ผลอ่านปากจริง)',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.orange,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _simulateMouthOpen(bool isOpen) {
    if (!mounted) return;
    _updateMouthState(isOpen ? 1.0 : 0.0, faceDetected: true);
  }

  Widget _buildCameraCard() {
    return GestureDetector(
      onTapDown: (_) => _simulateMouthOpen(true),
      onTapUp: (_) => _simulateMouthOpen(false),
      onTapCancel: () => _simulateMouthOpen(false),
      child: Container(
        height: 340,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 15,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Transform(
          alignment: Alignment.center,
          // กล้องหน้า (selfie) แสดงภาพดิบแบบไม่สลับซ้าย-ขวา ทำให้ดูเหมือน
          // "กลับด้าน" ผิดธรรมชาติเทียบกับกระจก จึงสลับด้วย scale(-1) ให้เห็น
          // เหมือนกระจกตามที่คนคุ้นเคย ครอบทั้ง preview และ overlay จุดใบหน้า
          // ไปด้วยกัน เพื่อให้จุด tracking ยังอยู่ตรงตำแหน่งใบหน้าเหมือนเดิม
          transform: _isFrontCamera ? Matrix4.diagonal3Values(-1, 1, 1) : Matrix4.identity(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _cameraReady && _cameraController != null
                  ? CameraPreview(_cameraController!)
                  : Container(
                      color: const Color(0xFF0D1B2A),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.camera_alt_outlined,
                            color: Colors.white38,
                            size: 52,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'กำลังเปิดกล้อง...',
                            style: TextStyle(color: Colors.white54),
                          ),
                        ],
                      ),
                    ),
              if (_cameraReady) _buildFaceOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFaceOverlay() {
    // ฟังการเปลี่ยนแปลงผ่าน ValueNotifier + RepaintBoundary แทนการ setState
    // ทั้งหน้าจอทุกเฟรมกล้อง ข้อมูลชุดนี้มีแค่ overlay ที่ใช้ จึงไม่มีเหตุผล
    // ให้ทั้งจอวาดใหม่ตามไปด้วยในอัตราเดียวกับกล้อง
    //
    // ครอบด้วย _overlayTick เพิ่ม (ดูเหตุผลตรงจุดประกาศตัวแปร) เพื่อให้วงแสง
    // หายใจ/ระลอกคลื่นรอบปากขยับได้ — อ่านค่าจาก _pulseCtrl/_waveCtrl ซึ่งวิ่ง
    // อยู่แล้วตั้งแต่ initState() แต่จำกัดอัตราสร้าง widget ใหม่ไว้ที่ timer
    // แทนที่จะผูกกับ vsync 60 fps ของ AnimationController ตรงๆ
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return ValueListenableBuilder<int>(
            valueListenable: _overlayTick,
            builder: (context, _, __) {
              return ValueListenableBuilder<_FaceOverlayData>(
                valueListenable: _overlayData,
                builder: (context, data, _) {
                  return CustomPaint(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    painter: _FaceOverlayPainter(
                      faces: data.faces,
                      imageSize: data.imageSize ?? const Size(480, 640),
                      rotation:
                          data.rotation ?? InputImageRotation.rotation0deg,
                      canvasSize:
                          Size(constraints.maxWidth, constraints.maxHeight),
                      isFrontCamera: _isFrontCamera,
                      isSpeaking: data.isSpeaking,
                      faceDetected: data.faceDetected,
                      mouthOpenProb: data.mouthOpenProb,
                      pulseValue: _pulseCtrl.value,
                      waveValue: _waveCtrl.value,
                      detectedAt: data.detectedAt,
                      now: DateTime.now(),
                      mouthCenterRaw: data.mouthCenterRaw,
                      foundLabelPainter: _foundLabelPainter,
                      listeningLabelPainter: _listeningLabelPainter,
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildSpeechBubble() {
    final hasText = _words.isNotEmpty;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 60),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: hasText
          ? Text(
              _displayText + (_state == _SpeakingState.speaking ? '...' : ''),
              // ข้อความแจ้งว่าอ่านไม่ได้ใช้สีจางกว่า จะได้ไม่ดูเหมือนคำที่
              // อ่านออกมาได้จริง ผู้ใช้แยกออกตั้งแต่เหลือบมอง
              style: TextStyle(
                fontSize: _hasWord ? 16 : 14,
                color: _hasWord ? AppTheme.textPrimary : AppTheme.textHint,
                fontWeight: _hasWord ? FontWeight.w500 : FontWeight.w400,
              ),
              textAlign: TextAlign.center,
            )
          : const Text(
              'รอการอ่านริมฝีปาก...',
              style: TextStyle(fontSize: 14, color: AppTheme.textHint),
              textAlign: TextAlign.center,
            ),
    );
  }

  // น้ำหนัก/ขนาดตัวอักษรเดียวกันทั้งสามปุ่ม — เดิม "บันทึก"/"Reset" ใช้ 10px
  // น้ำหนักปกติ ส่วน "Voice" ใช้ 12px ตัวหนา ทำให้แถวเดียวกันดูไม่เป็นชุดเดียว
  TextStyle _actionLabelStyle(bool enabled) => TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: enabled ? AppTheme.textPrimary : AppTheme.textHint,
      );

  Widget _buildActionRow() {
    // ผูกกับ _hasWord ไม่ใช่ "มีข้อความอยู่มั้ย" เพราะข้อความแจ้งว่าอ่านไม่ได้
    // ก็เป็นข้อความเหมือนกัน แต่ไม่ควรบันทึกลงประวัติหรือให้ TTS อ่านออกเสียง
    final hasText = _hasWord;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Column(
          children: [
            GestureDetector(
              onTap: hasText ? _savePhrase : null,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // โทนฟ้าอ่อนแทนวงกลมขาวล้วน ให้ "บันทึก" อ่านว่าเป็นแอ็กชัน
                  // ระดับข้อมูล/ฟ้า ต่างจาก Reset ที่เป็นแอ็กชันกลางๆ
                  color: hasText
                      ? AppTheme.primary.withOpacity(0.12)
                      : Colors.white,
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withOpacity(0.05), blurRadius: 10)
                  ],
                ),
                child: Icon(Icons.download_rounded,
                    color: hasText ? AppTheme.primary : AppTheme.textHint,
                    size: 22),
              ),
            ),
            const SizedBox(height: 8),
            Text('บันทึก', style: _actionLabelStyle(hasText)),
          ],
        ),
        Column(
          children: [
            GestureDetector(
              onTap: hasText ? _replayFull : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // ไล่เฉดจริงสองโทน (ดู successGradient) แทนสีทึบเดิม ให้ปุ่ม
                  // หลักของแถวมีมิติความลึกแทนที่จะแบนเหมือนอีกสองปุ่ม
                  gradient: AppTheme.successGradient,
                  boxShadow: hasText && !_isTtsSpeaking
                      ? [
                          BoxShadow(
                              color: AppTheme.successDark.withOpacity(0.45),
                              blurRadius: 18,
                              offset: const Offset(0, 6))
                        ]
                      : [],
                ),
                child: Icon(
                  _isTtsSpeaking
                      ? Icons.volume_up_rounded
                      : Icons.volume_up_rounded,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text('Voice', style: _actionLabelStyle(true)),
          ],
        ),
        Column(
          children: [
            GestureDetector(
              onTap: () {
                setState(() {
                  _words = [];
                  _state = _SpeakingState.idle;
                });
              },
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // โทนเทาอุ่นแทนวงกลมขาวล้วน แยกจาก "บันทึก" ด้วยสี ไม่ใช่แค่
                  // ไอคอน — Reset เป็นแอ็กชันกลางๆ จึงใช้กลุ่มสีที่เงียบกว่า
                  color: const Color(0xFFEEF0F3),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withOpacity(0.05), blurRadius: 10)
                  ],
                ),
                child: const Icon(Icons.restart_alt_rounded,
                    color: AppTheme.textSecondary, size: 22),
              ),
            ),
            const SizedBox(height: 8),
            Text('Reset', style: _actionLabelStyle(true)),
          ],
        ),
      ],
    );
  }
}

/// ข้อมูลที่ overlay ใช้วาด อัปเดตทุกเฟรมกล้องผ่าน ValueNotifier แทนการ
/// setState ทั้งหน้าจอ
class _FaceOverlayData {
  final List<Face> faces;
  final Size? imageSize;
  final InputImageRotation? rotation;
  final bool faceDetected;
  final bool isSpeaking;
  final double mouthOpenProb;
  // เวลาที่ ML Kit ตรวจจับเสร็จรอบล่าสุด (ไม่ว่าจะเจอหน้าหรือไม่ก็ตาม) —
  // painter ใช้ค่านี้เทียบกับเวลาปัจจุบันเพื่อรู้ว่าข้อมูลชุดนี้ค้างมานานแค่ไหน
  final DateTime? detectedAt;
  // จุดกึ่งกลางปาก คำนวณไว้แล้วครั้งเดียวตอนตรวจจับเสร็จ (ดู _mouthCenterRaw)
  // painter แค่เอาไป scale ลงผืนวาด ไม่ต้องไล่จุด contour ใหม่ทุกเฟรม
  final Offset? mouthCenterRaw;

  const _FaceOverlayData({
    this.faces = const [],
    this.imageSize,
    this.rotation,
    this.faceDetected = false,
    this.isSpeaking = false,
    this.mouthOpenProb = 0.0,
    this.detectedAt,
    this.mouthCenterRaw,
  });

  _FaceOverlayData copyWith({
    List<Face>? faces,
    Size? imageSize,
    InputImageRotation? rotation,
    bool? faceDetected,
    bool? isSpeaking,
    double? mouthOpenProb,
    DateTime? detectedAt,
  }) {
    return _FaceOverlayData(
      faces: faces ?? this.faces,
      imageSize: imageSize ?? this.imageSize,
      rotation: rotation ?? this.rotation,
      faceDetected: faceDetected ?? this.faceDetected,
      isSpeaking: isSpeaking ?? this.isSpeaking,
      mouthOpenProb: mouthOpenProb ?? this.mouthOpenProb,
      detectedAt: detectedAt ?? this.detectedAt,
      mouthCenterRaw: mouthCenterRaw, // ดู copyWithMouthCenter ด้านล่าง
    );
  }

  /// แยกออกมาต่างหากจาก copyWith ปกติ เพราะ "ไม่มีหน้าแล้ว" ต้องเคลียร์ค่านี้
  /// กลับเป็น null ได้จริง — ถ้าใช้ pattern `param ?? this.field` แบบ copyWith
  /// ทั่วไป จะไม่มีทางส่ง null เข้าไปทับค่าเก่าได้เลย (เพราะ null ?? old = old)
  _FaceOverlayData copyWithMouthCenter(Offset? center) {
    return _FaceOverlayData(
      faces: faces,
      imageSize: imageSize,
      rotation: rotation,
      faceDetected: faceDetected,
      isSpeaking: isSpeaking,
      mouthOpenProb: mouthOpenProb,
      detectedAt: detectedAt,
      mouthCenterRaw: center,
    );
  }
}

class _FaceOverlayPainter extends CustomPainter {
  final List<Face> faces;
  final Size imageSize;
  final InputImageRotation rotation;
  final Size canvasSize;
  final bool isFrontCamera;
  final bool isSpeaking;
  final bool faceDetected;
  final double mouthOpenProb;
  // ค่าปัจจุบันของ _pulseCtrl (0..1 วนกลับไปมา) และ _waveCtrl (0..1 วนต่อเนื่อง)
  // ใช้วาดวงแสงหายใจตอนเจอหน้าเฉยๆ กับระลอกคลื่นตอนกำลังพูด
  final double pulseValue;
  final double waveValue;
  // เวลาที่ตรวจจับเสร็จรอบล่าสุด กับเวลาปัจจุบัน (คำนวณตอนสั่งวาดแต่ละครั้ง)
  // ใช้เทียบกันว่าข้อมูล faces ชุดนี้ค้างมานานแค่ไหนแล้ว
  final DateTime? detectedAt;
  final DateTime now;
  // จุดกึ่งกลางปาก คำนวณไว้แล้วจากภายนอก (ดู _mouthCenterRaw) ที่นี่แค่ scale
  // ลงผืนวาด ไม่ไล่จุด contour ใหม่ — จุดนี้คือหัวใจของการแก้ปัญหา GC ถี่
  final Offset? mouthCenterRaw;
  // ป้ายสถานะสร้าง+ layout() มาแล้วครั้งเดียวจากภายนอก (ดู _buildStatusLabel)
  // painter แค่ paint() ซ้ำทุกเฟรม ไม่ต้องสร้าง TextPainter ใหม่ทุกครั้ง
  final TextPainter foundLabelPainter;
  final TextPainter listeningLabelPainter;

  // ข้อมูลเก่ากว่านี้ถือว่าเชื่อไม่ได้แล้ว เพราะระหว่างนั้น ML Kit อาจค้าง
  // (เช่นตอนอีมูเลเตอร์กระตุก — เจอมาแล้วว่าค้างได้นานเป็นสิบวินาที) แสดง
  // ป้าย/วงแสงจากข้อมูลเก่าขนาดนั้นต่อไปจะโกหกผู้ใช้ว่า "เจอหน้าแล้ว" ทั้งที่
  // อาจไม่มีหน้าอยู่ตรงนั้นแล้วก็ได้ ใช้ค่าเดียวกับ _mouthRoiMaxAge ในหน้าจอ
  // เพื่อให้ทั้งแอปมีความหมายเดียวกันว่า "ข้อมูลจากการตรวจจับเก่าแค่ไหนถึงเชื่อไม่ได้"
  static const _maxAge = Duration(milliseconds: 1500);

  _FaceOverlayPainter({
    required this.faces,
    required this.imageSize,
    required this.rotation,
    required this.canvasSize,
    required this.isFrontCamera,
    required this.isSpeaking,
    required this.faceDetected,
    required this.mouthOpenProb,
    required this.pulseValue,
    required this.waveValue,
    required this.detectedAt,
    required this.now,
    required this.mouthCenterRaw,
    required this.foundLabelPainter,
    required this.listeningLabelPainter,
  });

  bool get _isStale =>
      detectedAt == null || now.difference(detectedAt!) > _maxAge;

  @override
  void paint(Canvas canvas, Size size) {
    if (faces.isEmpty || _isStale) {
      _drawIdleFrame(canvas, size);
      return;
    }

    _logGeometryOnce(size);
    _drawStatusChip(canvas);
    _drawMouthFocus(canvas, size);
  }

  void _drawIdleFrame(Canvas canvas, Size size) {
    final textPainter = TextPainter(
      text: const TextSpan(
        text: 'หันหน้าเข้ากล้อง',
        style: TextStyle(
          color: Colors.white70,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    
    textPainter.paint(canvas, const Offset(16, 16));
  }

  /// เดิมตรงนี้วาดข้อความเขียวนีออนสไตล์ debug computer-vision ("พบใบหน้า")
  /// พร้อมเส้นตาข่ายพาดทับทั้งหน้า (คิ้ว-ตา-จมูก-ปาก) ซึ่งดูเหมือนถูกเครื่อง
  /// สแกนมากกว่าแอปสื่อสารที่ควรรู้สึกอบอุ่น — เปลี่ยนเป็นชิปสถานะโทนขาวนวล
  /// บวกวงแสงเฉพาะรอบปาก (จุดที่ผู้ใช้ต้องโฟกัสจริงๆ) แทน
  void _drawStatusChip(Canvas canvas) {
    // สร้างมาจากภายนอกครั้งเดียวแล้ว (ดู _buildStatusLabel) ที่นี่แค่เลือกใช้
    // ไม่ layout() ใหม่ — เคยสร้าง+layout() ใหม่ตรงนี้ทุกครั้งที่ paint() ทำงาน
    // ซึ่งตอนนี้เกิดที่ 60 fps ตามรอบแอนิเมชันวงแสง ทำให้ GC ทำงานถี่ผิดปกติ
    final textPainter = isSpeaking ? listeningLabelPainter : foundLabelPainter;
    final dotColor = isSpeaking ? AppTheme.successDark : AppTheme.success;

    const dotRadius = 4.0;
    const paddingH = 12.0;
    const paddingV = 7.0;
    const gap = 7.0;
    final chipWidth = paddingH * 2 + dotRadius * 2 + gap + textPainter.width;
    final chipHeight = paddingV * 2 + textPainter.height;
    final chipRect = Rect.fromLTWH(12, 12, chipWidth, chipHeight);

    canvas.drawRRect(
      RRect.fromRectAndRadius(chipRect, Radius.circular(chipHeight / 2)),
      Paint()..color = Colors.white.withOpacity(0.92),
    );

    final dotCenter = Offset(
      chipRect.left + paddingH + dotRadius,
      chipRect.top + chipHeight / 2,
    );
    canvas.drawCircle(dotCenter, dotRadius, Paint()..color = dotColor);

    textPainter.paint(
      canvas,
      Offset(dotCenter.dx + dotRadius + gap, chipRect.top + paddingV),
    );
  }

  /// แปลงจุดกึ่งกลางปาก (คำนวณไว้แล้วจากภายนอก ในพิกัดดิบของ ML Kit) ให้เป็น
  /// พิกัดบนผืนวาด ให้ตรงกับที่ CameraPreview วาดจริง — สูตรเดียวกับที่ใช้แปลง
  /// พิกัดครอปภาพปากตอนเก็บเฟรม ต่างกันแค่ที่นี่รับพิกัดดิบทีละจุดเดียว
  /// (ไม่ใช่ไล่ทั้ง contour) เพราะจุดนั้นถูกเฉลี่ยไว้เรียบร้อยแล้วตั้งแต่ตอน
  /// ตรวจจับเสร็จ ไม่ใช่ตอน paint()
  Offset _toCanvasSpace(Offset raw, Size widgetSize) {
    final double imageW, imageH;
    if (rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg) {
      imageW = imageSize.height;
      imageH = imageSize.width;
    } else {
      imageW = imageSize.width;
      imageH = imageSize.height;
    }

    final scale = min(widgetSize.width / imageW, widgetSize.height / imageH);
    final dx = (widgetSize.width - imageW * scale) / 2;
    final dy = (widgetSize.height - imageH * scale) / 2;
    return Offset(dx + raw.dx * scale, dy + raw.dy * scale);
  }

  void _drawMouthFocus(Canvas canvas, Size size) {
    final raw = mouthCenterRaw;
    if (raw == null) return;
    final center = _toCanvasSpace(raw, size);

    // ยิ่งปากอ้ากว้าง วงแสงยิ่งใหญ่ขึ้น — ผูกกับข้อมูลจริงแทนที่จะเป็นแค่ตกแต่ง
    final baseRadius = 22.0 + mouthOpenProb.clamp(0.0, 1.0) * 20.0;

    final glowPaint = Paint()
      ..color = AppTheme.primary.withOpacity(isSpeaking ? 0.28 : 0.16)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    canvas.drawCircle(center, baseRadius, glowPaint);

    if (isSpeaking) {
      // ระลอกคลื่นขยายออกตอนกำลังพูด ขับเคลื่อนด้วย _waveCtrl ซึ่งวนต่อเนื่อง
      // วาดสองวงเหลื่อมเฟสกันครึ่งรอบ ให้เห็นเป็นคลื่นไหลต่อเนื่องไม่ใช่วงเดียว
      // กระตุกทุกครั้งที่วนรอบใหม่
      for (final phase in [0.0, 0.5]) {
        final t = (waveValue + phase) % 1.0;
        final ringPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = AppTheme.primary.withOpacity((1 - t) * 0.5);
        canvas.drawCircle(center, baseRadius + t * 22, ringPaint);
      }
    } else {
      // หายใจเบาๆ ตอนแค่เจอหน้าแต่ยังไม่พูด ขับเคลื่อนด้วย _pulseCtrl ซึ่งวน
      // กลับไปมา (reverse) ให้รู้สึกว่าแอปยังทำงานอยู่แม้ผู้ใช้ยังไม่เริ่มพูด
      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = AppTheme.primary.withOpacity(0.35);
      canvas.drawCircle(center, baseRadius + pulseValue * 4, ringPaint);
    }
  }


  /// พิมพ์ขนาดจริงครั้งเดียว ไว้ตรวจว่าการแปลงพิกัดข้างบนตั้งสมมติฐานถูกมั้ย
  static bool _loggedGeometry = false;
  void _logGeometryOnce(Size widgetSize) {
    if (_loggedGeometry) return;
    _loggedGeometry = true;
    debugPrint('📐 overlay: canvas=${widgetSize.width.toStringAsFixed(0)}x'
        '${widgetSize.height.toStringAsFixed(0)} '
        'image=${imageSize.width.toStringAsFixed(0)}x'
        '${imageSize.height.toStringAsFixed(0)} rotation=$rotation');
  }

  @override
  bool shouldRepaint(covariant _FaceOverlayPainter oldDelegate) {
    return oldDelegate.faces != faces ||
        oldDelegate.isSpeaking != isSpeaking ||
        oldDelegate.mouthOpenProb != mouthOpenProb ||
        // ต้องเทียบสองค่านี้ด้วย ไม่งั้นวงแสงจะไม่ขยับเลยแม้ตัวควบคุม
        // แอนิเมชันจะวิ่งอยู่ก็ตาม เพราะ CustomPainter ไม่ repaint เอง
        oldDelegate.pulseValue != pulseValue ||
        oldDelegate.waveValue != waveValue;
  }
}

enum _SpeakingState { idle, speaking, paused, finalizing }
