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

  /// ส่งภาพปากไปให้โมเดล VocaLip ทำนายว่าเป็นคำใดใน 44 คำ
  ///
  /// [frames] ภาพปากสี PNG ขนาด 112x112 เรียงตามเวลา ส่งมากี่เฟรมก็ได้ —
  /// server จะเลือก/เติมให้เหลือ 16 เฟรมตามที่โมเดลรับเอง
  ///
  /// โมเดลนี้คืน "คำเดียว" ต่อหนึ่งคลิป ไม่ใช่ข้อความอิสระ และบังคับเลือก 1 ใน
  /// 44 คำเสมอแม้ผู้ใช้พูดคำนอกชุด จึงควรดู [WordPrediction.lowConfidence] ด้วย
  static Future<WordPrediction?> predictWord(
    List<Uint8List> frames, {
    int topK = 3,
    int? captureMs,
    int? collectedFrames,
    bool? isFinal,
  }) async {
    if (frames.isEmpty) return null;

    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/predict_word'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'frames': frames.map(base64Encode).toList(),
              'top_k': topK,
              if (captureMs != null) 'capture_ms': captureMs,
              // จำนวนเฟรมที่เก็บได้จริง ต่างจาก frames.length ที่ถูกลดเหลือ
              // เท่าที่โมเดลรับแล้ว — ต้องใช้ตัวนี้คำนวณอัตราเฟรมต่อวินาที
              if (collectedFrames != null) 'collected_frames': collectedFrames,
              if (isFinal != null) 'is_final': isFinal,
            }),
          )
          .timeout(_timeout);

      if (response.statusCode != 200) {
        debugPrint('❌ predict_word ${response.statusCode}: ${response.body}');
        return null;
      }

      // ต้อง decode เป็น UTF-8 เอง — FastAPI ไม่ได้ใส่ charset มาใน
      // Content-Type และ package:http จะ fallback ไปเป็น latin1 ทำให้คำไทย
      // กลายเป็นตัวอักษรขยะโดยไม่มี error ฟ้อง
      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return WordPrediction.fromJson(data);
    } catch (e) {
      debugPrint('❌ predict_word failed: $e');
      return null;
    }
  }

  /// ถามค่า preprocessing ที่โมเดลบน server ต้องการจริงๆ
  ///
  /// ค่าพวกนี้ต้องตรงกับตอนเทรนเป๊ะ และเปลี่ยนได้ทุกครั้งที่เปลี่ยนไฟล์โมเดล
  /// ถ้าฝั่งแอปฝังค่าไว้ตายตัว วันที่โมเดลรุ่นใหม่ใช้ค่าอื่น แอปจะส่งของผิด
  /// ขนาดไปให้ server ย่อให้เงียบๆ แล้วทำนายมั่วโดยไม่มี error ฟ้อง
  ///
  /// คืน null เมื่อถามไม่ได้ ให้ผู้เรียกใช้ค่าสำรองของตัวเองต่อไป
  static Future<WordModelConfig?> fetchWordModelConfig() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/word_model_info'))
          .timeout(_timeout);
      if (response.statusCode != 200) return null;

      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return WordModelConfig.fromJson(data);
    } catch (e) {
      debugPrint('word_model_info failed: $e');
      return null;
    }
  }

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

/// ค่า preprocessing ที่โมเดลบน server ต้องการ อ่านจากไฟล์ checkpoint โดยตรง
class WordModelConfig {
  /// จำนวนเฟรมต่อหนึ่งคลิป
  final int frames;

  /// ความกว้าง/สูงของภาพปากที่โมเดลรับ (จัตุรัส)
  final int roi;

  /// อัตราขยายกรอบครอบปาก — ปกติ checkpoint ยังไม่ได้บอกค่านี้มา
  /// จะมีค่าก็ต่อเมื่อผู้เทรนใส่ `mouth_scale` ลงใน preprocessing ให้
  final double? mouthScale;

  const WordModelConfig({
    required this.frames,
    required this.roi,
    this.mouthScale,
  });

  /// คืน null ถ้าค่าที่ได้มาอยู่นอกช่วงที่สมเหตุสมผล ดีกว่ารับค่าพังมาใช้
  /// แล้วทำให้แอปส่งภาพขนาดประหลาดไปทั้ง session
  static WordModelConfig? fromJson(Map<String, dynamic> json) {
    final frames = (json['frames'] as num?)?.toInt();
    final roi = (json['roi'] as num?)?.toInt();
    if (frames == null || roi == null) return null;
    if (frames < 2 || frames > 64) return null;
    if (roi < 32 || roi > 512) return null;

    final pre = json['preprocessing'];
    final scale = pre is Map<String, dynamic>
        ? (pre['mouth_scale'] as num?)?.toDouble()
        : null;

    return WordModelConfig(
      frames: frames,
      roi: roi,
      mouthScale: (scale != null && scale >= 1.0 && scale <= 6.0) ? scale : null,
    );
  }

  @override
  String toString() => 'frames=$frames roi=$roi'
      '${mouthScale != null ? ' mouthScale=$mouthScale' : ''}';
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
