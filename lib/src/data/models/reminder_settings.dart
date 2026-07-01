import 'alarm_behavior.dart';

class ReminderSettings {
  const ReminderSettings({
    this.defaultReminderOffsetMinutes = 5,
    this.alarmBehavior = AlarmBehavior.alarmAndNotification,
    this.microsoftClientId = '',
    this.lastOutlookSharedCalendarLink = '',
  });

  final int defaultReminderOffsetMinutes;
  final AlarmBehavior alarmBehavior;
  final String microsoftClientId;
  final String lastOutlookSharedCalendarLink;

  ReminderSettings copyWith({
    int? defaultReminderOffsetMinutes,
    AlarmBehavior? alarmBehavior,
    String? microsoftClientId,
    String? lastOutlookSharedCalendarLink,
  }) {
    return ReminderSettings(
      defaultReminderOffsetMinutes:
          defaultReminderOffsetMinutes ?? this.defaultReminderOffsetMinutes,
      alarmBehavior: alarmBehavior ?? this.alarmBehavior,
      microsoftClientId: microsoftClientId ?? this.microsoftClientId,
      lastOutlookSharedCalendarLink:
          lastOutlookSharedCalendarLink ?? this.lastOutlookSharedCalendarLink,
    );
  }
}
