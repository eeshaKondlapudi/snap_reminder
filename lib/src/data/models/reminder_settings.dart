import 'alarm_behavior.dart';

class ReminderSettings {
  const ReminderSettings({
    this.defaultReminderOffsetMinutes = 5,
    this.alarmBehavior = AlarmBehavior.alarmAndNotification,
  });

  final int defaultReminderOffsetMinutes;
  final AlarmBehavior alarmBehavior;

  ReminderSettings copyWith({
    int? defaultReminderOffsetMinutes,
    AlarmBehavior? alarmBehavior,
  }) {
    return ReminderSettings(
      defaultReminderOffsetMinutes:
          defaultReminderOffsetMinutes ?? this.defaultReminderOffsetMinutes,
      alarmBehavior: alarmBehavior ?? this.alarmBehavior,
    );
  }
}
