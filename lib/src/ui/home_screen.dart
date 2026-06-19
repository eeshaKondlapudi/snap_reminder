import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/models/important_meeting.dart';
import '../voice/dictation_service.dart';
import '../voice/voice_reminder_parser.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    required this.meetings,
    required this.onSaveMeeting,
    required this.onDeleteMeeting,
    this.dictationService = const DictationService(),
    this.voiceReminderParser = const VoiceReminderParser(),
    super.key,
  });

  final List<ImportantMeeting> meetings;
  final Future<void> Function(ImportantMeeting meeting) onSaveMeeting;
  final Future<void> Function(ImportantMeeting meeting) onDeleteMeeting;
  final DictationService dictationService;
  final VoiceReminderParser voiceReminderParser;

  @override
  Widget build(BuildContext context) {
    final children = [
      _VoiceReminderCard(
        dictationService: dictationService,
        parser: voiceReminderParser,
        onSaveMeeting: onSaveMeeting,
      ),
      const SizedBox(height: 16),
      if (meetings.isEmpty)
        const _EmptyHome()
      else
        ...meetings.map(
          (meeting) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _MeetingCard(
              meeting: meeting,
              onDelete: onDeleteMeeting,
            ),
          ),
        ),
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: children,
    );
  }
}

class _VoiceReminderCard extends StatefulWidget {
  const _VoiceReminderCard({
    required this.dictationService,
    required this.parser,
    required this.onSaveMeeting,
  });

  final DictationService dictationService;
  final VoiceReminderParser parser;
  final Future<void> Function(ImportantMeeting meeting) onSaveMeeting;

  @override
  State<_VoiceReminderCard> createState() => _VoiceReminderCardState();
}

class _VoiceReminderCardState extends State<_VoiceReminderCard> {
  var isListening = false;
  String? lastTranscript;

  Future<void> startDictation() async {
    if (isListening) {
      return;
    }

    setState(() {
      isListening = true;
      lastTranscript = 'Say your reminder...';
    });

    try {
      final transcript = await widget.dictationService.listen(
        onTranscript: (transcript) {
          if (!mounted) {
            return;
          }
          setState(() {
            lastTranscript = transcript;
          });
        },
      );
      if (!mounted) {
        return;
      }

      setState(() {
        if (transcript.isNotEmpty) {
          lastTranscript = transcript;
        }
        isListening = false;
      });

      await scheduleFromPhrase(transcript);
    } on DictationException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        isListening = false;
      });
      final phrase = await showManualPhraseDialog(
        context,
        title: 'Type reminder',
        initialText: lastTranscript ?? '',
        helperText: error.message,
      );
      if (phrase != null && mounted) {
        await scheduleFromPhrase(phrase);
      }
    } finally {
      if (mounted && isListening) {
        setState(() {
          isListening = false;
        });
      }
    }
  }

  Future<void> typeReminder() async {
    final phrase = await showManualPhraseDialog(
      context,
      title: 'Type reminder',
      initialText: '',
      helperText: 'Example: At 6:30, go get groceries',
    );
    if (phrase != null && mounted) {
      await scheduleFromPhrase(phrase);
    }
  }

  Future<void> scheduleFromPhrase(String phrase) async {
    final trimmedPhrase = phrase.trim();
    if (trimmedPhrase.isEmpty) {
      _showMessage('No reminder heard.');
      return;
    }

    late final ImportantMeeting meeting;
    try {
      meeting = widget.parser.parse(trimmedPhrase);
    } on FormatException catch (error) {
      final correctedPhrase = await showManualPhraseDialog(
        context,
        title: 'Check reminder',
        initialText: trimmedPhrase,
        helperText: error.message,
      );
      if (correctedPhrase == null || !mounted) {
        return;
      }
      return scheduleFromPhrase(correctedPhrase);
    }

    try {
      await widget.onSaveMeeting(meeting);
      if (!mounted) {
        return;
      }
      final formatter = DateFormat('EEE, MMM d | h:mm a');
      _showMessage(
        'Alarm set for ${meeting.title} at ${formatter.format(meeting.startsAt)}.',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('Could not set alarm: $error');
    }
  }

  Future<String?> showManualPhraseDialog(
    BuildContext context, {
    required String title,
    required String initialText,
    required String helperText,
  }) async {
    var phrase = initialText;
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextFormField(
            initialValue: initialText,
            onChanged: (value) {
              phrase = value;
            },
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              helperText: helperText,
              hintText: 'At 6:30, go get groceries',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop(phrase);
              },
              icon: const Icon(Icons.alarm_add),
              label: const Text('Set alarm'),
            ),
          ],
        );
      },
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isListening ? Icons.hearing : Icons.mic_none,
                  color: theme.colorScheme.primary,
                  size: 32,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Voice reminder',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isListening
                            ? lastTranscript ?? 'Listening...'
                            : lastTranscript ??
                                'Alarm defaults to 5 minutes before.',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: isListening ? null : typeReminder,
                  icon: const Icon(Icons.keyboard_outlined),
                  label: const Text('Type'),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: isListening ? null : startDictation,
                  icon: Icon(isListening ? Icons.more_horiz : Icons.mic),
                  label: Text(isListening ? 'Listening' : 'Dictate'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHome extends StatelessWidget {
  const _EmptyHome();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.event_available,
            color: theme.colorScheme.primary,
            size: 34,
          ),
          const SizedBox(height: 12),
          Text(
            'No reminders yet',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Scan an Outlook week screenshot to start saving important meeting alarms.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _MeetingCard extends StatelessWidget {
  const _MeetingCard({required this.meeting, required this.onDelete});

  final ImportantMeeting meeting;
  final Future<void> Function(ImportantMeeting meeting) onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formatter = DateFormat('EEE, MMM d | h:mm a');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    meeting.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Delete reminder',
                  onPressed: () => _confirmDelete(context),
                  icon: const Icon(Icons.delete_outline),
                  color: theme.colorScheme.error,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              formatter.format(meeting.startsAt),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Alarm ${meeting.reminderOffsetMinutes} minutes before',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete reminder?'),
          content: Text(
            'Remove "${meeting.title}" and cancel its scheduled alarm?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !context.mounted) {
      return;
    }

    try {
      await onDelete(meeting);
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted ${meeting.title}.')),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete reminder: $error')),
      );
    }
  }
}
