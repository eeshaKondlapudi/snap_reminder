import 'alarm_behavior.dart';

class ReminderSettings {
  const ReminderSettings({
    this.defaultReminderOffsetMinutes = 5,
    this.alarmBehavior = AlarmBehavior.alarmAndNotification,
    this.microsoftClientId = '',
  });

  final int defaultReminderOffsetMinutes;
  final AlarmBehavior alarmBehavior;
  final String microsoftClientId;

  ReminderSettings copyWith({
    int? defaultReminderOffsetMinutes,
    AlarmBehavior? alarmBehavior,
    String? microsoftClientId,
  }) {
    return ReminderSettings(
      defaultReminderOffsetMinutes:
          defaultReminderOffsetMinutes ?? this.defaultReminderOffsetMinutes,
      alarmBehavior: alarmBehavior ?? this.alarmBehavior,
      microsoftClientId: microsoftClientId ?? this.microsoftClientId,
    );
  }
}
