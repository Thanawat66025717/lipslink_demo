import 'package:flutter_tts/flutter_tts.dart';

/// Singleton TTS service with emotion-based voice modulation
/// and word-by-word real-time speaking support
class TtsService {
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  TtsService._internal();

  final FlutterTts _tts = FlutterTts();
  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;
    await _tts.setLanguage('th-TH');
    await _tts.setSpeechRate(0.52);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    _isInitialized = true;
  }

  /// Speak a full sentence — stops any current speech first
  Future<void> speak(String text, {String emotion = 'neutral'}) async {
    await init();
    await _tts.stop();
    _applyEmotionParams(emotion);
    await _tts.speak(text);
  }

  /// Speak a single word immediately (real-time word-by-word mode)
  /// Uses a faster speech rate and does NOT stop ongoing speech —
  /// words queue naturally via TTS engine
  Future<void> speakWord(String word, {String emotion = 'neutral'}) async {
    await init();
    // Slightly faster for real-time feel
    switch (emotion) {
      case 'happy':
        await _tts.setPitch(1.25);
        await _tts.setSpeechRate(0.58);
        break;
      case 'sad':
        await _tts.setPitch(0.82);
        await _tts.setSpeechRate(0.42);
        break;
      case 'angry':
        await _tts.setPitch(0.88);
        await _tts.setSpeechRate(0.60);
        break;
      default:
        await _tts.setPitch(1.0);
        await _tts.setSpeechRate(0.54);
    }
    await _tts.speak(word);
  }

  void _applyEmotionParams(String emotion) {
    switch (emotion) {
      case 'happy':
        _tts.setPitch(1.3);
        _tts.setSpeechRate(0.55);
        break;
      case 'sad':
        _tts.setPitch(0.8);
        _tts.setSpeechRate(0.40);
        break;
      case 'angry':
        _tts.setPitch(0.9);
        _tts.setSpeechRate(0.60);
        break;
      case 'surprised':
        _tts.setPitch(1.4);
        _tts.setSpeechRate(0.60);
        break;
      default:
        _tts.setPitch(1.0);
        _tts.setSpeechRate(0.52);
    }
  }

  Future<void> stop() async {
    await _tts.stop();
  }

  void setOnCompletionHandler(void Function() callback) {
    _tts.setCompletionHandler(callback);
  }
}
