import 'dart:async';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/models/phrase_model.dart';
import '../../../shared/services/tts_service.dart';
import '../../../shared/services/storage_service.dart';

/// ─────────────────────────────────────────────────────────────────────────────
/// Real-time lip reading scanner screen
/// Pipeline:
///   Camera image stream → ML Kit FaceDetector → mouth open/close ratio
///   → speaking state machine → simulate word-by-word detection
///   → word-by-word TTS playback in real-time
/// ─────────────────────────────────────────────────────────────────────────────
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
      enableClassification: true, // gives mouthOpenProbability
      enableLandmarks: true,
      performanceMode: FaceDetectorMode.fast,
    ),
  );
  bool _isProcessingFrame = false;

  // ─── Mouth state ──────────────────────────────────────────────────────────
  double _mouthOpenProb = 0.0;
  bool _faceDetected = false;
  static const double _mouthOpenThreshold = 0.45;
  static const double _mouthCloseThreshold = 0.20;

  // ─── Speaking state machine ────────────────────────────────────────────────
  // States: idle → listening → speaking → paused → finalizing
  _SpeakingState _state = _SpeakingState.idle;
  Timer? _silenceTimer; // fires when mouth closed long enough → finalize
  Timer? _wordTimer; // fires to emit next simulated word
  Duration _silenceGap = const Duration(milliseconds: 800);
  int _consecutiveSilenceFrames = 0;
  int _consecutiveSpeakFrames = 0;
  static const int _speakFrameThreshold = 3;
  static const int _silenceFrameThreshold = 8;

  // ─── Output ───────────────────────────────────────────────────────────────
  /// Words emitted so far in the current utterance
  List<String> _words = [];
  String get _displayText => _words.join(' ');
  String _currentEmotion = 'neutral';

  /// Pool of simulated phrases (word lists)
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
  String _userName = '';
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
    _loadUser();
    _initCamera();
  }

  Future<void> _loadUser() async {
    final user = await StorageService.getCurrentUser();
    if (mounted) setState(() => _userName = user?.name.split(' ').first ?? '');
  }

  // ─── Camera init ──────────────────────────────────────────────────────────
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
      imageFormatGroup: ImageFormatGroup.nv21, // best for ML Kit on Android
    );

    await controller.initialize();
    if (!mounted) {
      controller.dispose();
      return;
    }

    _cameraController?.dispose();
    _cameraController = controller;

    // Start image stream for real-time processing
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

  // ─── ML Kit frame processing ──────────────────────────────────────────────
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

      if (faces.isEmpty) {
        _updateMouthState(0.0, faceDetected: false);
      } else {
        final face = faces.first;
        final prob = face.smilingProbability ?? 0.0;
        // Use leftEyeOpenProbability as proxy for mouth + face liveliness
        // mouthOpenProbability is the key value from ML Kit classification
        final mouthOpen = _estimateMouthOpen(face);
        _updateMouthState(mouthOpen, faceDetected: true, smiling: prob > 0.6);
      }
    } catch (e) {
      debugPrint('ML Kit error: $e');
    }

    _isProcessingFrame = false;
  }

  InputImage? _buildInputImage(CameraImage image, CameraDescription camera) {
    try {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      final rotation =
          InputImageRotationValue.fromRawValue(camera.sensorOrientation) ??
              InputImageRotation.rotation0deg;

      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      if (format == null) return null;

      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } catch (e) {
      return null;
    }
  }

  /// Estimate mouth openness from face landmarks
  double _estimateMouthOpen(Face face) {
    // ML Kit provides mouth contour points when landmarks enabled
    final bottomMouth = face.landmarks[FaceLandmarkType.bottomMouth];
    final leftMouth = face.landmarks[FaceLandmarkType.leftMouth];
    final rightMouth = face.landmarks[FaceLandmarkType.rightMouth];

    if (bottomMouth != null && leftMouth != null && rightMouth != null) {
      // Approximate mouth height vs width ratio
      final mouthWidth = (rightMouth.position.x - leftMouth.position.x).abs();
      // Use nose-to-mouth distance as reference
      final noseBase = face.landmarks[FaceLandmarkType.noseBase];
      if (noseBase != null && mouthWidth > 0) {
        final noseToMouth =
            (bottomMouth.position.y - noseBase.position.y).abs();
        final ratio = noseToMouth / (face.boundingBox.height * 0.35);
        return ratio.clamp(0.0, 1.0);
      }
    }

    // Fallback: use bounding box tracking trick — mouth open produces
    // slightly different face bbox aspect ratio, but this is unreliable.
    // Use a random-walk simulation anchored to face detection as fallback.
    return 0.0;
  }

  // ─── Speaking state machine ────────────────────────────────────────────────
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

    // Pick random phrase
    final rng = Random();
    final idx = rng.nextInt(_wordPool.length);
    _currentWordList = _wordPool[idx];
    _currentEmotion = _emotionPool[idx];
    _wordIndex = 0;

    setState(() {
      _state = _SpeakingState.speaking;
      _words = [];
    });

    _scheduleNextWord();
  }

  void _scheduleNextWord() {
    if (_wordIndex >= _currentWordList.length) {
      // All words emitted
      _finalizeUtterance();
      return;
    }
    _wordTimer?.cancel();
    _wordTimer = Timer(const Duration(milliseconds: 380), () {
      if (!mounted) return;
      if (_state != _SpeakingState.speaking) return;

      final word = _currentWordList[_wordIndex++];
      setState(() => _words = [..._words, word]);

      // Speak word immediately (real-time!)
      _speakWordRealtime(word);

      _scheduleNextWord();
    });
  }

  Future<void> _speakWordRealtime(String word) async {
    // Each word spoken as it appears
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
    if (_words.isEmpty) {
      setState(() => _state = _SpeakingState.idle);
      return;
    }
    setState(() => _state = _SpeakingState.finalizing);
    // After short pause go back to idle (ready for next)
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _state = _SpeakingState.idle);
    });
  }

  // ─── Save phrase ──────────────────────────────────────────────────────────
  Future<void> _savePhrase() async {
    if (_displayText.isEmpty) return;
    final box = Hive.box<PhraseModel>('phrases');
    final existing = box.values
        .cast<PhraseModel?>()
        .firstWhere((p) => p?.text == _displayText, orElse: () => null);
    if (existing != null) {
      existing.usageCount++;
      await existing.save();
    } else {
      await box.add(PhraseModel(
        id: _uuid.v4(),
        text: _displayText,
        emotion: _currentEmotion,
        createdAt: DateTime.now(),
      ));
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(children: [
            const Icon(Icons.bookmark_added, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text('บันทึก "$_displayText" แล้ว'),
          ]),
          backgroundColor: AppTheme.success,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 2),
        ),
      );
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

  // ─── Dispose ──────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _wordTimer?.cancel();
    _silenceTimer?.cancel();
    _pulseCtrl.dispose();
    _waveCtrl.dispose();
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _faceDetector.close();
    _tts.stop();
    super.dispose();
  }

  // ─── UI helpers ───────────────────────────────────────────────────────────
  Color get _emotionColor {
    switch (_currentEmotion) {
      case 'happy':
        return const Color(0xFF4CAF50);
      case 'sad':
        return const Color(0xFF2196F3);
      case 'angry':
        return const Color(0xFFEF5350);
      default:
        return AppTheme.textSecondary;
    }
  }

  String get _emotionLabel {
    switch (_currentEmotion) {
      case 'happy':
        return '😊 มีความสุข';
      case 'sad':
        return '😢 เศร้า';
      case 'angry':
        return '😠 โกรธ';
      default:
        return '😐 ปกติ';
    }
  }

  String get _stateLabel {
    switch (_state) {
      case _SpeakingState.idle:
        return 'รอตรวจจับ...';
      case _SpeakingState.speaking:
        return '🎙 กำลังวิเคราะห์...';
      case _SpeakingState.paused:
        return '⏸ หยุดชั่วคราว';
      case _SpeakingState.finalizing:
        return '✅ วิเคราะห์เสร็จแล้ว';
      default:
        return '';
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────
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
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Camera preview or placeholder
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

            // Face detection frame (Green corners)
            if (_cameraReady) _buildFaceFrame(),
          ],
        ),
      ),
    );
  }

  Widget _buildFaceFrame() {
    final isActive = _state == _SpeakingState.speaking;
    // We want to simulate the green box and corners from the mockup
    return Stack(
      children: [
        Center(
          child: Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              border: Border.all(
                color: isActive
                    ? AppTheme.success
                    : AppTheme.success.withOpacity(0.5),
                width: 2,
              ),
            ),
          ),
        ),
        // Draw corners
        Center(
          child: SizedBox(
            width: 220,
            height: 220,
            child: Stack(
              children: [
                Positioned(top: -2, left: -2, child: _buildCorner()),
                Positioned(
                    top: -2,
                    right: -2,
                    child: RotatedBox(quarterTurns: 1, child: _buildCorner())),
                Positioned(
                    bottom: -2,
                    right: -2,
                    child: RotatedBox(quarterTurns: 2, child: _buildCorner())),
                Positioned(
                    bottom: -2,
                    left: -2,
                    child: RotatedBox(quarterTurns: 3, child: _buildCorner())),
              ],
            ),
          ),
        ),
        // Draw inner mouth box approx
        Center(
          child: Padding(
            padding: const EdgeInsets.only(top: 80), // push down to mouth area
            child: Container(
              width: 80,
              height: 40,
              decoration: BoxDecoration(
                border: Border.all(
                  color: AppTheme.success.withOpacity(isActive ? 0.8 : 0.3),
                  width: 1.5,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCorner() {
    return CustomPaint(
      size: const Size(20, 20),
      painter: _CornerPainter(color: AppTheme.success, strokeWidth: 4),
    );
  }

  // ─── Speech bubble card (wireframe style) ────────────────────────────────
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

  // ─── Action row: play + save ───────────────────────────────────────────────
  Widget _buildActionRow() {
    final hasText = _words.isNotEmpty;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Save button
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

        // Voice button (Green)
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

        // Reset button
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

class _CornerPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  _CornerPainter({required this.color, required this.strokeWidth});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;

    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(0, 0)
      ..lineTo(size.width, 0);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
// ─── Enums & Sub-widgets ─────────────────────────────────────────────────────

enum _SpeakingState { idle, speaking, paused, finalizing }

/// Animated word chip that bounces in when a new word is detected
class _WordChip extends StatelessWidget {
  final String word;
  final int index;
  final Color emotionColor;

  const _WordChip({
    required this.word,
    required this.index,
    required this.emotionColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: emotionColor.withOpacity(0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: emotionColor.withOpacity(0.25)),
      ),
      child: Text(
        word,
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: AppTheme.textPrimary,
        ),
      ),
    )
        .animate()
        .scale(
          begin: const Offset(0.5, 0.5),
          duration: 220.ms,
          curve: Curves.elasticOut,
        )
        .fadeIn(duration: 150.ms);
  }
}

/// Blinking typing cursor shown while detecting
class _TypingCursor extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      height: 28,
      decoration: BoxDecoration(
        color: AppTheme.primary,
        borderRadius: BorderRadius.circular(2),
      ),
    )
        .animate(onPlay: (c) => c.repeat())
        .fadeIn(duration: 400.ms)
        .then()
        .fadeOut(duration: 400.ms);
  }
}
