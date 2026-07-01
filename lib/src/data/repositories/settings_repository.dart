import 'package:shared_preferences/shared_preferences.dart';

import '../models/alarm_behavior.dart';
import '../models/reminder_settings.dart';

class SettingsRepository {
  static const _defaultOffsetKey = 'default_offset_minutes';
  static const _alarmBehaviorKey = 'alarm_behavior';
  static const _microsoftClientIdKey = 'microsoft_client_id';
  static const _lastOutlookSharedCalendarLinkKey =
      'last_outlook_shared_calendar_link';

  Future<ReminderSettings> load() async {
    final preferences = await SharedPreferences.getInstance();
    return ReminderSettings(
      defaultReminderOffsetMinutes: preferences.getInt(_defaultOffsetKey) ?? 5,
      alarmBehavior: AlarmBehavior.fromName(
        preferences.getString(_alarmBehaviorKey),
      ),
      microsoftClientId: preferences.getString(_microsoftClientIdKey) ?? '',
      lastOutlookSharedCalendarLink:
          preferences.getString(_lastOutlookSharedCalendarLinkKey) ?? '',
    );
  }

  Future<ReminderSettings> save(ReminderSettings settings) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(
      _defaultOffsetKey,
      settings.defaultReminderOffsetMinutes,
    );
    await preferences.setString(_alarmBehaviorKey, settings.alarmBehavior.name);
    await preferences.setString(
      _microsoftClientIdKey,
      settings.microsoftClientId.trim(),
    );
    await preferences.setString(
      _lastOutlookSharedCalendarLinkKey,
      settings.lastOutlookSharedCalendarLink.trim(),
    );
    return settings;
  }
}
