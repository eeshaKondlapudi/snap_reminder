enum AlarmBehavior {
  alarmAndNotification,
  alarmOnly,
  notificationOnly;

  String get label {
    switch (this) {
      case AlarmBehavior.alarmAndNotification:
        return 'Alarm + notification';
      case AlarmBehavior.alarmOnly:
        return 'Alarm only';
      case AlarmBehavior.notificationOnly:
        return 'Notification only';
    }
  }

  static AlarmBehavior fromName(String? name) {
    return AlarmBehavior.values.firstWhere(
      (value) => value.name == name,
      orElse: () => AlarmBehavior.alarmAndNotification,
    );
  }
}
