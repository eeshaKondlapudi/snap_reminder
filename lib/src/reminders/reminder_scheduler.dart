import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../data/models/alarm_behavior.dart';
import '../data/models/important_meeting.dart';

class ReminderScheduler {
  ReminderScheduler({FlutterLocalNotificationsPlugin? notifications})
      : _notifications = notifications ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _notifications;
  var _initialized = false;
  var _exactAlarmsAllowed = true;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    tz.initializeTimeZones();
    await _configureLocalTimezone();

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _notifications.initialize(
      settings: const InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      ),
    );

    final androidNotifications =
        _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidNotifications?.createNotificationChannel(
      const AndroidNotificationChannel(
        'meeting_reminder_alarms_v3',
        'Meeting alarms',
        description: 'Audible alarm reminders for important meetings.',
        importance: Importance.max,
        playSound: true,
        sound: UriAndroidNotificationSound(
          'content://settings/system/alarm_alert',
        ),
        enableVibration: true,
        audioAttributesUsage: AudioAttributesUsage.alarm,
      ),
    );
    await androidNotifications?.createNotificationChannel(
      const AndroidNotificationChannel(
        'meeting_reminder_notifications_v2',
        'Meeting notifications',
        description: 'Standard reminders for important meetings.',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        audioAttributesUsage: AudioAttributesUsage.notification,
      ),
    );

    await androidNotifications?.requestNotificationsPermission();
    _exactAlarmsAllowed = await _notifications
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestExactAlarmsPermission() ??
        true;
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestFullScreenIntentPermission();

    _initialized = true;
  }

  Future<void> scheduleMeeting({
    required ImportantMeeting meeting,
    required AlarmBehavior alarmBehavior,
  }) async {
    await initialize();

    final meetingId = meeting.id;
    if (meetingId == null) {
      return;
    }

    final reminderTime = meeting.startsAt.subtract(
      Duration(minutes: meeting.reminderOffsetMinutes),
    );
    if (reminderTime.isBefore(DateTime.now())) {
      return;
    }

    final usesAlarm = alarmBehavior != AlarmBehavior.notificationOnly;
    final androidDetails = AndroidNotificationDetails(
      usesAlarm
          ? 'meeting_reminder_alarms_v3'
          : 'meeting_reminder_notifications_v2',
      usesAlarm ? 'Meeting alarms' : 'Meeting notifications',
      channelDescription: usesAlarm
          ? 'Audible alarm reminders for important meetings.'
          : 'Standard reminders for important meetings.',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.alarm,
      playSound: true,
      sound: usesAlarm
          ? const UriAndroidNotificationSound(
              'content://settings/system/alarm_alert',
            )
          : null,
      enableVibration: true,
      fullScreenIntent: usesAlarm,
      audioAttributesUsage: usesAlarm
          ? AudioAttributesUsage.alarm
          : AudioAttributesUsage.notification,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    await _notifications.zonedSchedule(
      id: meetingId,
      title: 'Meeting soon',
      body: '${meeting.title} starts in ${meeting.reminderOffsetMinutes} min',
      scheduledDate: tz.TZDateTime.from(reminderTime, tz.local),
      notificationDetails: NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      ),
      androidScheduleMode: _exactAlarmsAllowed
          ? AndroidScheduleMode.alarmClock
          : AndroidScheduleMode.inexactAllowWhileIdle,
      payload: meetingId.toString(),
    );
  }

  Future<void> cancelMeeting(int meetingId) async {
    await initialize();
    await _notifications.cancel(id: meetingId);
  }

  Future<void> _configureLocalTimezone() async {
    if (kIsWeb) {
      return;
    }

    try {
      final timezone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timezone.identifier));
    } on Object {
      tz.setLocalLocation(tz.getLocation('UTC'));
    }
  }
}
