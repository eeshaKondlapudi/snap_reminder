import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'meeting_candidate.dart';

class OcrMeetingParserClient {
  OcrMeetingParserClient({
    this.endpoint = const String.fromEnvironment(
      'OCR_PARSE_ENDPOINT',
      defaultValue: 'http://10.0.2.2:8788/parse-ocr',
    ),
    this.timeout = const Duration(seconds: 90),
  });

  final String endpoint;
  final Duration timeout;

  Future<List<MeetingCandidate>> parse({
    required List<OcrLinePayload> lines,
    required List<CalendarEventPayload> events,
    required String rawText,
    required String imagePath,
    required int reminderOffsetMinutes,
  }) async {
    final client = HttpClient();

    try {
      final request =
          await client.postUrl(Uri.parse(endpoint)).timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'rawText': rawText,
          'lines': lines.map((line) => line.toJson()).toList(),
          'events': events.map((event) => event.toJson()).toList(),
          'currentDate': DateTime.now().toIso8601String().split('T').first,
        }),
      );

      final response = await request.close().timeout(timeout);
      final body =
          await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw OcrMeetingParserException(
          'OCR parser failed (${response.statusCode}): $body',
        );
      }

      final data = jsonDecode(body) as Map<String, dynamic>;
      final meetings = (data['meetings'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();

      return meetings.map((meeting) {
        return _candidateFromJson(
          meeting,
          imagePath,
          reminderOffsetMinutes,
        );
      }).toList();
    } finally {
      client.close(force: true);
    }
  }

  MeetingCandidate _candidateFromJson(
    Map<String, dynamic> json,
    String imagePath,
    int reminderOffsetMinutes,
  ) {
    final title = (json['title'] as String?)?.trim();
    final date = (json['date'] as String?)?.trim();
    final startTime = (json['start_time'] as String?)?.trim();
    final startsAt = _parseStartsAt(date, startTime);
    final confidence = (json['confidence'] as num?)?.toDouble() ?? 0.7;
    final reason = (json['reason'] as String?)?.trim();

    return MeetingCandidate(
      title: title == null || title.isEmpty ? 'Untitled meeting' : title,
      startsAt: startsAt,
      reminderOffsetMinutes: reminderOffsetMinutes,
      sourceImagePath: imagePath,
      confidence: confidence.clamp(0.1, 0.98).toDouble(),
      reason: reason == null || reason.isEmpty
          ? 'Filtered from OCR text by Llama.'
          : 'Llama parser: $reason',
      selected: false,
    );
  }

  DateTime _parseStartsAt(String? date, String? time) {
    final fallback = DateTime.now().add(const Duration(hours: 1));
    if (date == null || time == null) {
      return fallback;
    }

    final dateParts = date.split('-').map(int.tryParse).toList();
    final timeParts = time.split(':').map(int.tryParse).toList();
    if (dateParts.length < 3 ||
        timeParts.length < 2 ||
        dateParts.any((part) => part == null) ||
        timeParts.any((part) => part == null)) {
      return fallback;
    }

    return DateTime(
      dateParts[0]!,
      dateParts[1]!,
      dateParts[2]!,
      timeParts[0]!,
      timeParts[1]!,
    );
  }
}

class OcrLinePayload {
  const OcrLinePayload({
    required this.text,
    required this.rect,
  });

  final String text;
  final Rect rect;

  Map<String, Object> toJson() {
    return {
      'text': text,
      'left': rect.left.round(),
      'top': rect.top.round(),
      'right': rect.right.round(),
      'bottom': rect.bottom.round(),
      'centerX': rect.center.dx.round(),
      'centerY': rect.center.dy.round(),
    };
  }
}

class CalendarEventPayload {
  const CalendarEventPayload({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.lines,
    required this.inferredDate,
    required this.inferredStartTime,
  });

  final int left;
  final int top;
  final int right;
  final int bottom;
  final List<String> lines;
  final String inferredDate;
  final String inferredStartTime;

  Map<String, Object> toJson() {
    return {
      'left': left,
      'top': top,
      'right': right,
      'bottom': bottom,
      'centerX': ((left + right) / 2).round(),
      'centerY': ((top + bottom) / 2).round(),
      'lines': lines,
      'text': lines.join('\n'),
      'inferredDate': inferredDate,
      'inferredStartTime': inferredStartTime,
    };
  }
}

class OcrMeetingParserException implements Exception {
  const OcrMeetingParserException(this.message);

  final String message;

  @override
  String toString() => message;
}
