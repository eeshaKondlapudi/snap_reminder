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
        // const SizedBox(height: 24),
        // _SettingsSection(
        //   title: 'Microsoft Graph',
        //   child: _MicrosoftClientIdField(appState: appState),
        // ),
      ],
    );
  }
}

class _MicrosoftClientIdField extends StatefulWidget {
  const _MicrosoftClientIdField({required this.appState});

  final AppState appState;

  @override
  State<_MicrosoftClientIdField> createState() =>
      _MicrosoftClientIdFieldState();
}

class _MicrosoftClientIdFieldState extends State<_MicrosoftClientIdField> {
  late final TextEditingController controller;
  var isSaving = false;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(
      text: widget.appState.settings.microsoftClientId,
    );
  }

  @override
  void didUpdateWidget(covariant _MicrosoftClientIdField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final currentValue = widget.appState.settings.microsoftClientId;
    if (controller.text != currentValue && !isSaving) {
      controller.text = currentValue;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      isSaving = true;
    });
    await widget.appState.setMicrosoftClientId(controller.text);
    if (!mounted) {
      return;
    }
    setState(() {
      isSaving = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Microsoft client ID saved.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Azure Application client ID',
            helperText:
                'Redirect URI: msauth://com.example.snap_reminder/iwckoFi05XXx3Da9T1NHxfqglac=',
          ),
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => save(),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: isSaving ? null : save,
          icon: const Icon(Icons.save_outlined),
          label: Text(isSaving ? 'Saving...' : 'Save client ID'),
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
