import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models/alarm_behavior.dart';
import 'models/important_meeting.dart';
import 'models/reminder_settings.dart';
import 'repositories/meeting_repository.dart';
import 'repositories/settings_repository.dart';
import '../reminders/reminder_scheduler.dart';

class AppState extends ChangeNotifier {
  AppState({
    required this.meetingRepository,
    required this.settingsRepository,
    required this.reminderScheduler,
  });

  final MeetingRepository meetingRepository;
  final SettingsRepository settingsRepository;
  final ReminderScheduler reminderScheduler;

  var upcomingMeetings = <ImportantMeeting>[];
  var settings = const ReminderSettings();
  var isLoading = true;
  ImportantMeeting? activeAlarmMeeting;
  StreamSubscription<ReminderNotificationResponse>? _notificationSubscription;

  Future<void> load() async {
    isLoading = true;
    notifyListeners();

    await reminderScheduler.initialize();
    _notificationSubscription ??=
        reminderScheduler.notificationResponses.listen(
      handleNotificationResponse,
    );
    settings = await settingsRepository.load();
    upcomingMeetings = await meetingRepository.loadUpcoming();
    await _rescheduleUpcomingMeetings();
    final launchResponse = await reminderScheduler.takeLaunchResponse();
    if (launchResponse != null) {
      await handleNotificationResponse(launchResponse);
    }

    isLoading = false;
    notifyListeners();
  }

  Future<void> setDefaultReminderOffset(int minutes) async {
    settings = await settingsRepository.save(
      settings.copyWith(defaultReminderOffsetMinutes: minutes),
    );
    notifyListeners();
  }

  Future<void> setAlarmBehavior(AlarmBehavior behavior) async {
    settings = await settingsRepository.save(
      settings.copyWith(alarmBehavior: behavior),
    );
    await _rescheduleUpcomingMeetings();
    notifyListeners();
  }

  Future<void> setMicrosoftClientId(String clientId) async {
    settings = await settingsRepository.save(
      settings.copyWith(microsoftClientId: clientId.trim()),
    );
    notifyListeners();
  }

  Future<void> setLastOutlookSharedCalendarLink(String link) async {
    settings = await settingsRepository.save(
      settings.copyWith(lastOutlookSharedCalendarLink: link.trim()),
    );
    notifyListeners();
  }

  Future<ImportantMeeting> saveMeeting(ImportantMeeting meeting) async {
    final id = await meetingRepository.save(meeting);
    final savedMeeting = meeting.copyWith(id: id);
    await reminderScheduler.scheduleMeeting(
      meeting: savedMeeting,
      alarmBehavior: settings.alarmBehavior,
    );
    upcomingMeetings = await meetingRepository.loadUpcoming();
    notifyListeners();
    return savedMeeting;
  }

  Future<void> saveMeetings(List<ImportantMeeting> meetings) async {
    for (final meeting in meetings) {
      await saveMeeting(meeting);
    }
  }

  Future<void> refreshUpcomingMeetings() async {
    upcomingMeetings = await meetingRepository.loadUpcoming();
    notifyListeners();
  }

  Future<void> deleteMeeting(ImportantMeeting meeting) async {
    final id = meeting.id;
    if (id == null) {
      return;
    }

    await reminderScheduler.cancelMeeting(id);
    await meetingRepository.delete(id);
    upcomingMeetings = await meetingRepository.loadUpcoming();
    if (activeAlarmMeeting?.id == id) {
      activeAlarmMeeting = null;
    }
    notifyListeners();
  }

  Future<void> snoozeActiveAlarm() async {
    final meeting = activeAlarmMeeting;
    final meetingId = meeting?.id;
    if (meeting == null || meetingId == null) {
      return;
    }

    await reminderScheduler.cancelMeeting(meetingId);
    await reminderScheduler.scheduleSnooze(
      meeting: meeting,
      alarmBehavior: settings.alarmBehavior,
    );
    activeAlarmMeeting = null;
    notifyListeners();
  }

  Future<void> dismissActiveAlarm() async {
    final meetingId = activeAlarmMeeting?.id;
    if (meetingId == null) {
      return;
    }

    await reminderScheduler.cancelMeeting(meetingId);
    activeAlarmMeeting = null;
    notifyListeners();
  }

  Future<void> handleNotificationResponse(
    ReminderNotificationResponse response,
  ) async {
    final meeting = await meetingRepository.findById(response.meetingId);
    if (meeting == null) {
      return;
    }

    switch (response.action) {
      case ReminderNotificationAction.open:
        activeAlarmMeeting = meeting;
        break;
      case ReminderNotificationAction.snooze:
        await reminderScheduler.cancelMeeting(response.meetingId);
        await reminderScheduler.scheduleSnooze(
          meeting: meeting,
          alarmBehavior: settings.alarmBehavior,
        );
        activeAlarmMeeting = null;
        break;
      case ReminderNotificationAction.dismiss:
        await reminderScheduler.cancelMeeting(response.meetingId);
        activeAlarmMeeting = null;
        break;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_notificationSubscription?.cancel());
    super.dispose();
  }

  Future<void> _rescheduleUpcomingMeetings() async {
    for (final meeting in upcomingMeetings) {
      await reminderScheduler.scheduleMeeting(
        meeting: meeting,
        alarmBehavior: settings.alarmBehavior,
      );
    }
  }
}
