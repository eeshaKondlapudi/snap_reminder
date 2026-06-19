import 'package:flutter/services.dart';

class DictationService {
  const DictationService();

  static const _channel = MethodChannel('snap_reminder/dictation');

  Future<String> listen(
      {void Function(String transcript)? onTranscript}) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'transcriptChanged') {
        return;
      }

      final transcript = call.arguments as String?;
      if (transcript == null || transcript.trim().isEmpty) {
        return;
      }

      onTranscript?.call(transcript.trim());
    });

    try {
      final transcript = await _channel.invokeMethod<String>('listen');
      return transcript?.trim() ?? '';
    } on PlatformException catch (error) {
      throw DictationException(error.message ?? 'Dictation is unavailable.');
    } on MissingPluginException {
      throw const DictationException(
          'Dictation is unavailable on this device.');
    } finally {
      _channel.setMethodCallHandler(null);
    }
  }
}

class DictationException implements Exception {
  const DictationException(this.message);

  final String message;

  @override
  String toString() => message;
}
