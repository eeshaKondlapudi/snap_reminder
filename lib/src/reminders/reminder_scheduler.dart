import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../data/models/alarm_behavior.dart';
import '../data/models/important_meeting.dart';
import '../data/repositories/meeting_repository.dart';
import '../data/repositories/settings_repository.dart';

const snoozeReminderActionId = 'snooze_meeting_alarm';
const dismissReminderActionId = 'dismiss_meeting_alarm';

class ReminderScheduler {
  ReminderScheduler({FlutterLocalNotificationsPlugin? notifications})
      : _notifications = notifications ?? FlutterLocalNotificationsPlugin();

  static const snoozeDuration = Duration(minutes: 5);
  static const _darwinAlarmCategoryId = 'meeting_alarm_actions';

  final FlutterLocalNotificationsPlugin _notifications;
  final _responses = StreamController<ReminderNotificationResponse>.broadcast();
  var _initialized = false;
  var _exactAlarmsAllowed = true;

  Stream<ReminderNotificationResponse> get notificationResponses =>
      _responses.stream;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    tz.initializeTimeZones();
    await _configureLocalTimezone();

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    final iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      notificationCategories: [
        DarwinNotificationCategory(
          _darwinAlarmCategoryId,
          actions: [
            DarwinNotificationAction.plain(
              snoozeReminderActionId,
              'Snooze 5 min',
            ),
            DarwinNotificationAction.plain(
              dismissReminderActionId,
              'Dismiss',
              options: {DarwinNotificationActionOption.destructive},
            ),
          ],
        ),
      ],
    );

    await _notifications.initialize(
      settings: InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      ),
      onDidReceiveNotificationResponse: _handleNotificationResponse,
      onDidReceiveBackgroundNotificationResponse:
          handleReminderNotificationBackground,
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
    _initialized = true;
  }

  Future<ReminderNotificationResponse?> takeLaunchResponse() async {
    await initialize();
    final details = await _notifications.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) {
      return null;
    }
    final response = details?.notificationResponse;
    if (response == null) {
      return null;
    }
    return ReminderNotificationResponse.fromNotificationResponse(response);
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
    final androidDetails = _androidDetails(
      usesAlarm
          ? 'meeting_reminder_alarms_v3'
          : 'meeting_reminder_notifications_v2',
      usesAlarm ? 'Meeting alarms' : 'Meeting notifications',
      usesAlarm: usesAlarm,
      meeting: meeting,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      presentBanner: true,
      presentList: true,
      categoryIdentifier: _darwinAlarmCategoryId,
    );

    await _notifications.zonedSchedule(
      id: meetingId,
      title: meeting.title,
      body: 'Starts in ${meeting.reminderOffsetMinutes} min',
      scheduledDate: tz.TZDateTime.from(reminderTime, tz.local),
      notificationDetails: NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      ),
      androidScheduleMode: _exactAlarmsAllowed
          ? AndroidScheduleMode.alarmClock
          : AndroidScheduleMode.inexactAllowWhileIdle,
      payload: _payloadForMeeting(meetingId),
    );
  }

  Future<void> scheduleSnooze({
    required ImportantMeeting meeting,
    required AlarmBehavior alarmBehavior,
    Duration delay = snoozeDuration,
  }) async {
    await initialize();

    final meetingId = meeting.id;
    if (meetingId == null) {
      return;
    }

    final usesAlarm = alarmBehavior != AlarmBehavior.notificationOnly;
    final scheduledDate = DateTime.now().add(delay);
    final androidDetails = _androidDetails(
      usesAlarm
          ? 'meeting_reminder_alarms_v3'
          : 'meeting_reminder_notifications_v2',
      usesAlarm ? 'Meeting alarms' : 'Meeting notifications',
      usesAlarm: usesAlarm,
      meeting: meeting,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      presentBanner: true,
      presentList: true,
      categoryIdentifier: _darwinAlarmCategoryId,
    );

    await _notifications.zonedSchedule(
      id: meetingId,
      title: meeting.title,
      body: 'Snoozed for ${delay.inMinutes} min',
      scheduledDate: tz.TZDateTime.from(scheduledDate, tz.local),
      notificationDetails: NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      ),
      androidScheduleMode: _exactAlarmsAllowed
          ? AndroidScheduleMode.alarmClock
          : AndroidScheduleMode.inexactAllowWhileIdle,
      payload: _payloadForMeeting(meetingId),
    );
  }

  Future<void> cancelMeeting(int meetingId) async {
    await initialize();
    await _notifications.cancel(id: meetingId);
  }

  AndroidNotificationDetails _androidDetails(
    String channelId,
    String channelName, {
    required bool usesAlarm,
    required ImportantMeeting meeting,
  }) {
    return AndroidNotificationDetails(
      channelId,
      channelName,
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
      fullScreenIntent: false,
      visibility: NotificationVisibility.public,
      styleInformation: BigTextStyleInformation(
        '${meeting.title}\nUse Snooze or Dismiss to manage this alarm.',
        contentTitle: meeting.title,
        summaryText: 'Meeting alarm',
      ),
      actions: const [
        AndroidNotificationAction(
          snoozeReminderActionId,
          'Snooze 5 min',
          cancelNotification: true,
          semanticAction: SemanticAction.markAsRead,
        ),
        AndroidNotificationAction(
          dismissReminderActionId,
          'Dismiss',
          cancelNotification: true,
          semanticAction: SemanticAction.delete,
        ),
      ],
      audioAttributesUsage: usesAlarm
          ? AudioAttributesUsage.alarm
          : AudioAttributesUsage.notification,
    );
  }

  void _handleNotificationResponse(NotificationResponse response) {
    final reminderResponse =
        ReminderNotificationResponse.fromNotificationResponse(response);
    if (reminderResponse == null) {
      return;
    }
    _responses.add(reminderResponse);
  }

  String _payloadForMeeting(int meetingId) => 'meeting:$meetingId';

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

class ReminderNotificationResponse {
  const ReminderNotificationResponse({
    required this.meetingId,
    required this.action,
  });

  final int meetingId;
  final ReminderNotificationAction action;

  static ReminderNotificationResponse? fromNotificationResponse(
    NotificationResponse response,
  ) {
    final meetingId = _meetingIdFromPayload(response.payload) ?? response.id;
    if (meetingId == null) {
      return null;
    }
    return ReminderNotificationResponse(
      meetingId: meetingId,
      action: ReminderNotificationAction.fromActionId(response.actionId),
    );
  }

  static int? _meetingIdFromPayload(String? payload) {
    if (payload == null || payload.trim().isEmpty) {
      return null;
    }
    final trimmedPayload = payload.trim();
    final legacyId = int.tryParse(trimmedPayload);
    if (legacyId != null) {
      return legacyId;
    }
    if (!trimmedPayload.startsWith('meeting:')) {
      return null;
    }
    return int.tryParse(trimmedPayload.substring('meeting:'.length));
  }
}

enum ReminderNotificationAction {
  open,
  snooze,
  dismiss;

  static ReminderNotificationAction fromActionId(String? actionId) {
    return switch (actionId) {
      snoozeReminderActionId => ReminderNotificationAction.snooze,
      dismissReminderActionId => ReminderNotificationAction.dismiss,
      _ => ReminderNotificationAction.open,
    };
  }
}

@pragma('vm:entry-point')
void handleReminderNotificationBackground(NotificationResponse response) {
  DartPluginRegistrant.ensureInitialized();
  final reminderResponse =
      ReminderNotificationResponse.fromNotificationResponse(response);
  if (reminderResponse == null) {
    return;
  }
  unawaited(_handleReminderNotificationAction(reminderResponse));
}

Future<void> _handleReminderNotificationAction(
  ReminderNotificationResponse response,
) async {
  final meetingRepository = MeetingRepository();
  final meeting = await meetingRepository.findById(response.meetingId);
  if (meeting == null) {
    return;
  }

  final settings = await SettingsRepository().load();
  final scheduler = ReminderScheduler();
  switch (response.action) {
    case ReminderNotificationAction.snooze:
      await scheduler.cancelMeeting(response.meetingId);
      await scheduler.scheduleSnooze(
        meeting: meeting,
        alarmBehavior: settings.alarmBehavior,
      );
      break;
    case ReminderNotificationAction.dismiss:
    case ReminderNotificationAction.open:
      await scheduler.cancelMeeting(response.meetingId);
      break;
  }
}
