import '../data/models/important_meeting.dart';

class MeetingCandidate {
  MeetingCandidate({
    required this.title,
    required this.startsAt,
    required this.reminderOffsetMinutes,
    required this.sourceImagePath,
    required this.confidence,
    required this.reason,
    this.selected = false,
  });

  String title;
  DateTime startsAt;
  int reminderOffsetMinutes;
  String sourceImagePath;
  double confidence;
  String reason;
  bool selected;

  ImportantMeeting toMeeting() {
    return ImportantMeeting(
      title: title.trim().isEmpty ? 'Untitled meeting' : title.trim(),
      startsAt: startsAt,
      reminderOffsetMinutes: reminderOffsetMinutes,
      sourceImagePath: sourceImagePath,
    );
  }
}

class ScanResult {
  const ScanResult({
    required this.candidates,
    required this.recognizedText,
  });

  final List<MeetingCandidate> candidates;
  final String recognizedText;
}
