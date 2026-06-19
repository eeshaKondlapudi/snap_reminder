import '../data/models/important_meeting.dart';

class VoiceReminderParser {
  const VoiceReminderParser();

  static const defaultReminderOffsetMinutes = 5;

  ImportantMeeting parse(String input, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final phrase = input.trim();
    if (phrase.isEmpty) {
      throw const FormatException('Say a time and what the reminder is for.');
    }

    final timeMatch = _findTimeMatch(phrase);
    if (timeMatch == null) {
      throw const FormatException('I could not find a time in that reminder.');
    }

    final startsAt = _resolveStartsAt(phrase, timeMatch, reference);
    final title = _titleFromPhrase(phrase, timeMatch);

    return ImportantMeeting(
      title: title,
      startsAt: startsAt,
      reminderOffsetMinutes: defaultReminderOffsetMinutes,
    );
  }

  RegExpMatch? _findTimeMatch(String phrase) {
    const patterns = [
      r'\bat\s+(\d{1,2})(?:[:.](\d{2}))?\s*(a\.?m\.?|p\.?m\.?|a|p)?\b',
      r'\b(\d{1,2})(?:[:.](\d{2}))\s*(a\.?m\.?|p\.?m\.?|a|p)?\b',
      r'\b(\d{1,2})(?:[:.](\d{2}))?\s*(a\.?m\.?|p\.?m\.?|a|p)\b',
    ];

    for (final pattern in patterns) {
      final match = RegExp(pattern, caseSensitive: false).firstMatch(phrase);
      if (match != null) {
        return match;
      }
    }

    return null;
  }

  DateTime _resolveStartsAt(
    String phrase,
    RegExpMatch timeMatch,
    DateTime now,
  ) {
    final hour = int.parse(timeMatch.group(1)!);
    final minute = int.tryParse(timeMatch.group(2) ?? '0') ?? 0;
    final meridiem = _normalizedMeridiem(timeMatch.group(3));

    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      throw const FormatException('That time does not look valid.');
    }
    if (meridiem != null && hour > 12) {
      throw const FormatException('Use either AM/PM or 24-hour time.');
    }

    final day = _resolveDay(phrase, now);
    final possibleHours = _possibleHours(hour, meridiem);
    final candidates = possibleHours.map((possibleHour) {
      return DateTime(
        day.year,
        day.month,
        day.day,
        possibleHour,
        minute,
      );
    }).toList()
      ..sort();

    for (final candidate in candidates) {
      if (candidate.isAfter(now)) {
        return candidate;
      }
    }

    final nextDay = day.add(const Duration(days: 1));
    return DateTime(
      nextDay.year,
      nextDay.month,
      nextDay.day,
      candidates.first.hour,
      minute,
    );
  }

  DateTime _resolveDay(String phrase, DateTime now) {
    final lower = phrase.toLowerCase();
    final today = DateTime(now.year, now.month, now.day);

    if (lower.contains(RegExp(r'\btomorrow\b'))) {
      return today.add(const Duration(days: 1));
    }

    const weekdays = {
      'monday': DateTime.monday,
      'tuesday': DateTime.tuesday,
      'wednesday': DateTime.wednesday,
      'thursday': DateTime.thursday,
      'friday': DateTime.friday,
      'saturday': DateTime.saturday,
      'sunday': DateTime.sunday,
    };

    for (final entry in weekdays.entries) {
      if (!lower.contains(RegExp('\\b${entry.key}\\b'))) {
        continue;
      }
      var dayOffset = entry.value - now.weekday;
      if (dayOffset <= 0) {
        dayOffset += DateTime.daysPerWeek;
      }
      return today.add(Duration(days: dayOffset));
    }

    return today;
  }

  List<int> _possibleHours(int hour, String? meridiem) {
    if (meridiem == 'am') {
      return [hour == 12 ? 0 : hour];
    }
    if (meridiem == 'pm') {
      return [hour == 12 ? 12 : hour + 12];
    }
    if (hour > 12) {
      return [hour];
    }
    if (hour == 12) {
      return [12];
    }
    return [hour, hour + 12];
  }

  String? _normalizedMeridiem(String? value) {
    if (value == null) {
      return null;
    }
    final cleaned = value.toLowerCase().replaceAll('.', '');
    if (cleaned.startsWith('a')) {
      return 'am';
    }
    if (cleaned.startsWith('p')) {
      return 'pm';
    }
    return null;
  }

  String _titleFromPhrase(String phrase, RegExpMatch timeMatch) {
    var title = phrase.replaceRange(timeMatch.start, timeMatch.end, ' ');

    title = title
        .replaceAll(RegExp(r'\b(today|tomorrow)\b', caseSensitive: false), ' ')
        .replaceAll(
          RegExp(
            r'\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[,.;:]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    title = title.replaceFirst(
      RegExp(
        r'^(please\s+)?((can you\s+)?remind me (to|that)\s+|'
        r'set (an?\s+)?(alarm|reminder)(to|for)?\s+|'
        r'i (need|have|got) to\s+|'
        r'i need\s+|'
        r'need to\s+)',
        caseSensitive: false,
      ),
      '',
    );

    title = title.trim();
    if (title.isEmpty) {
      return 'Voice reminder';
    }

    return title[0].toUpperCase() + title.substring(1);
  }
}
