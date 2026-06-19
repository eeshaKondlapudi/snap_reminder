import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/models/alarm_behavior.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({required this.appState, super.key});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final settings = appState.settings;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SettingsSection(
          title: 'Default reminder',
          child: Wrap(
            spacing: 8,
            children: [5, 10, 15, 30].map((minutes) {
              return ChoiceChip(
                label: Text('${minutes}m'),
                selected: settings.defaultReminderOffsetMinutes == minutes,
                onSelected: (_) {
                  appState.setDefaultReminderOffset(minutes);
                },
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 24),
        _SettingsSection(
          title: 'Reminder style',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: AlarmBehavior.values.map((behavior) {
              return ChoiceChip(
                label: Text(behavior.label),
                selected: settings.alarmBehavior == behavior,
                onSelected: (_) {
                  appState.setAlarmBehavior(behavior);
                },
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 10),
        child,
      ],
    );
  }
}
