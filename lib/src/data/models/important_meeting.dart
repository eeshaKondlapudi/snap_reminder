class ImportantMeeting {
  ImportantMeeting({
    this.id,
    required this.title,
    required this.startsAt,
    required this.reminderOffsetMinutes,
    this.sourceImagePath,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final int? id;
  final String title;
  final DateTime startsAt;
  final int reminderOffsetMinutes;
  final String? sourceImagePath;
  final DateTime createdAt;

  ImportantMeeting copyWith({
    int? id,
    String? title,
    DateTime? startsAt,
    int? reminderOffsetMinutes,
    String? sourceImagePath,
    DateTime? createdAt,
  }) {
    return ImportantMeeting(
      id: id ?? this.id,
      title: title ?? this.title,
      startsAt: startsAt ?? this.startsAt,
      reminderOffsetMinutes:
          reminderOffsetMinutes ?? this.reminderOffsetMinutes,
      sourceImagePath: sourceImagePath ?? this.sourceImagePath,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'title': title,
      'starts_at_millis': startsAt.millisecondsSinceEpoch,
      'reminder_offset_minutes': reminderOffsetMinutes,
      'source_image_path': sourceImagePath,
      'created_at_millis': createdAt.millisecondsSinceEpoch,
    };
  }

  factory ImportantMeeting.fromMap(Map<String, Object?> map) {
    return ImportantMeeting(
      id: map['id'] as int?,
      title: map['title'] as String,
      startsAt: DateTime.fromMillisecondsSinceEpoch(
        map['starts_at_millis'] as int,
      ),
      reminderOffsetMinutes: map['reminder_offset_minutes'] as int,
      sourceImagePath: map['source_image_path'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        map['created_at_millis'] as int,
      ),
    );
  }
}
