import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/app_state.dart';
import '../data/models/important_meeting.dart';
import '../outlook/microsoft_calendar_service.dart';

class OutlookScreen extends StatefulWidget {
  const OutlookScreen({
    required this.appState,
    this.calendarService,
    super.key,
  });

  final AppState appState;
  final MicrosoftCalendarService? calendarService;

  @override
  State<OutlookScreen> createState() => _OutlookScreenState();
}

class _OutlookScreenState extends State<OutlookScreen> {
  late final MicrosoftCalendarService calendarService =
      widget.calendarService ?? MicrosoftCalendarService();
  late final TextEditingController sharedCalendarController =
      TextEditingController();

  late DateTime weekStart = _startOfWeek(DateTime.now());
  final scheduledEvents = <String, ImportantMeeting>{};
  var events = <OutlookCalendarEvent>[];
  var isLoading = false;
  String status = 'Connect Outlook to load calendar events directly.';

  Future<void> connectAndFetch() async {
    if (isLoading) {
      return;
    }

    final clientId = widget.appState.settings.microsoftClientId.trim();
    if (clientId.isEmpty) {
      setState(() {
        status = 'Add your Azure Application client ID in Settings first.';
      });
      return;
    }

    setState(() {
      isLoading = true;
      status = 'Opening Microsoft sign-in...';
    });

    try {
      final fetchedEvents = await calendarService.fetchWeek(
        clientId: clientId,
        weekStart: weekStart,
      );
      final upcomingEvents = _upcomingEvents(fetchedEvents);
      if (!mounted) {
        return;
      }
      setState(() {
        events = upcomingEvents;
        status = 'Loaded ${events.length} Outlook event(s).';
      });
    } on MicrosoftCalendarException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        status = error.message;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        status = 'Could not load Outlook calendar: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> loadSharedCalendar() async {
    if (isLoading) {
      return;
    }

    final uri = Uri.tryParse(sharedCalendarController.text.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      setState(() {
        status = 'Paste a valid Outlook shared calendar link first.';
      });
      return;
    }

    setState(() {
      isLoading = true;
      status = 'Loading shared calendar link...';
    });

    try {
      final fetchedEvents = await calendarService.fetchSharedCalendarWeek(
        calendarUri: uri,
        weekStart: weekStart,
      );
      final upcomingEvents = _upcomingEvents(fetchedEvents);
      if (!mounted) {
        return;
      }
      setState(() {
        events = upcomingEvents;
        status = 'Loaded ${events.length} shared calendar event(s).';
      });
    } on MicrosoftCalendarException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        status = error.message;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        status = 'Could not load shared calendar: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> toggleEventAlarm(OutlookCalendarEvent event) async {
    try {
      final scheduledMeeting = scheduledEvents[event.id];
      if (scheduledMeeting != null) {
        await widget.appState.deleteMeeting(scheduledMeeting);
        if (!mounted) {
          return;
        }
        setState(() {
          scheduledEvents.remove(event.id);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Alarm removed for ${event.title}.')),
        );
        return;
      }

      final savedMeeting = await widget.appState.saveMeeting(
        ImportantMeeting(
            title: event.title,
            startsAt: event.startsAt,
            reminderOffsetMinutes:
                widget.appState.settings.defaultReminderOffsetMinutes),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        scheduledEvents[event.id] = savedMeeting;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Alarm set for ${event.title}.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not set alarm: $error')),
      );
    }
  }

  void moveWeek(int delta) {
    setState(() {
      weekStart = weekStart.add(Duration(days: delta * 7));
      events = [];
      scheduledEvents.clear();
      status = 'Week changed. Load Outlook events again.';
    });
  }

  List<OutlookCalendarEvent> _upcomingEvents(
    List<OutlookCalendarEvent> loadedEvents,
  ) {
    final now = DateTime.now();
    return loadedEvents.where((event) => event.endsAt.isAfter(now)).toList()
      ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
  }

  @override
  void dispose() {
    sharedCalendarController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final weekEnd = weekStart.add(const Duration(days: 4));
    final formatter = DateFormat('MMM d');
    final weekLabel =
        '${formatter.format(weekStart)} - ${formatter.format(weekEnd)}';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.event_available_outlined,
                      color: Theme.of(context).colorScheme.primary,
                      size: 30,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Outlook calendar',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    IconButton.outlined(
                      tooltip: 'Previous week',
                      onPressed: isLoading ? null : () => moveWeek(-1),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          weekLabel,
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                      ),
                    ),
                    IconButton.outlined(
                      tooltip: 'Next week',
                      onPressed: isLoading ? null : () => moveWeek(1),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  status,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: isLoading ? null : connectAndFetch,
                  icon: isLoading
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: Text(isLoading ? 'Loading...' : 'Load Outlook week'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: sharedCalendarController,
                  decoration: const InputDecoration(
                    labelText: 'Shared calendar link',
                    hintText: 'https://outlook.live.com/owa/calendar/...',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => loadSharedCalendar(),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: isLoading ? null : loadSharedCalendar,
                  icon: const Icon(Icons.link),
                  label: const Text('Load shared link'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (events.isEmpty)
          const _EmptyOutlookEvents()
        else
          ...events.map((event) {
            return _OutlookEventCard(
              event: event,
              isScheduled: scheduledEvents.containsKey(event.id),
              onStar: () => toggleEventAlarm(event),
            );
          }),
      ],
    );
  }

  DateTime _startOfWeek(DateTime date) {
    final midnight = DateTime(date.year, date.month, date.day);
    return midnight
        .subtract(Duration(days: midnight.weekday - DateTime.monday));
  }
}

class _OutlookEventCard extends StatelessWidget {
  const _OutlookEventCard({
    required this.event,
    required this.isScheduled,
    required this.onStar,
  });

  final OutlookCalendarEvent event;
  final bool isScheduled;
  final VoidCallback onStar;

  @override
  Widget build(BuildContext context) {
    final dateFormatter = DateFormat('EEE, MMM d');
    final timeFormatter = DateFormat('h:mm a');
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surface,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _InfoChip(
                      icon: Icons.schedule,
                      label:
                          '${dateFormatter.format(event.startsAt)} ${timeFormatter.format(event.startsAt)}',
                    ),
                    if (event.location.isNotEmpty)
                      _InfoChip(
                        icon: Icons.place_outlined,
                        label: event.location,
                      ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: isScheduled ? 'Remove alarm' : 'Set alarm',
            onPressed: onStar,
            icon: Icon(
              isScheduled ? Icons.star : Icons.star_border,
              color: isScheduled
                  ? Colors.amber.shade700
                  : theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
    );
  }
}

class _EmptyOutlookEvents extends StatelessWidget {
  const _EmptyOutlookEvents();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Text(
          'No Outlook events loaded yet.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}
