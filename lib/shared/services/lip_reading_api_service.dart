import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Service สำหรับเชื่อมต่อกับ LipsLink API Server
/// ส่ง lip frames ไปให้โมเดล AI อ่านปากแล้วรับข้อความกลับมา
class LipReadingApiService {
  // 🔧 กำหนด URL ผ่าน --dart-define=API_BASE_URL=... ตอน build/run
  // ไม่ระบุ = ใช้ค่า default ด้านล่าง (Android emulator loopback สำหรับ dev)
  //
  // ตัวอย่างรัน dev กับเครื่องจริงในวง LAN เดียวกัน:
  //   flutter run --dart-define=API_BASE_URL=http://192.168.1.100:8000
  // ตัวอย่าง build production หลัง deploy ขึ้น Render:
  //   flutter build apk --dart-define=API_BASE_URL=https://lipslink-api.onrender.com
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );

  static const Duration _timeout = Duration(seconds: 30);

  /// เช็กว่า Server พร้อมใช้งานหรือไม่
  static Future<bool> checkHealth() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/health'))
          .timeout(_timeout);
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// โหมดทดลอง: อ่านปากเป็นข้อความอิสระด้วยโมเดลประโยค (CTC ระดับตัวอักษร)
  ///
  /// ส่ง "ทุกเฟรม" ที่เก็บได้ ไม่ต้องลดจำนวน และต้องส่ง [captureMs] มาเสมอ
  /// เพราะ server ใช้ยืดเฟรมให้เป็น 25 fps ตามตอนเทรน ภาพต้องเป็น RGB ตามเดิม
  static Future<SentencePrediction?> predictSentence(
    List<Uint8List> frames, {
    required int roiSize,
    required int captureMs,
  }) async {
    if (frames.isEmpty) return null;

    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/predict_sentence'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'frames': frames.map(base64Encode).toList(),
              'frame_format': 'rgb',
              'roi': roiSize,
              'capture_ms': captureMs,
            }),
          )
          .timeout(_timeout);

      if (response.statusCode != 200) {
        debugPrint(
            '❌ predict_sentence ${response.statusCode}: ${utf8.decode(response.bodyBytes)}');
        return null;
      }

      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return SentencePrediction.fromJson(data);
    } catch (e) {
      debugPrint('❌ predict_sentence failed: $e');
      return null;
    }
  }

  // ─── VocaLip v4 (200 คำ) ───────────────────────────────────────────────────
  //
  // v4 อ่านจากจุดบนใบหน้าที่ server หาเองด้วย MediaPipe จึงรับ "ภาพทั้งหน้า"
  // (JPEG) ไม่ใช่ภาพปาก และต้องได้เวลาของแต่ละเฟรม server ยืดเป็น 25 fps เอง

  /// ค่าที่โมเดล v4 ต้องการ (fps, ความยาวคลิป, วิธีครอป) — คืน null ถ้าถามไม่ได้
  static Future<V4ModelInfo?> fetchV4ModelInfo() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/v4/model_info'))
          .timeout(_timeout);
      if (response.statusCode != 200) return null;
      return V4ModelInfo.fromJson(
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('v4/model_info failed: $e');
      return null;
    }
  }

  /// ส่งภาพหน้าช่วงปรับเทียบ (~20 วินาที) ได้ค่าประจำตัวผู้ใช้กลับมาเก็บในเครื่อง
  static Future<V4CalibrateResult> calibrateV4(
    List<Uint8List> jpegFrames,
    List<double> timestampsMs,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/v4/calibrate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'frames': jpegFrames.map(base64Encode).toList(),
              'timestamps_ms': timestampsMs,
              'frame_format': 'jpeg',
            }),
          )
          .timeout(_timeout);
      final data = _decodeBody(response);
      if (response.statusCode != 200) {
        return V4CalibrateResult.failed(response.statusCode, data['detail']?.toString());
      }
      return V4CalibrateResult(
        statusCode: 200,
        calibration: V4Calibration(
          featMean: _doubles(data['feat_mean']),
          featStd: _doubles(data['feat_std']),
          modelVersion: data['model_version'] as String? ?? '',
        ),
        framesWithFace: (data['frames_with_face'] as num?)?.toInt() ?? 0,
        warning: data['warning'] as String?,
      );
    } catch (e) {
      debugPrint('❌ v4/calibrate failed: $e');
      return V4CalibrateResult.failed(0, '$e');
    }
  }

  /// ทายคำจากภาพหน้าหนึ่งช่วง — ผลมีรูปแบบเดียวกับ [predictWord] เดิม
  ///
  /// ไม่ส่ง [calibration] = server ใช้ค่ากลาง ซึ่งแม่นน้อยกว่ามาก
  static Future<V4PredictResult> predictWordV4(
    List<Uint8List> jpegFrames,
    List<double> timestampsMs, {
    V4Calibration? calibration,
    int topK = 5,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/v4/predict_word'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'frames': jpegFrames.map(base64Encode).toList(),
              'timestamps_ms': timestampsMs,
              'frame_format': 'jpeg',
              'top_k': topK,
              if (calibration != null) 'feat_mean': calibration.featMean,
              if (calibration != null) 'feat_std': calibration.featStd,
            }),
          )
          .timeout(_timeout);
      final data = _decodeBody(response);
      if (response.statusCode != 200) {
        return V4PredictResult(
            statusCode: response.statusCode, detail: data['detail']?.toString());
      }
      return V4PredictResult(
        statusCode: 200,
        prediction: WordPrediction.fromJson(data),
        faceRatio: (data['face_ratio'] as num?)?.toDouble(),
        captureFps: (data['capture_fps'] as num?)?.toDouble(),
        calibrated: data['calibrated'] as bool? ?? false,
        modelVersion: data['model_version'] as String?,
      );
    } catch (e) {
      debugPrint('❌ v4/predict_word failed: $e');
      return V4PredictResult(statusCode: 0, detail: '$e');
    }
  }

  static Map<String, dynamic> _decodeBody(http.Response response) {
    try {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static List<double> _doubles(dynamic list) =>
      (list as List? ?? const []).map((e) => (e as num).toDouble()).toList();

  /// ดูรายชื่อโมเดลที่มีบน Server
  static Future<Map<String, dynamic>?> getModels() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/models'))
          .timeout(_timeout);

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return null;
    } catch (e) {
      return null;
    }
  }
}

/// ค่าที่โมเดล v4 ต้องการ อ่านจาก /v4/model_info (ห้ามฝังไว้ในแอป เพราะรุ่น
/// โมเดลถัดไปเปลี่ยนได้ทั้งรายการคำและความยาวคลิป)
class V4ModelInfo {
  final String version;
  final double fps;
  final int minFrames;
  final int maxFrames;
  final double calibrationSeconds;
  final int cropSize;
  final double boxScale;
  final int jpegQuality;

  const V4ModelInfo({
    required this.version,
    required this.fps,
    required this.minFrames,
    required this.maxFrames,
    required this.calibrationSeconds,
    required this.cropSize,
    required this.boxScale,
    required this.jpegQuality,
  });

  double get maxSeconds => maxFrames / fps;

  factory V4ModelInfo.fromJson(Map<String, dynamic> json) {
    final crop = json['recommended_face_crop'] as Map<String, dynamic>? ?? {};
    return V4ModelInfo(
      version: json['version'] as String? ?? '',
      fps: (json['fps'] as num?)?.toDouble() ?? 25.0,
      minFrames: (json['min_frames'] as num?)?.toInt() ?? 4,
      maxFrames: (json['max_frames'] as num?)?.toInt() ?? 40,
      calibrationSeconds:
          (json['calibration_seconds'] as num?)?.toDouble() ?? 20.0,
      cropSize: (crop['size'] as num?)?.toInt() ?? 192,
      boxScale: (crop['box_scale'] as num?)?.toDouble() ?? 1.4,
      jpegQuality: (crop['quality'] as num?)?.toInt() ?? 80,
    );
  }

  @override
  String toString() => '$version fps=$fps frames=$minFrames-$maxFrames '
      'crop=$cropSize x$boxScale q$jpegQuality';
}

/// ค่าปรับเทียบของผู้ใช้หนึ่งคน (110 + 110 ตัวเลข) เก็บในเครื่อง ไม่เก็บบน server
class V4Calibration {
  final List<double> featMean;
  final List<double> featStd;

  /// รุ่นโมเดลตอนปรับเทียบ — ถ้า server เปลี่ยนรุ่น ควรปรับเทียบใหม่
  final String modelVersion;

  const V4Calibration({
    required this.featMean,
    required this.featStd,
    required this.modelVersion,
  });

  Map<String, dynamic> toJson() => {
        'feat_mean': featMean,
        'feat_std': featStd,
        'model_version': modelVersion,
      };

  static V4Calibration? fromJson(Map<String, dynamic> json) {
    final mean = json['feat_mean'];
    final std = json['feat_std'];
    if (mean is! List || std is! List || mean.isEmpty) return null;
    return V4Calibration(
      featMean: mean.map((e) => (e as num).toDouble()).toList(),
      featStd: std.map((e) => (e as num).toDouble()).toList(),
      modelVersion: json['model_version'] as String? ?? '',
    );
  }
}

class V4CalibrateResult {
  final int statusCode;
  final V4Calibration? calibration;
  final int framesWithFace;
  final String? warning;
  final String? detail;

  const V4CalibrateResult({
    required this.statusCode,
    this.calibration,
    this.framesWithFace = 0,
    this.warning,
    this.detail,
  });

  factory V4CalibrateResult.failed(int statusCode, String? detail) =>
      V4CalibrateResult(statusCode: statusCode, detail: detail);
}

class V4PredictResult {
  /// 200 = สำเร็จ, 422 = ไม่เจอใบหน้า, 400 = ค่าปรับเทียบใช้กับรุ่นนี้ไม่ได้,
  /// 0 = ต่อ server ไม่ได้
  final int statusCode;
  final WordPrediction? prediction;
  final String? detail;
  final double? faceRatio;
  final double? captureFps;
  final bool calibrated;
  final String? modelVersion;

  const V4PredictResult({
    required this.statusCode,
    this.prediction,
    this.detail,
    this.faceRatio,
    this.captureFps,
    this.calibrated = false,
    this.modelVersion,
  });
}

/// ผลจากโมเดลประโยค (ทดลอง) — ไม่มีค่าความมั่นใจ จึงกรองผลมั่วไม่ได้
class SentencePrediction {
  final String text;

  /// สัดส่วนเฟรมที่โมเดลตอบว่า "ไม่มีตัวอักษร" ใกล้ 100% แปลว่าแทบไม่ได้อะไร
  final double blankRate;
  final int framesReceived;

  /// ความยาวที่โมเดลเห็นจริง หลัง server ยืดเฟรมเป็น 25 fps แล้ว
  final int framesUsed;
  final double? captureFps;
  final double processingTimeMs;

  const SentencePrediction({
    required this.text,
    required this.blankRate,
    required this.framesReceived,
    required this.framesUsed,
    required this.captureFps,
    required this.processingTimeMs,
  });

  factory SentencePrediction.fromJson(Map<String, dynamic> json) =>
      SentencePrediction(
        text: json['text'] as String? ?? '',
        blankRate: (json['blank_rate'] as num?)?.toDouble() ?? 1.0,
        framesReceived: (json['num_frames_received'] as num?)?.toInt() ?? 0,
        framesUsed: (json['num_frames_used'] as num?)?.toInt() ?? 0,
        captureFps: (json['capture_fps'] as num?)?.toDouble(),
        processingTimeMs:
            (json['processing_time_ms'] as num?)?.toDouble() ?? 0.0,
      );

  @override
  String toString() => "'$text' blank ${(blankRate * 100).toStringAsFixed(1)}% "
      '$framesReceived frames @ ${captureFps ?? '?'} fps -> $framesUsed '
      '${processingTimeMs.toStringAsFixed(0)}ms';
}

/// คำที่โมเดลเดาได้หนึ่งตัวเลือก พร้อมความมั่นใจ
class WordCandidate {
  final String word;
  final double confidence;

  const WordCandidate({required this.word, required this.confidence});

  factory WordCandidate.fromJson(Map<String, dynamic> json) => WordCandidate(
        word: json['word'] as String? ?? '',
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      );

  @override
  String toString() => '$word ${(confidence * 100).toStringAsFixed(1)}%';
}

/// ผลลัพธ์จากโมเดลทำนายคำ
class WordPrediction {
  final String word;
  final double confidence;

  /// ตัวเลือกอันดับต้นๆ เรียงจากมั่นใจที่สุด ตัวแรกคือตัวเดียวกับ [word]
  final List<WordCandidate> topK;
  final double processingTimeMs;
  final int framesUsed;

  /// server ตั้งธงนี้เมื่อความมั่นใจต่ำกว่าเกณฑ์ ไม่ได้กรองผลทิ้ง —
  /// ฝั่งแอปเป็นคนตัดสินใจเองว่าจะแสดงผลนั้นหรือไม่
  final bool lowConfidence;

  /// เกณฑ์ที่ server ใช้ตัดสิน [lowConfidence] ค่าตั้งต้นมากับไฟล์โมเดล
  /// ทับได้ที่ server ด้วยตัวแปรสภาพแวดล้อม VOCALIP_MIN_CONFIDENCE
  final double minConfidence;

  /// ระยะห่างระหว่างคำอันดับ 1 กับอันดับ 2 ใกล้กันมากแปลว่าโมเดลลังเล
  /// แม้ความมั่นใจอันดับ 1 จะดูสูงก็ตาม
  final double margin;
  final double minMargin;

  /// ปริมาณการขยับปากที่ server วัดได้จากเฟรมที่ส่งไป ปากนิ่งจะได้ 0
  final double mouthMotion;

  /// ข้อที่ไม่ผ่าน: confidence / margin / motion — ว่างแปลว่าผ่านหมด
  /// มีไว้ให้ไล่ได้ว่าถูกปฏิเสธเพราะอะไร ไม่ใช่แค่รู้ว่าถูกปฏิเสธ
  final List<String> rejectReasons;

  const WordPrediction({
    required this.word,
    required this.confidence,
    required this.topK,
    required this.processingTimeMs,
    required this.framesUsed,
    required this.lowConfidence,
    required this.minConfidence,
    required this.margin,
    required this.minMargin,
    required this.mouthMotion,
    required this.rejectReasons,
  });

  factory WordPrediction.fromJson(Map<String, dynamic> json) => WordPrediction(
        word: json['word'] as String? ?? '',
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
        topK: (json['top_k'] as List?)
                ?.map((e) => WordCandidate.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        processingTimeMs:
            (json['processing_time_ms'] as num?)?.toDouble() ?? 0.0,
        framesUsed: (json['num_frames_used'] as num?)?.toInt() ?? 0,
        lowConfidence: json['low_confidence'] as bool? ?? false,
        minConfidence: (json['min_confidence'] as num?)?.toDouble() ?? 0.0,
        margin: (json['margin'] as num?)?.toDouble() ?? 0.0,
        minMargin: (json['min_margin'] as num?)?.toDouble() ?? 0.0,
        mouthMotion: (json['mouth_motion'] as num?)?.toDouble() ?? 0.0,
        rejectReasons: (json['reject_reasons'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
      );

  @override
  String toString() {
    final verdict =
        rejectReasons.isEmpty ? 'accepted' : 'rejected: ${rejectReasons.join(",")}';
    return '${topK.join(' / ')} '
        '[margin ${margin.toStringAsFixed(3)}/${minMargin.toStringAsFixed(2)}, '
        'conf min ${minConfidence.toStringAsFixed(2)}, '
        'motion ${mouthMotion.toStringAsFixed(5)}] '
        '${processingTimeMs.toStringAsFixed(0)}ms $framesUsed frames — $verdict';
  }
}
