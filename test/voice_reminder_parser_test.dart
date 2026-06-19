import 'package:flutter_test/flutter_test.dart';
import 'package:snap_reminder/src/voice/voice_reminder_parser.dart';

void main() {
  const parser = VoiceReminderParser();

  test('parses a dictated reminder with a five minute alarm offset', () {
    final meeting = parser.parse(
      'at 6:30, I need to go get groceries',
      now: DateTime(2026, 6, 18, 15),
    );

    expect(meeting.title, 'Go get groceries');
    expect(meeting.startsAt, DateTime(2026, 6, 18, 18, 30));
    expect(meeting.reminderOffsetMinutes, 5);
  });

  test('rolls an ambiguous passed time to the next day', () {
    final meeting = parser.parse(
      'at 6:30 go get groceries',
      now: DateTime(2026, 6, 18, 22),
    );

    expect(meeting.startsAt, DateTime(2026, 6, 19, 6, 30));
  });

  test('respects explicit PM', () {
    final meeting = parser.parse(
      'remind me to call mom at 6 pm',
      now: DateTime(2026, 6, 18, 8),
    );

    expect(meeting.title, 'Call mom');
    expect(meeting.startsAt, DateTime(2026, 6, 18, 18));
  });
}
