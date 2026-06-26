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

  Future<void> load() async {
    isLoading = true;
    notifyListeners();

    await reminderScheduler.initialize();
    settings = await settingsRepository.load();
    upcomingMeetings = await meetingRepository.loadUpcoming();
    await _rescheduleUpcomingMeetings();

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

  Future<void> deleteMeeting(ImportantMeeting meeting) async {
    final id = meeting.id;
    if (id == null) {
      return;
    }

    await reminderScheduler.cancelMeeting(id);
    await meetingRepository.delete(id);
    upcomingMeetings = await meetingRepository.loadUpcoming();
    notifyListeners();
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
