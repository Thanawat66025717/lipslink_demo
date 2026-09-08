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
import 'dart:ui' as ui;
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
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true, 
      enableLandmarks: true,
      enableContours: true,
      performanceMode: FaceDetectorMode.fast,
    ),
  );
  bool _isProcessingFrame = false;

  // ─── Face Overlay ─────────────────────────────────────────────────────────
  List<Face> _detectedFaces = [];
  Size? _imageSize;
  InputImageRotation? _imageRotation;

  // ─── Mouth state ──────────────────────────────────────────────────────────
  double _mouthOpenProb = 0.0;
  bool _faceDetected = false;
  // ค่าเริ่มต้นสำหรับ mouth-aspect-ratio (ช่องปาก/ความกว้างปาก) แบบใหม่ —
  // ปิดปากสนิทควรใกล้ 0, พูด/อ้าปากเบาๆ มักอยู่แถว 0.15-0.3 ค่านี้เป็นค่า
  // เริ่มต้นที่ต้อง fine-tune ต่อจากค่าจริงที่ debugPrint ออกมา
  static const double _mouthOpenThreshold = 0.15;

  // ─── Speaking state machine ────────────────────────────────────────────────
  _SpeakingState _state = _SpeakingState.idle;
  Timer? _silenceTimer; 
  Timer? _wordTimer; 
  Duration _silenceGap = const Duration(milliseconds: 800);
  int _consecutiveSilenceFrames = 0;
  int _consecutiveSpeakFrames = 0;
  static const int _speakFrameThreshold = 3;
  static const int _silenceFrameThreshold = 8;

  // ─── Output ───────────────────────────────────────────────────────────────
  List<String> _words = [];
  String get _displayText => _words.join(' ');
  String _currentEmotion = 'neutral';

  // ─── AI Lip Reading ────────────────────────────────────────────────────────
  List<Uint8List> _collectedLipFrames = [];
  bool _isApiAvailable = false;
  bool _isPredicting = false;
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
    if (mounted && available != _isApiAvailable) {
      setState(() => _isApiAvailable = available);
      debugPrint(available ? '✅ API Server พร้อมใช้งาน' : '⚠️ API Server ไม่พร้อม — ใช้โหมดสุ่มคำแทน');
    }
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
      ResolutionPreset.medium,
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
    if (_isProcessingFrame) return;
    _isProcessingFrame = true;

    try {
      final camera = _cameras[_isFrontCamera ? 1 : 0];
      final inputImage = _buildInputImage(image, camera);
      if (inputImage == null) {
        _isProcessingFrame = false;
        return;
      }

      final faces = await _faceDetector.processImage(inputImage);
      if (!mounted) {
        _isProcessingFrame = false;
        return;
      }

      // 🟢 เก็บข้อมูลใบหน้าสำหรับวาด Overlay
      final rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation) ?? InputImageRotation.rotation0deg;
      setState(() {
        _detectedFaces = faces;
        _imageSize = Size(image.width.toDouble(), image.height.toDouble());
        _imageRotation = rotation;
      });

      if (faces.isEmpty) {
        _updateMouthState(0.0, faceDetected: false);
      } else {
        final face = faces.first;
        final prob = face.smilingProbability ?? 0.0;
        final mouthOpen = _estimateMouthOpen(face);
        _updateMouthState(mouthOpen, faceDetected: true, smiling: prob > 0.6);

        // 🟢 เก็บ lip frames ขณะกำลังพูด (สำหรับส่งไป API)
        if (_state == _SpeakingState.speaking && _isApiAvailable && _collectedLipFrames.length < _maxCollectFrames) {
          await _collectLipFrame(image, face);
          // ถ้าเก็บครบ cap แล้วแต่ยังพูดต่อไม่หยุด ส่งเท่าที่มีไปประมวลผลเลย
          // ดีกว่าปล่อยให้ผู้ใช้รอเก้อจนกว่าจะตรวจพบว่าหยุดพูดจริง (frame ส่วน
          // ที่เกินมาจะไม่ถูกเก็บต่ออยู่ดี ไม่มีประโยชน์ที่จะรอเฉยๆ)
          if (_collectedLipFrames.length >= _maxCollectFrames) {
            _finalizeUtterance();
          }
        }
      }
    } catch (e) {
      debugPrint('ML Kit error: $e');
    }

    _isProcessingFrame = false;
  }

  /// เก็บภาพปากจาก camera frame โดยครอปจาก face bounding box
  Future<void> _collectLipFrame(CameraImage image, Face face) async {
    try {
      // ครอปบริเวณปากจาก face bounding box
      final rect = face.boundingBox;
      // ปากอยู่ประมาณครึ่งล่างของใบหน้า
      final mouthTop = rect.top + rect.height * 0.6;
      final mouthHeight = rect.height * 0.4;
      final mouthLeft = rect.left + rect.width * 0.1;
      final mouthWidth = rect.width * 0.8;

      // แปลง NV21 เป็น grayscale (Y channel เท่านั้น)
      final int width = image.width;
      final int height = image.height;
      final yPlane = image.planes[0].bytes;

      // Crop mouth region จาก Y plane
      final int cropX = mouthLeft.toInt().clamp(0, width - 1);
      final int cropY = mouthTop.toInt().clamp(0, height - 1);
      final int cropW = mouthWidth.toInt().clamp(1, width - cropX);
      final int cropH = mouthHeight.toInt().clamp(1, height - cropY);

      // สร้าง cropped image bytes
      final croppedBytes = Uint8List(cropW * cropH);
      for (int y = 0; y < cropH; y++) {
        for (int x = 0; x < cropW; x++) {
          final srcIdx = (cropY + y) * image.planes[0].bytesPerRow + (cropX + x);
          if (srcIdx < yPlane.length) {
            croppedBytes[y * cropW + x] = yPlane[srcIdx];
          }
        }
      }

      // Encode เป็น PNG bytes จริงๆ ก่อนส่งไป API — เซิร์ฟเวอร์ถอดรหัสด้วย
      // cv2.imdecode/PIL ซึ่งต้องการไฟล์ภาพที่ encode แล้ว ส่ง raw pixel bytes
      // ตรงๆ แบบเดิมจะถอดรหัสไม่ออกและทำให้ prediction ล้มเหลวเงียบๆ
      final pngBytes = await _encodeGrayscalePng(croppedBytes, cropW, cropH);
      _collectedLipFrames.add(pngBytes);
    } catch (e) {
      debugPrint('Lip frame collection error: $e');
    }
  }

  /// แปลง grayscale bytes (1 byte/pixel) เป็นไฟล์ PNG จริง
  Future<Uint8List> _encodeGrayscalePng(
      Uint8List grayscale, int width, int height) async {
    final rgba = Uint8List(width * height * 4);
    for (int i = 0; i < grayscale.length; i++) {
      final v = grayscale[i];
      rgba[i * 4] = v;
      rgba[i * 4 + 1] = v;
      rgba[i * 4 + 2] = v;
      rgba[i * 4 + 3] = 255;
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final image = await completer.future;
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData!.buffer.asUint8List();
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

    setState(() {
      _mouthOpenProb = mouthOpen;
      _faceDetected = faceDetected;
      if (smiling) _currentEmotion = 'happy';
    });

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
    });

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
    if (_isPredicting) return;
    setState(() {
      _isPredicting = true;
      _state = _SpeakingState.finalizing;
      _words = ['กำลังอ่านปาก...'];
    });

    try {
      final result = await LipReadingApiService.predictFromFrames(
        _collectedLipFrames,
        model: 'model1',
      );

      if (result != null && result.text.isNotEmpty && mounted) {
        setState(() {
          _words = [result.text];
        });

        // TTS อ่านออกเสียง
        await _tts.speak(result.text, emotion: _currentEmotion);

        debugPrint('🔮 AI Prediction: ${result.text} (confidence: ${(result.confidence * 100).toStringAsFixed(1)}%, time: ${result.processingTimeMs}ms)');
      } else {
        // Fallback ถ้า API ไม่ส่งผลลัพธ์
        if (mounted) {
          setState(() {
            _words = ['(ไม่สามารถอ่านได้)'];
          });
        }
      }
    } catch (e) {
      debugPrint('❌ API prediction error: $e');
      if (mounted) {
        setState(() {
          _words = ['(เกิดข้อผิดพลาด)'];
        });
      }
    } finally {
      _collectedLipFrames = [];
      if (mounted) {
        setState(() => _isPredicting = false);
        Future.delayed(const Duration(seconds: 4), () {
          if (mounted) setState(() => _state = _SpeakingState.idle);
        });
      }
    }
  }

  // ─── Save phrase to Firebase ──────────────────────────────────────────────
  Future<void> _savePhrase() async {
    if (_displayText.isEmpty) return;

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
    if (_displayText.isEmpty) return;
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
    _pulseCtrl.dispose();
    _waveCtrl.dispose();
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
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
    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomPaint(
          size: Size(constraints.maxWidth, constraints.maxHeight),
          painter: _FaceOverlayPainter(
            faces: _detectedFaces,
            imageSize: _imageSize ?? const Size(480, 640),
            rotation: _imageRotation ?? InputImageRotation.rotation0deg,
            canvasSize: Size(constraints.maxWidth, constraints.maxHeight),
            isFrontCamera: _isFrontCamera,
            isSpeaking: _state == _SpeakingState.speaking,
            faceDetected: _faceDetected,
            mouthOpenProb: _mouthOpenProb,
          ),
        );
      },
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
              style: const TextStyle(
                  fontSize: 16,
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            )
          : const Text(
              'รอการอ่านริมฝีปาก...',
              style: TextStyle(fontSize: 14, color: AppTheme.textHint),
              textAlign: TextAlign.center,
            ),
    );
  }

  Widget _buildActionRow() {
    final hasText = _words.isNotEmpty;
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
                  color: Colors.white,
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
            Text('บันทึก',
                style: TextStyle(
                    fontSize: 10,
                    color: hasText ? AppTheme.textPrimary : AppTheme.textHint)),
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
                  color: AppTheme.success,
                  boxShadow: hasText && !_isTtsSpeaking
                      ? [
                          BoxShadow(
                              color: AppTheme.success.withOpacity(0.4),
                              blurRadius: 15,
                              offset: const Offset(0, 5))
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
            const Text('Voice',
                style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w600)),
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
                  color: Colors.white,
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
            const Text('Reset',
                style: TextStyle(fontSize: 10, color: AppTheme.textPrimary)),
          ],
        ),
      ],
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

  _FaceOverlayPainter({
    required this.faces,
    required this.imageSize,
    required this.rotation,
    required this.canvasSize,
    required this.isFrontCamera,
    required this.isSpeaking,
    required this.faceDetected,
    required this.mouthOpenProb,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (faces.isEmpty) {
      _drawIdleFrame(canvas, size);
      return;
    }

    for (final face in faces) {
      _drawFaceTracking(canvas, size, face);
    }
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

  void _drawFaceTracking(Canvas canvas, Size size, Face face) {
    // 1) Text "พบใบหน้า" or "กำลังพูด..."
    final label = isSpeaking ? 'กำลังพูด...' : 'พบใบหน้า';
    final textColor = isSpeaking ? const Color(0xFF4CAF50) : const Color(0xFF00FF00);

    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: textColor,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    
    textPainter.paint(canvas, const Offset(16, 16));

    // 2) Contour Wireframe Mesh — เส้นตาข่ายตาม contour ของใบหน้า
    final contourTypes = [
      FaceContourType.face,
      FaceContourType.leftEyebrowTop,
      FaceContourType.leftEyebrowBottom,
      FaceContourType.rightEyebrowTop,
      FaceContourType.rightEyebrowBottom,
      FaceContourType.leftEye,
      FaceContourType.rightEye,
      FaceContourType.noseBottom,
      FaceContourType.noseBridge,
      FaceContourType.upperLipTop,
      FaceContourType.upperLipBottom,
      FaceContourType.lowerLipTop,
      FaceContourType.lowerLipBottom,
    ];

    for (final type in contourTypes) {
      final contour = face.contours[type];
      if (contour == null || contour.points.isEmpty) continue;

      final points = contour.points.map((p) => _scalePoint(p, size)).toList();

      // กำหนดสีเป็นสีเขียวสไตล์ AI Vision
      Color lineColor = const Color(0xFF00FF00); 
      double lineWidth = 0.8;
      double dotRadius = 1.5;
      
      final isLip = type == FaceContourType.upperLipTop ||
          type == FaceContourType.upperLipBottom ||
          type == FaceContourType.lowerLipTop ||
          type == FaceContourType.lowerLipBottom;
      final isEye = type == FaceContourType.leftEye ||
          type == FaceContourType.rightEye;

      if (isLip) {
        lineColor = isSpeaking ? const Color(0xFF4CAF50) : const Color(0xFF00FF00);
        lineWidth = 1.2;
        dotRadius = 2.0;
      } else if (isEye) {
        lineWidth = 1.0;
        dotRadius = 1.8;
      }

      // วาดเส้นเชื่อมจุด contour
      final linePaint = Paint()
        ..color = lineColor.withOpacity(0.5) // เส้นเขียวจางๆ
        ..strokeWidth = lineWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      if (points.length > 1) {
        final path = Path()..moveTo(points.first.dx, points.first.dy);
        for (int i = 1; i < points.length; i++) {
          path.lineTo(points[i].dx, points[i].dy);
        }
        // ปิดเส้นสำหรับ ตา, ขอบหน้า
        if (isEye || type == FaceContourType.face) {
          path.close();
        }
        canvas.drawPath(path, linePaint);
      }

      // วาดจุดสีเขียว
      final dotPaint = Paint()
        ..color = lineColor
        ..style = PaintingStyle.fill;
      for (final p in points) {
        canvas.drawCircle(p, dotRadius, dotPaint);
      }
    }
  }

  Rect _scaleRect(Rect faceRect, Size widgetSize) {
    double imageW, imageH;

    if (rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg) {
      imageW = imageSize.height;
      imageH = imageSize.width;
    } else {
      imageW = imageSize.width;
      imageH = imageSize.height;
    }

    final scaleX = widgetSize.width / imageW;
    final scaleY = widgetSize.height / imageH;

    // 🟢 ไม่ต้อง flip พิกัดเองแล้ว เพราะ widget แม่ (ScannerScreen) ครอบทั้ง
    // CameraPreview กับ overlay นี้ไว้ใน Transform เดียวกันสำหรับกล้องหน้า
    // ถ้า flip ซ้ำที่นี่อีกจะกลายเป็น flip 2 ต่อ จุดจะไปคนละตำแหน่งกับใบหน้า
    final left = faceRect.left * scaleX;
    final top = faceRect.top * scaleY;
    final right = faceRect.right * scaleX;
    final bottom = faceRect.bottom * scaleY;

    return Rect.fromLTRB(left, top, right, bottom);
  }

  Offset _scalePoint(Point<int> point, Size widgetSize) {
    double imageW, imageH;

    if (rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg) {
      imageW = imageSize.height;
      imageH = imageSize.width;
    } else {
      imageW = imageSize.width;
      imageH = imageSize.height;
    }

    final scaleX = widgetSize.width / imageW;
    final scaleY = widgetSize.height / imageH;

    // 🟢 เหตุผลเดียวกับ _getFaceRect — ไม่ flip ที่นี่แล้ว เพราะ Transform
    // ระดับ widget ด้านนอกจัดการ mirror ให้ทั้ง preview และ overlay พร้อมกัน
    final x = point.x.toDouble() * scaleX;
    final y = point.y.toDouble() * scaleY;

    return Offset(x, y);
  }

  @override
  bool shouldRepaint(covariant _FaceOverlayPainter oldDelegate) {
    return oldDelegate.faces != faces ||
        oldDelegate.isSpeaking != isSpeaking ||
        oldDelegate.mouthOpenProb != mouthOpenProb;
  }
}

enum _SpeakingState { idle, speaking, paused, finalizing }