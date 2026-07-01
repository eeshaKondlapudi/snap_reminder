import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/repositories/meeting_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../reminders/reminder_scheduler.dart';
import '../theme/app_theme.dart';
import '../ui/home_screen.dart';
import '../ui/outlook_screen.dart';
// import '../ui/scan_screen.dart';
import '../ui/settings_screen.dart';

class SnapReminderApp extends StatefulWidget {
  const SnapReminderApp({super.key});

  @override
  State<SnapReminderApp> createState() => _SnapReminderAppState();
}

class _SnapReminderAppState extends State<SnapReminderApp> {
  late final AppState appState;

  @override
  void initState() {
    super.initState();
    appState = AppState(
      meetingRepository: MeetingRepository(),
      settingsRepository: SettingsRepository(),
      reminderScheduler: ReminderScheduler(),
    );
    appState.load();
  }

  @override
  void dispose() {
    appState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SnapReminder',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: AppShell(appState: appState),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({required this.appState, super.key});

  final AppState appState;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  static const activeScreens = [
    AppScreen.home,
    AppScreen.outlook,
    // AppScreen.scan,
    AppScreen.settings,
  ];

  var selectedIndex = 0;
  int? _lastActiveAlarmMeetingId;

  @override
  void initState() {
    super.initState();
    _lastActiveAlarmMeetingId = widget.appState.activeAlarmMeeting?.id;
    WidgetsBinding.instance.addObserver(this);
    widget.appState.addListener(_showActiveAlarm);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.appState.removeListener(_showActiveAlarm);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.appState.refreshUpcomingMeetings();
    }
  }

  void _showActiveAlarm() {
    final activeAlarmMeetingId = widget.appState.activeAlarmMeeting?.id;
    if (activeAlarmMeetingId == null) {
      _lastActiveAlarmMeetingId = null;
      return;
    }
    if (activeAlarmMeetingId == _lastActiveAlarmMeetingId) {
      return;
    }

    _lastActiveAlarmMeetingId = activeAlarmMeetingId;
    if (selectedIndex == 0) {
      return;
    }
    setState(() {
      selectedIndex = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final screen = activeScreens[selectedIndex];

        return Scaffold(
          appBar: AppBar(
            title: const Text('SnapReminder'),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(32),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    screen.subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ),
            ),
          ),
          body: IndexedStack(
            index: selectedIndex,
            children: [
              HomeScreen(
                meetings: widget.appState.upcomingMeetings,
                activeAlarmMeeting: widget.appState.activeAlarmMeeting,
                onSaveMeeting: widget.appState.saveMeeting,
                onDeleteMeeting: widget.appState.deleteMeeting,
                onSnoozeAlarm: widget.appState.snoozeActiveAlarm,
                onDismissAlarm: widget.appState.dismissActiveAlarm,
              ),
              OutlookScreen(appState: widget.appState),
              // ScanScreen(appState: widget.appState),
              SettingsScreen(appState: widget.appState),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: selectedIndex,
            onDestinationSelected: (index) {
              setState(() {
                selectedIndex = index;
              });
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.event_available_outlined),
                selectedIcon: Icon(Icons.event_available),
                label: 'Outlook',
              ),
              // NavigationDestination(
              //   icon: Icon(Icons.add_a_photo_outlined),
              //   selectedIcon: Icon(Icons.add_a_photo),
              //   label: 'Scan',
              // ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
          ),
        );
      },
    );
  }
}

enum AppScreen {
  home('Saved meeting reminders will appear here.'),
  outlook('Sign in to read real Outlook calendar events.'),
  // scan('Pick an Outlook week screenshot to inspect.'),
  settings('Configure how reminders should behave.');

  const AppScreen(this.subtitle);

  final String subtitle;
}
