import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../data/app_state.dart';
import '../scan/meeting_candidate.dart';
import '../scan/screenshot_analyzer.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({required this.appState, super.key});

  final AppState appState;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final imagePicker = ImagePicker();
  final analyzer = ScreenshotAnalyzer();
  final schedulingCandidates = <MeetingCandidate>{};

  XFile? selectedImage;
  String pickerStatus = 'No screenshot selected yet.';
  ScanResult? scanResult;
  var isAnalyzing = false;

  Future<void> pickScreenshot() async {
    await pickImage(ImageSource.gallery);
  }

  Future<void> takeScreenshotPhoto() async {
    await pickImage(ImageSource.camera);
  }

  Future<void> pickImage(ImageSource source) async {
    final image = await imagePicker.pickImage(source: source);
    setState(() {
      selectedImage = image;
      pickerStatus = image == null
          ? 'No screenshot selected yet.'
          : source == ImageSource.camera
              ? 'Photo captured. Ready to read meetings.'
              : 'Screenshot selected. Ready to read meetings.';
      scanResult = null;
      schedulingCandidates.clear();
    });
  }

  Future<void> analyzeScreenshot() async {
    final image = selectedImage;
    if (image == null || isAnalyzing) {
      return;
    }

    setState(() {
      isAnalyzing = true;
      pickerStatus = 'Reading meetings from the screenshot...';
    });

    try {
      final settings = widget.appState.settings;
      final result = await analyzer.analyze(
        imagePath: image.path,
        reminderOffsetMinutes: settings.defaultReminderOffsetMinutes,
      );
      if (!mounted) {
        return;
      }

      for (final candidate in result.candidates) {
        candidate.selected = false;
      }

      setState(() {
        scanResult = result;
        pickerStatus =
            'Found ${result.candidates.length} meeting(s). Tap a star to schedule one.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        pickerStatus = 'Analysis failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          isAnalyzing = false;
        });
      }
    }
  }

  Future<void> scheduleCandidate(MeetingCandidate candidate) async {
    if (candidate.selected || schedulingCandidates.contains(candidate)) {
      return;
    }

    setState(() {
      schedulingCandidates.add(candidate);
    });

    try {
      await widget.appState.saveMeeting(candidate.toMeeting());
      if (!mounted) {
        return;
      }
      setState(() {
        candidate.selected = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Alarm set for ${candidate.title}.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not set alarm: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          schedulingCandidates.remove(candidate);
        });
      }
    }
  }

  void splitCandidate(MeetingCandidate candidate, String secondTitle) {
    final result = scanResult;
    if (result == null) {
      return;
    }

    final index = result.candidates.indexOf(candidate);
    if (index == -1) {
      return;
    }

    final duplicate = MeetingCandidate(
      title: secondTitle,
      startsAt: candidate.startsAt,
      reminderOffsetMinutes: candidate.reminderOffsetMinutes,
      sourceImagePath: candidate.sourceImagePath,
      confidence: candidate.confidence * 0.9,
      reason: '${candidate.reason} Manually split from a combined card.',
      selected: false,
    );

    setState(() {
      result.candidates.insert(index + 1, duplicate);
      pickerStatus =
          'Found ${result.candidates.length} meeting(s). Tap a star to schedule one.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.appState.settings;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.image_search,
                  color: Theme.of(context).colorScheme.primary,
                  size: 32,
                ),
                const SizedBox(height: 12),
                Text(
                  'Pick an Outlook week screenshot',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Upload the screenshot as-is. The app reads the meetings and lets you star the ones that need alarms.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: pickScreenshot,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Choose screenshot'),
                    ),
                    OutlinedButton.icon(
                      onPressed: takeScreenshotPhoto,
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Take photo'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _ScanSetupCard(
          reminderOffsetMinutes: settings.defaultReminderOffsetMinutes,
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Selected screenshot',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  pickerStatus,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                if (selectedImage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    selectedImage!.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: isAnalyzing ? null : analyzeScreenshot,
                    icon: const Icon(Icons.document_scanner_outlined),
                    label: Text(isAnalyzing ? 'Analyzing...' : 'Analyze'),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (scanResult != null) ...[
          const SizedBox(height: 16),
          _DetectedMeetingsCard(
            scanResult: scanResult!,
            schedulingCandidates: schedulingCandidates,
            onChanged: () => setState(() {}),
            onStar: scheduleCandidate,
            onSplit: splitCandidate,
          ),
        ],
      ],
    );
  }
}

class _ScanSetupCard extends StatelessWidget {
  const _ScanSetupCard({required this.reminderOffsetMinutes});

  final int reminderOffsetMinutes;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Scan setup',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'All visible meetings are listed. Starring a meeting schedules an alarm $reminderOffsetMinutes minutes before it starts.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  Icons.auto_awesome,
                  color: Theme.of(context).colorScheme.primary,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Uses on-device OCR first, then a local Llama parser when it is running.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DetectedMeetingsCard extends StatelessWidget {
  const _DetectedMeetingsCard({
    required this.scanResult,
    required this.schedulingCandidates,
    required this.onChanged,
    required this.onStar,
    required this.onSplit,
  });

  final ScanResult scanResult;
  final Set<MeetingCandidate> schedulingCandidates;
  final VoidCallback onChanged;
  final Future<void> Function(MeetingCandidate candidate) onStar;
  final void Function(MeetingCandidate candidate, String secondTitle) onSplit;

  @override
  Widget build(BuildContext context) {
    final scheduledCount =
        scanResult.candidates.where((candidate) => candidate.selected).length;
    final reviewCount =
        scanResult.candidates.where(_candidateNeedsReview).length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Detected meetings',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                Text(
                  '$scheduledCount starred',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (scanResult.candidates.isNotEmpty) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _StatusChip(
                    icon: Icons.event_available,
                    label: '${scanResult.candidates.length} found',
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  _StatusChip(
                    icon: reviewCount == 0
                        ? Icons.verified_outlined
                        : Icons.error_outline,
                    label: reviewCount == 0
                        ? 'times look good'
                        : '$reviewCount need review',
                    color: reviewCount == 0
                        ? Colors.green.shade700
                        : Colors.orange.shade800,
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            Text(
              'Check any review badges, adjust the time if needed, then tap the star to set the alarm.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            if (scanResult.candidates.isEmpty)
              const Text('No meetings were found in this screenshot.')
            else
              ...scanResult.candidates.map((candidate) {
                return _MeetingRow(
                  candidate: candidate,
                  isScheduling: schedulingCandidates.contains(candidate),
                  onChanged: onChanged,
                  onStar: onStar,
                  onSplit: onSplit,
                );
              }),
            const SizedBox(height: 12),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Scan details'),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    scanResult.recognizedText.trim().isEmpty
                        ? 'No text recognized.'
                        : scanResult.recognizedText,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MeetingRow extends StatefulWidget {
  const _MeetingRow({
    required this.candidate,
    required this.isScheduling,
    required this.onChanged,
    required this.onStar,
    required this.onSplit,
  });

  final MeetingCandidate candidate;
  final bool isScheduling;
  final VoidCallback onChanged;
  final Future<void> Function(MeetingCandidate candidate) onStar;
  final void Function(MeetingCandidate candidate, String secondTitle) onSplit;

  @override
  State<_MeetingRow> createState() => _MeetingRowState();
}

class _MeetingRowState extends State<_MeetingRow> {
  late final TextEditingController titleController;
  late final TextEditingController offsetController;

  @override
  void initState() {
    super.initState();
    titleController = TextEditingController(text: widget.candidate.title);
    offsetController = TextEditingController(
      text: widget.candidate.reminderOffsetMinutes.toString(),
    );
  }

  @override
  void dispose() {
    titleController.dispose();
    offsetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dateFormatter = DateFormat('EEE, MMM d');
    final timeFormatter = DateFormat('h:mm a');
    final isScheduled = widget.candidate.selected;
    final needsReview = _candidateNeedsReview(widget.candidate);
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 10),
      decoration: BoxDecoration(
        color: needsReview
            ? Colors.orange.withValues(alpha: 0.06)
            : theme.colorScheme.surface,
        border: Border.all(
          color: needsReview
              ? Colors.orange.shade300
              : theme.colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  controller: titleController,
                  enabled: !isScheduled,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Meeting title',
                  ),
                  style: theme.textTheme.titleMedium,
                  onChanged: (value) {
                    widget.candidate.title = value;
                  },
                ),
              ),
              IconButton(
                tooltip: isScheduled ? 'Alarm scheduled' : 'Set alarm',
                onPressed: isScheduled || widget.isScheduling
                    ? null
                    : () async {
                        _syncCandidateFromFields();
                        await widget.onStar(widget.candidate);
                      },
                icon: widget.isScheduling
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        isScheduled ? Icons.star : Icons.star_border,
                        color: isScheduled
                            ? Colors.amber.shade700
                            : Theme.of(context).colorScheme.primary,
                      ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: isScheduled ? null : () => _pickDateTime(context),
                  icon: const Icon(Icons.schedule, size: 18),
                  label: Text(
                    '${dateFormatter.format(widget.candidate.startsAt)}  ${timeFormatter.format(widget.candidate.startsAt)}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 120,
                child: TextField(
                  controller: offsetController,
                  enabled: !isScheduled,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Remind before',
                    suffixText: 'min',
                  ),
                  onChanged: (value) {
                    widget.candidate.reminderOffsetMinutes =
                        int.tryParse(value) ??
                            widget.candidate.reminderOffsetMinutes;
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: isScheduled ? null : _splitRow,
              icon: const Icon(Icons.call_split, size: 18),
              label: const Text('Split'),
            ),
          ),
        ],
      ),
    );
  }

  void _syncCandidateFromFields() {
    widget.candidate.title = titleController.text;
    widget.candidate.reminderOffsetMinutes =
        int.tryParse(offsetController.text) ??
            widget.candidate.reminderOffsetMinutes;
  }

  void _splitRow() {
    _syncCandidateFromFields();
    final titles = _suggestSplitTitles(widget.candidate.title);
    setState(() {
      titleController.text = titles.first;
      widget.candidate.title = titles.first;
    });
    widget.onSplit(widget.candidate, titles.last);
    widget.onChanged();
  }

  List<String> _suggestSplitTitles(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      return ['Untitled meeting', 'Untitled meeting'];
    }

    final splitPatterns = [
      RegExp(r'(?<=\b(?:am|pm))\s+(?=[A-Z][A-Za-z])', caseSensitive: false),
      RegExp(r'\s{2,}'),
      RegExp(r'\s+\|\s+'),
    ];

    for (final pattern in splitPatterns) {
      final pieces = trimmed
          .split(pattern)
          .map((piece) => piece.trim())
          .where((piece) => piece.length >= 3)
          .toList();
      if (pieces.length >= 2) {
        return [pieces.first, pieces.sublist(1).join(' ')];
      }
    }

    return [trimmed, 'New split meeting'];
  }

  Future<void> _pickDate(BuildContext context) async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: widget.candidate.startsAt,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now().add(const Duration(days: 370)),
    );
    if (pickedDate == null) {
      return;
    }
    setState(() {
      widget.candidate.startsAt = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        widget.candidate.startsAt.hour,
        widget.candidate.startsAt.minute,
      );
    });
    widget.onChanged();
  }

  Future<void> _pickTime(BuildContext context) async {
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(widget.candidate.startsAt),
    );
    if (pickedTime == null) {
      return;
    }
    setState(() {
      widget.candidate.startsAt = DateTime(
        widget.candidate.startsAt.year,
        widget.candidate.startsAt.month,
        widget.candidate.startsAt.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    });
    widget.onChanged();
  }

  Future<void> _pickDateTime(BuildContext context) async {
    await _pickDate(context);
    if (!context.mounted) {
      return;
    }
    await _pickTime(context);
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w800,
                ),
          ),
        ],
      ),
    );
  }
}

bool _candidateNeedsReview(MeetingCandidate candidate) {
  final reason = candidate.reason.toLowerCase();
  return candidate.confidence < 0.8 ||
      reason.contains('inferred') ||
      reason.contains('estimated') ||
      reason.contains('need review');
}
