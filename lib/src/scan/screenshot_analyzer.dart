import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

import 'meeting_candidate.dart';
import 'ocr_meeting_parser_client.dart';

class ScreenshotAnalyzer {
  ScreenshotAnalyzer({OcrMeetingParserClient? parserClient})
      : parserClient = parserClient ?? OcrMeetingParserClient();

  final OcrMeetingParserClient parserClient;

  Future<ScanResult> analyze({
    required String imagePath,
    required int reminderOffsetMinutes,
  }) async {
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final recognizedText = await textRecognizer.processImage(inputImage);
      final textLines = _extractTextLines(recognizedText);
      final eventBlocks = await _refineEventBlocksWithZoomedOcr(
        imagePath: imagePath,
        eventBlocks: await _detectEventBlocks(imagePath, textLines),
        textRecognizer: textRecognizer,
      );
      final parserCandidates = await _parseWithLlama(
        textLines: textLines,
        eventBlocks: eventBlocks,
        rawText: recognizedText.text,
        imagePath: imagePath,
        reminderOffsetMinutes: reminderOffsetMinutes,
      );

      return ScanResult(
        candidates: parserCandidates ??
            (eventBlocks.isEmpty
                ? _meetingCandidates(
                    textLines: textLines,
                    imagePath: imagePath,
                    reminderOffsetMinutes: reminderOffsetMinutes,
                  )
                : _meetingCandidatesFromEventBlocks(
                    eventBlocks: eventBlocks,
                    textLines: textLines,
                    imagePath: imagePath,
                    reminderOffsetMinutes: reminderOffsetMinutes,
                  )),
        recognizedText: recognizedText.text,
      );
    } finally {
      await textRecognizer.close();
    }
  }

  Future<List<MeetingCandidate>?> _parseWithLlama({
    required List<_TextLineInfo> textLines,
    required List<_EventBlock> eventBlocks,
    required String rawText,
    required String imagePath,
    required int reminderOffsetMinutes,
  }) async {
    if (rawText.trim().isEmpty || textLines.isEmpty) {
      return null;
    }

    try {
      final candidates = await parserClient.parse(
        lines: textLines
            .map((line) => OcrLinePayload(text: line.text, rect: line.rect))
            .toList(),
        events: eventBlocks
            .map((block) => _eventPayloadFromBlock(block, textLines))
            .toList(),
        rawText: rawText,
        imagePath: imagePath,
        reminderOffsetMinutes: reminderOffsetMinutes,
      );
      return _deduplicateCandidates(_filterCandidates(candidates));
    } catch (_) {
      return null;
    }
  }

  Future<List<_EventBlock>> _detectEventBlocks(
    String imagePath,
    List<_TextLineInfo> textLines,
  ) async {
    final bytes = await File(imagePath).readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) {
      return [];
    }

    final timeAnchors = _extractTimeAnchors(textLines);
    final dateAnchors = _extractDateAnchors(textLines);
    final gridBounds = _estimateGridBounds(image, dateAnchors, timeAnchors);
    final clusters = _findColoredRectangles(image, gridBounds);
    final blocks = <_EventBlock>[];

    for (final cluster in clusters) {
      final rect = cluster.rect;
      final lines = textLines
          .where((line) {
            return _expanded(rect, 5).overlaps(line.rect) ||
                rect.contains(line.rect.center);
          })
          .where((line) => line.text.trim().isNotEmpty)
          .toList();
      final usefulLines =
          lines.where((line) => !_looksLikeNonEventLine(line.text)).toList();
      if (usefulLines.isEmpty) {
        continue;
      }

      blocks.add(_EventBlock(rect: rect, lines: usefulLines));
    }

    blocks.sort((a, b) {
      final yCompare = a.rect.top.compareTo(b.rect.top);
      if (yCompare != 0) {
        return yCompare;
      }
      return a.rect.left.compareTo(b.rect.left);
    });

    return _deduplicateEventBlocks(blocks);
  }

  Future<List<_EventBlock>> _refineEventBlocksWithZoomedOcr({
    required String imagePath,
    required List<_EventBlock> eventBlocks,
    required TextRecognizer textRecognizer,
  }) async {
    if (eventBlocks.isEmpty) {
      return eventBlocks;
    }

    final bytes = await File(imagePath).readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) {
      return eventBlocks;
    }

    final refined = <_EventBlock>[];
    for (var index = 0; index < eventBlocks.length; index += 1) {
      final block = eventBlocks[index];
      final zoomedLines = await _ocrZoomedEventBlock(
        image: image,
        block: block,
        index: index,
        textRecognizer: textRecognizer,
      );
      refined.add(
        zoomedLines.isEmpty
            ? block
            : _EventBlock(
                rect: block.rect,
                lines: _mergeBlockLines(zoomedLines, block.lines),
              ),
      );
    }

    return refined;
  }

  List<_TextLineInfo> _mergeBlockLines(
    List<_TextLineInfo> primary,
    List<_TextLineInfo> fallback,
  ) {
    final merged = <_TextLineInfo>[];
    for (final line in [...primary, ...fallback]) {
      final cleaned = _cleanMeetingTitle(line.text).toLowerCase();
      if (cleaned.isEmpty) {
        continue;
      }
      final exists = merged.any((item) {
        return _cleanMeetingTitle(item.text).toLowerCase() == cleaned;
      });
      if (!exists) {
        merged.add(line);
      }
    }
    return merged;
  }

  Future<List<_TextLineInfo>> _ocrZoomedEventBlock({
    required img.Image image,
    required _EventBlock block,
    required int index,
    required TextRecognizer textRecognizer,
  }) async {
    const scale = 3;
    final cropRect = _clampedCropRect(
      block.rect,
      image.width,
      image.height,
    );
    if (cropRect.width < 16 || cropRect.height < 8) {
      return [];
    }

    final crop = img.copyCrop(
      image,
      x: cropRect.left.round(),
      y: cropRect.top.round(),
      width: cropRect.width.round(),
      height: cropRect.height.round(),
    );
    final zoomed = img.copyResize(
      crop,
      width: crop.width * scale,
      height: crop.height * scale,
      interpolation: img.Interpolation.cubic,
    );

    final tempFile = File(
      '${Directory.systemTemp.path}/snap_reminder_event_${DateTime.now().microsecondsSinceEpoch}_$index.png',
    );
    try {
      await tempFile.writeAsBytes(img.encodePng(zoomed), flush: true);
      final recognizedText = await textRecognizer.processImage(
        InputImage.fromFilePath(tempFile.path),
      );
      final lines = _extractTextLines(recognizedText)
          .map((line) {
            final rect = Rect.fromLTRB(
              cropRect.left + line.rect.left / scale,
              cropRect.top + line.rect.top / scale,
              cropRect.left + line.rect.right / scale,
              cropRect.top + line.rect.bottom / scale,
            );
            return _TextLineInfo(text: line.text, rect: rect);
          })
          .where((line) => line.text.trim().isNotEmpty)
          .toList();
      final usefulLines =
          lines.where((line) => !_looksLikeNonEventLine(line.text)).toList();
      return usefulLines;
    } finally {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  Rect _clampedCropRect(Rect rect, int imageWidth, int imageHeight) {
    final left = max(0.0, rect.left - 2);
    final top = max(0.0, rect.top - 2);
    final right = min(imageWidth.toDouble(), rect.right + 2);
    final bottom = min(imageHeight.toDouble(), rect.bottom + 2);
    return Rect.fromLTRB(left, top, max(left + 1, right), max(top + 1, bottom));
  }

  Rect _estimateGridBounds(
    img.Image image,
    List<_DateAnchor> dateAnchors,
    List<_TimeAnchor> timeAnchors,
  ) {
    final top = timeAnchors.isEmpty
        ? image.height * 0.18
        : max(0, timeAnchors.map((anchor) => anchor.y).reduce(min) - 40);
    final bottom = timeAnchors.isEmpty
        ? image.height * 0.96
        : min(
            image.height.toDouble(),
            timeAnchors.map((anchor) => anchor.y).reduce(max) + 80,
          );
    final left = dateAnchors.isEmpty
        ? image.width * 0.22
        : max(0, dateAnchors.map((anchor) => anchor.x).reduce(min) - 70);
    final right = dateAnchors.isEmpty
        ? image.width * 0.98
        : min(
            image.width.toDouble(),
            dateAnchors.map((anchor) => anchor.x).reduce(max) + 90,
          );

    return Rect.fromLTRB(
      left.toDouble(),
      top.toDouble(),
      right.toDouble(),
      bottom.toDouble(),
    );
  }

  List<_ColorCluster> _findColoredRectangles(img.Image image, Rect gridBounds) {
    const step = 3;
    final visited = <int>{};
    final clusters = <_ColorCluster>[];

    final startY = gridBounds.top.clamp(0, image.height - 1).round();
    final endY = gridBounds.bottom.clamp(0, image.height - 1).round();
    final startX = gridBounds.left.clamp(0, image.width - 1).round();
    final endX = gridBounds.right.clamp(0, image.width - 1).round();

    for (var y = startY; y <= endY; y += step) {
      for (var x = startX; x <= endX; x += step) {
        final key = y * image.width + x;
        if (visited.contains(key) ||
            !_isCalendarEventPixel(image.getPixel(x, y))) {
          continue;
        }

        final cluster = _growColorCluster(image, x, y, step, visited);
        final rect = cluster.rect;
        final area = rect.width * rect.height;
        if (cluster.count >= 12 &&
            rect.width >= 28 &&
            rect.height >= 12 &&
            rect.width <= image.width * 0.25 &&
            rect.height <= image.height * 0.18 &&
            area >= 450) {
          clusters.add(cluster);
        }
      }
    }

    return _mergeNearbyClusters(clusters);
  }

  _ColorCluster _growColorCluster(
    img.Image image,
    int startX,
    int startY,
    int step,
    Set<int> visited,
  ) {
    final queue = <Point<int>>[Point(startX, startY)];
    var minX = startX;
    var maxX = startX;
    var minY = startY;
    var maxY = startY;
    var count = 0;

    while (queue.isNotEmpty && count < 35000) {
      final point = queue.removeLast();
      final x = point.x.clamp(0, image.width - 1);
      final y = point.y.clamp(0, image.height - 1);
      final key = y * image.width + x;
      if (visited.contains(key)) {
        continue;
      }
      visited.add(key);

      if (!_isCalendarEventPixel(image.getPixel(x, y))) {
        continue;
      }

      count += 1;
      minX = min(minX, x);
      maxX = max(maxX, x);
      minY = min(minY, y);
      maxY = max(maxY, y);

      queue
        ..add(Point(x + step, y))
        ..add(Point(x - step, y))
        ..add(Point(x, y + step))
        ..add(Point(x, y - step));
    }

    return _ColorCluster(
      rect: Rect.fromLTRB(
        minX.toDouble(),
        minY.toDouble(),
        maxX.toDouble(),
        maxY.toDouble(),
      ),
      count: count,
    );
  }

  bool _isCalendarEventPixel(img.Pixel pixel) {
    final r = pixel.r.toInt();
    final g = pixel.g.toInt();
    final b = pixel.b.toInt();
    final maxChannel = max(r, max(g, b));
    final minChannel = min(r, min(g, b));
    final saturation = maxChannel - minChannel;
    final brightness = (r + g + b) / 3;

    if (brightness < 125 || brightness > 248 || saturation < 12) {
      return false;
    }

    final looksLikeStrongToolbarBlue = b > 150 && g > 80 && r < 80;
    return !looksLikeStrongToolbarBlue;
  }

  List<_ColorCluster> _mergeNearbyClusters(List<_ColorCluster> clusters) {
    final merged = <_ColorCluster>[];
    for (final cluster in clusters) {
      final index = merged.indexWhere((existing) {
        return _expanded(existing.rect, 6).overlaps(cluster.rect);
      });
      if (index == -1) {
        merged.add(cluster);
      } else {
        final existing = merged[index];
        merged[index] = _ColorCluster(
          rect: existing.rect.expandToInclude(cluster.rect),
          count: existing.count + cluster.count,
        );
      }
    }
    return merged;
  }

  List<_EventBlock> _deduplicateEventBlocks(List<_EventBlock> blocks) {
    final unique = <_EventBlock>[];
    for (final block in blocks) {
      final duplicate = unique.any((item) {
        return item.rect.overlaps(block.rect) &&
            _overlapRatio(item.rect, block.rect) > 0.55;
      });
      if (!duplicate) {
        unique.add(block);
      }
    }
    return unique;
  }

  double _overlapRatio(Rect a, Rect b) {
    final left = max(a.left, b.left);
    final top = max(a.top, b.top);
    final right = min(a.right, b.right);
    final bottom = min(a.bottom, b.bottom);
    if (right <= left || bottom <= top) {
      return 0;
    }
    final overlap = (right - left) * (bottom - top);
    final smaller = min(a.width * a.height, b.width * b.height);
    return smaller == 0 ? 0 : overlap / smaller;
  }

  CalendarEventPayload _eventPayloadFromBlock(
    _EventBlock block,
    List<_TextLineInfo> textLines,
  ) {
    final dateAnchors = _extractDateAnchors(textLines);
    final timeAnchors = _extractTimeAnchors(textLines);
    final inferredStart = _inferStartTimeFromRect(
      rect: block.rect,
      dateAnchors: dateAnchors,
      timeAnchors: timeAnchors,
      eventLines: block.lines,
    );

    return CalendarEventPayload(
      left: block.rect.left.round(),
      top: block.rect.top.round(),
      right: block.rect.right.round(),
      bottom: block.rect.bottom.round(),
      lines: block.lines.map((line) => line.text).toList(),
      inferredDate: _formatDate(inferredStart),
      inferredStartTime: _formatTime(inferredStart),
    );
  }

  List<_TextLineInfo> _extractTextLines(RecognizedText recognizedText) {
    final lines = <_TextLineInfo>[];
    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        final text = line.text.trim();
        if (text.isEmpty) {
          continue;
        }
        lines.add(_TextLineInfo(text: text, rect: line.boundingBox));
      }
    }

    lines.sort((a, b) {
      final yCompare = a.rect.top.compareTo(b.rect.top);
      if (yCompare != 0) {
        return yCompare;
      }
      return a.rect.left.compareTo(b.rect.left);
    });
    return lines;
  }

  List<MeetingCandidate> _meetingCandidates({
    required List<_TextLineInfo> textLines,
    required String imagePath,
    required int reminderOffsetMinutes,
  }) {
    final dateAnchors = _extractDateAnchors(textLines);
    final timeAnchors = _extractTimeAnchors(textLines);
    final lines = textLines
        .where((line) => _looksLikeMeetingLine(line, timeAnchors))
        .take(20)
        .toList();

    if (lines.isEmpty) {
      return [
        MeetingCandidate(
          title: 'Untitled meeting',
          startsAt: DateTime.now().add(const Duration(hours: 1)),
          reminderOffsetMinutes: reminderOffsetMinutes,
          sourceImagePath: imagePath,
          confidence: 0.1,
          reason: 'OCR did not find clear meeting text.',
          selected: false,
        ),
      ];
    }

    final candidates = <MeetingCandidate>[];
    for (var index = 0; index < lines.length; index += 1) {
      final line = lines[index];
      final startsAt = _inferStartTime(
        line: line,
        dateAnchors: dateAnchors,
        timeAnchors: timeAnchors,
      );
      final hasCalendarAnchors =
          dateAnchors.isNotEmpty && timeAnchors.isNotEmpty;
      final inferredStart = hasCalendarAnchors
          ? startsAt
          : DateTime.now().add(Duration(hours: index + 1));

      candidates.add(
        MeetingCandidate(
          title: _cleanMeetingTitle(line.text),
          startsAt: inferredStart,
          reminderOffsetMinutes: reminderOffsetMinutes,
          sourceImagePath: imagePath,
          confidence: hasCalendarAnchors ? 0.62 : 0.32,
          reason: hasCalendarAnchors
              ? 'Detected from OCR and calendar grid position.'
              : 'Detected from OCR text; time is estimated.',
          selected: false,
        ),
      );
    }

    return _deduplicateCandidates(candidates);
  }

  List<MeetingCandidate> _meetingCandidatesFromEventBlocks({
    required List<_EventBlock> eventBlocks,
    required List<_TextLineInfo> textLines,
    required String imagePath,
    required int reminderOffsetMinutes,
  }) {
    final dateAnchors = _extractDateAnchors(textLines);
    final timeAnchors = _extractTimeAnchors(textLines);
    final candidates = <MeetingCandidate>[];

    for (final block in eventBlocks) {
      final titleLine = _bestTitleLine(block.lines, timeAnchors);
      final title = _cleanMeetingTitle(titleLine.text);
      if (title.isEmpty || _looksLikeNonEventLine(title)) {
        continue;
      }

      final startsAt = _inferStartTimeFromRect(
        rect: block.rect,
        dateAnchors: dateAnchors,
        timeAnchors: timeAnchors,
        eventLines: block.lines,
      );
      final hasExplicitTime = _minutesFromEventLines(block.lines) != null;
      candidates.add(
        MeetingCandidate(
          title: title,
          startsAt: startsAt,
          reminderOffsetMinutes: reminderOffsetMinutes,
          sourceImagePath: imagePath,
          confidence: hasExplicitTime ? 0.88 : 0.72,
          reason: hasExplicitTime
              ? 'Detected from OCR grouped inside a calendar event block. Time was read from event text.'
              : 'Detected from OCR grouped inside a calendar event block. Time was inferred from calendar position.',
          selected: false,
        ),
      );
    }

    return _deduplicateCandidates(candidates);
  }

  _TextLineInfo _bestTitleLine(
    List<_TextLineInfo> lines,
    List<_TimeAnchor> timeAnchors,
  ) {
    final titleLines = lines
        .where((line) => _looksLikeMeetingLine(line, timeAnchors))
        .toList();
    if (titleLines.isEmpty) {
      return lines.first;
    }

    titleLines.sort((a, b) {
      return _titleScore(_cleanMeetingTitle(b.text))
          .compareTo(_titleScore(_cleanMeetingTitle(a.text)));
    });
    return titleLines.first;
  }

  int _titleScore(String title) {
    final normalized = title.toLowerCase();
    var score = min(title.length, 80);
    if (_strongTitleWordPattern().hasMatch(normalized)) {
      score += 40;
    }
    if (RegExp(r'^\d').hasMatch(normalized)) {
      score -= 20;
    }
    if (RegExp(r'[/\\:_]').hasMatch(normalized)) {
      score -= 15;
    }
    return score;
  }

  DateTime _inferStartTime({
    required _TextLineInfo line,
    required List<_DateAnchor> dateAnchors,
    required List<_TimeAnchor> timeAnchors,
  }) {
    final date = _closestDateFor(line.rect.center.dx, dateAnchors);
    final minutes = _roundToNearestInterval(
      _minutesForY(line.rect.center.dy, timeAnchors),
      15,
    );
    final fallback = DateTime.now().add(const Duration(hours: 1));

    if (date == null || minutes == null) {
      return DateTime(
        fallback.year,
        fallback.month,
        fallback.day,
        fallback.hour,
        (fallback.minute ~/ 15) * 15,
      );
    }

    return DateTime(
      date.year,
      date.month,
      date.day,
      minutes ~/ 60,
      minutes % 60,
    );
  }

  DateTime _inferStartTimeFromRect({
    required Rect rect,
    required List<_DateAnchor> dateAnchors,
    required List<_TimeAnchor> timeAnchors,
    List<_TextLineInfo> eventLines = const [],
  }) {
    final date = _closestDateFor(rect.center.dx, dateAnchors);
    final explicitMinutes = _minutesFromEventLines(eventLines);
    final minutes = explicitMinutes ??
        _roundToNearestInterval(
          _minutesForY(rect.top + min(10, rect.height * 0.2), timeAnchors),
          15,
        );
    final fallback = DateTime.now().add(const Duration(hours: 1));

    if (date == null || minutes == null) {
      return DateTime(
        fallback.year,
        fallback.month,
        fallback.day,
        fallback.hour,
        (fallback.minute ~/ 15) * 15,
      );
    }

    return DateTime(
      date.year,
      date.month,
      date.day,
      minutes ~/ 60,
      minutes % 60,
    );
  }

  DateTime? _closestDateFor(double x, List<_DateAnchor> anchors) {
    if (anchors.isEmpty) {
      return null;
    }
    anchors.sort((a, b) => (a.x - x).abs().compareTo((b.x - x).abs()));
    return anchors.first.date;
  }

  int? _minutesForY(double y, List<_TimeAnchor> anchors) {
    if (anchors.isEmpty) {
      return null;
    }

    anchors.sort((a, b) => a.y.compareTo(b.y));
    for (var i = 0; i < anchors.length - 1; i += 1) {
      final top = anchors[i];
      final bottom = anchors[i + 1];
      if (y >= top.y && y <= bottom.y && bottom.y != top.y) {
        final progress = (y - top.y) / (bottom.y - top.y);
        return (top.minutes + (bottom.minutes - top.minutes) * progress)
            .round();
      }
    }

    final closest = anchors.reduce(
      (a, b) => (a.y - y).abs() < (b.y - y).abs() ? a : b,
    );
    return closest.minutes;
  }

  int? _roundToNearestInterval(int? minutes, int interval) {
    if (minutes == null) {
      return null;
    }

    return ((minutes / interval).round() * interval).clamp(0, 23 * 60 + 59);
  }

  List<_DateAnchor> _extractDateAnchors(List<_TextLineInfo> lines) {
    final candidates = <_DateAnchorCandidate>[];
    final calendarYear = _extractCalendarYear(lines);
    final calendarMonth = _extractCalendarMonth(lines);
    for (final line in lines) {
      candidates.addAll(_dateAnchorCandidatesFromLine(line, calendarYear));
    }
    candidates.addAll(
      _dateAnchorCandidatesFromSplitWeekHeaders(
        lines,
        calendarYear,
        calendarMonth,
      ),
    );

    if (candidates.isEmpty) {
      return [];
    }

    final groups = <List<_DateAnchorCandidate>>[];
    for (final candidate in candidates) {
      final index = groups.indexWhere((group) {
        final averageY =
            group.map((item) => item.y).reduce((a, b) => a + b) / group.length;
        return (averageY - candidate.y).abs() < 30;
      });
      if (index == -1) {
        groups.add([candidate]);
      } else {
        groups[index].add(candidate);
      }
    }

    groups.sort((a, b) {
      final countCompare = b.length.compareTo(a.length);
      if (countCompare != 0) {
        return countCompare;
      }
      final spreadA = a.map((item) => item.x).reduce(max) -
          a.map((item) => item.x).reduce(min);
      final spreadB = b.map((item) => item.x).reduce(max) -
          b.map((item) => item.x).reduce(min);
      return spreadB.compareTo(spreadA);
    });

    final bestGroup = groups.first;
    return bestGroup
        .map((candidate) => _DateAnchor(x: candidate.x, date: candidate.date))
        .toList()
      ..sort((a, b) => a.x.compareTo(b.x));
  }

  List<_DateAnchorCandidate> _dateAnchorCandidatesFromSplitWeekHeaders(
    List<_TextLineInfo> lines,
    int? calendarYear,
    int? calendarMonth,
  ) {
    if (calendarMonth == null) {
      return [];
    }

    final weekdayLines = lines.where((line) {
      return RegExp(
        r'^(monday|tuesday|wednesday|thursday|friday|saturday|sunday)$',
        caseSensitive: false,
      ).hasMatch(line.text.trim());
    }).toList();
    final dayLines = lines.where((line) {
      final day = int.tryParse(line.text.trim());
      return day != null && day >= 1 && day <= 31;
    }).toList();

    final candidates = <_DateAnchorCandidate>[];
    for (final weekdayLine in weekdayLines) {
      final nearbyDays = dayLines.where((dayLine) {
        final xDistance =
            (dayLine.rect.center.dx - weekdayLine.rect.center.dx).abs();
        final yDistance = dayLine.rect.top - weekdayLine.rect.bottom;
        return xDistance <= max(45, weekdayLine.rect.width * 0.55) &&
            yDistance >= -8 &&
            yDistance <= 70;
      }).toList()
        ..sort((a, b) {
          final aDistance =
              (a.rect.center.dx - weekdayLine.rect.center.dx).abs() +
                  (a.rect.top - weekdayLine.rect.bottom).abs();
          final bDistance =
              (b.rect.center.dx - weekdayLine.rect.center.dx).abs() +
                  (b.rect.top - weekdayLine.rect.bottom).abs();
          return aDistance.compareTo(bDistance);
        });

      if (nearbyDays.isEmpty) {
        continue;
      }

      final day = int.parse(nearbyDays.first.text.trim());
      candidates.add(
        _DateAnchorCandidate(
          x: weekdayLine.rect.center.dx,
          y: weekdayLine.rect.center.dy,
          date: _dateForMonthDay(calendarMonth, day, calendarYear),
        ),
      );
    }

    return candidates;
  }

  List<_DateAnchorCandidate> _dateAnchorCandidatesFromLine(
    _TextLineInfo line,
    int? calendarYear,
  ) {
    final text = line.text.trim();
    if (text.isEmpty) {
      return [];
    }

    final candidates = <_DateAnchorCandidate>[];
    final tokenPattern = RegExp(
      r'\b(sun|mon|tue|wed|thu|fri|sat)\w*\s+([01]?\d)[/-]([0-3]?\d)\b',
      caseSensitive: false,
    );
    final matches = tokenPattern.allMatches(text).toList();
    if (matches.length >= 2) {
      for (final match in matches) {
        final month = int.tryParse(match.group(2) ?? '');
        final day = int.tryParse(match.group(3) ?? '');
        if (month == null ||
            day == null ||
            month < 1 ||
            month > 12 ||
            day < 1 ||
            day > 31) {
          continue;
        }

        candidates.add(
          _DateAnchorCandidate(
            x: _xForTextRange(line.rect, text.length, match.start, match.end),
            y: line.rect.center.dy,
            date: _dateForMonthDay(month, day, calendarYear),
          ),
        );
      }
      return candidates;
    }

    final date = _dateFromWeekHeader(text, calendarYear);
    if (date == null) {
      return [];
    }

    return [
      _DateAnchorCandidate(
        x: line.rect.center.dx,
        y: line.rect.center.dy,
        date: date,
      ),
    ];
  }

  DateTime? _dateFromWeekHeader(String text, int? calendarYear) {
    final normalized = text.toLowerCase();
    final weekdayPattern =
        RegExp(r'\b(mon|tue|wed|thu|fri|sat|sun)\w*\b', caseSensitive: false);
    if (!weekdayPattern.hasMatch(normalized)) {
      return null;
    }

    final now = DateTime.now();
    final numericDateMatch =
        RegExp(r'\b([01]?\d)[/-]([0-3]?\d)\b').firstMatch(normalized);
    var month = numericDateMatch == null
        ? null
        : int.tryParse(numericDateMatch.group(1)!);
    var day = numericDateMatch == null
        ? null
        : int.tryParse(numericDateMatch.group(2)!);

    final monthMatch = RegExp(
      r'\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)\w*\b',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (monthMatch != null) {
      month = _monthNumber(monthMatch.group(1)!);
    }

    day ??= int.tryParse(
        RegExp(r'\b([1-3]?\d)\b').firstMatch(normalized)?.group(1) ?? '');
    month ??= now.month;
    if (day == null || month < 1 || month > 12 || day < 1 || day > 31) {
      return null;
    }

    return _dateForMonthDay(month, day, calendarYear);
  }

  DateTime _dateForMonthDay(int month, int day, int? calendarYear) {
    final now = DateTime.now();
    var date = DateTime(calendarYear ?? now.year, month, day);
    if (calendarYear == null && date.difference(now).inDays < -180) {
      date = DateTime(now.year + 1, month, day);
    }
    return date;
  }

  int? _extractCalendarYear(List<_TextLineInfo> lines) {
    for (final line in lines) {
      final match = RegExp(r'\b(20\d{2})\b').firstMatch(line.text);
      final year = int.tryParse(match?.group(1) ?? '');
      if (year != null && year >= 2000 && year <= 2100) {
        return year;
      }
    }
    return null;
  }

  int? _extractCalendarMonth(List<_TextLineInfo> lines) {
    for (final line in lines) {
      final match = RegExp(
        r'\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)\w*\b',
        caseSensitive: false,
      ).firstMatch(line.text);
      if (match == null) {
        continue;
      }
      return _monthNumber(match.group(1)!.toLowerCase());
    }
    return null;
  }

  List<_TimeAnchor> _extractTimeAnchors(List<_TextLineInfo> lines) {
    final candidates = <_TimeAnchorCandidate>[];

    for (final line in lines) {
      candidates.addAll(_timeAnchorCandidatesFromLine(line));
    }

    if (candidates.isEmpty) {
      return [];
    }

    final groups = <List<_TimeAnchorCandidate>>[];
    for (final candidate in candidates) {
      final index = groups.indexWhere((group) {
        final averageX =
            group.map((item) => item.x).reduce((a, b) => a + b) / group.length;
        return (averageX - candidate.x).abs() < 35;
      });
      if (index == -1) {
        groups.add([candidate]);
      } else {
        groups[index].add(candidate);
      }
    }

    groups.sort((a, b) {
      final rangeA = a.map((item) => item.y).reduce(max) -
          a.map((item) => item.y).reduce(min);
      final rangeB = b.map((item) => item.y).reduce(max) -
          b.map((item) => item.y).reduce(min);
      final scoreA = a.length * 1000 + rangeA - _averageX(a) * 0.2;
      final scoreB = b.length * 1000 + rangeB - _averageX(b) * 0.2;
      return scoreB.compareTo(scoreA);
    });

    return groups.first
        .map((candidate) =>
            _TimeAnchor(y: candidate.y, minutes: candidate.minutes))
        .toList()
      ..sort((a, b) => a.y.compareTo(b.y));
  }

  List<_TimeAnchorCandidate> _timeAnchorCandidatesFromLine(
    _TextLineInfo line,
  ) {
    final text = line.text.trim();
    if (text.isEmpty) {
      return [];
    }

    final exactMatch = RegExp(
      r'^([01]?\d|2[0-3])(?::([0-5]\d))?\s*(am|pm)?$',
      caseSensitive: false,
    ).firstMatch(text);
    if (exactMatch != null) {
      final minutes = _minutesFromTimeMatch(exactMatch);
      if (minutes == null) {
        return [];
      }
      return [
        _TimeAnchorCandidate(
          x: line.rect.center.dx,
          y: line.rect.center.dy,
          minutes: minutes,
        ),
      ];
    }

    final matches = RegExp(
      r'\b([01]?\d|2[0-3])(?::([0-5]\d))?\s*(am|pm)\b',
      caseSensitive: false,
    ).allMatches(text);

    return matches
        .map((match) {
          final minutes = _minutesFromTimeMatch(match);
          if (minutes == null) {
            return null;
          }
          return _TimeAnchorCandidate(
            x: _xForTextRange(line.rect, text.length, match.start, match.end),
            y: line.rect.center.dy,
            minutes: minutes,
          );
        })
        .whereType<_TimeAnchorCandidate>()
        .toList();
  }

  int? _minutesFromTimeMatch(RegExpMatch match) {
    var hour = int.tryParse(match.group(1) ?? '');
    final minute = int.tryParse(match.group(2) ?? '0') ?? 0;
    final meridiem = match.group(3)?.toLowerCase();
    if (hour == null) {
      return null;
    }
    if (meridiem == 'pm' && hour < 12) {
      hour += 12;
    }
    if (meridiem == 'am' && hour == 12) {
      hour = 0;
    }
    return hour * 60 + minute;
  }

  int? _minutesFromEventLines(List<_TextLineInfo> lines) {
    for (final line in lines) {
      final match = RegExp(
        r'\b([01]?\d|2[0-3])(?::([0-5]\d))?\s*(am|pm)\b',
        caseSensitive: false,
      ).firstMatch(line.text);
      if (match == null) {
        continue;
      }
      final minutes = _minutesFromTimeMatch(match);
      if (minutes != null) {
        return minutes;
      }
    }
    return null;
  }

  double _xForTextRange(Rect rect, int textLength, int start, int end) {
    if (textLength <= 0 || rect.width <= 0) {
      return rect.center.dx;
    }
    final centerIndex = (start + end) / 2;
    final progress = (centerIndex / textLength).clamp(0.0, 1.0);
    return rect.left + rect.width * progress;
  }

  double _averageX(List<_TimeAnchorCandidate> candidates) {
    return candidates.map((item) => item.x).reduce((a, b) => a + b) /
        candidates.length;
  }

  bool _looksLikeMeetingLine(
    _TextLineInfo line,
    List<_TimeAnchor> timeAnchors,
  ) {
    final text = _cleanMeetingTitle(line.text);
    final normalized = text.toLowerCase();
    if (_looksLikeHeaderOrTime(text)) {
      return false;
    }
    if (_looksLikeCalendarHeader(text)) {
      return false;
    }
    if (_looksLikeDurationLabel(text)) {
      return false;
    }
    if (!RegExp(r'[a-zA-Z]').hasMatch(text)) {
      return false;
    }
    if (text.length < 3 || text.length > 90) {
      return false;
    }

    final blockedWords = RegExp(
      r'\b(calendar|today|search|meet now|new event|work week|week|month|day|all day|gmt|utc|outlook|microsoft|teams|join|dismiss|snooze|settings)\b',
      caseSensitive: false,
    );
    if (blockedWords.hasMatch(normalized)) {
      return false;
    }

    if (timeAnchors.length >= 2) {
      final top = timeAnchors.map((anchor) => anchor.y).reduce(min);
      final bottom = timeAnchors.map((anchor) => anchor.y).reduce(max);
      final insideTimeGrid =
          line.rect.center.dy >= top - 40 && line.rect.center.dy <= bottom + 80;
      if (!insideTimeGrid) {
        return false;
      }
    }

    return true;
  }

  bool _looksLikeDurationLabel(String text) {
    return RegExp(
      r'^\d+(\.\d+)?\s*(min|mins|minute|minutes|hr|hrs|hour|hours)$',
      caseSensitive: false,
    ).hasMatch(text.trim());
  }

  bool _looksLikeNonEventLine(String text) {
    return _looksLikeHeaderOrTime(text) ||
        _looksLikeCalendarHeader(text) ||
        _looksLikeDurationLabel(text);
  }

  bool _looksLikeCalendarHeader(String text) {
    final normalized = text.trim().toLowerCase();
    if (normalized.isEmpty) {
      return true;
    }

    final compact = normalized.replaceAll(RegExp(r'[\s,./-]+'), ' ');
    if (RegExp(
      r'^(mo|mon|tu|tue|we|wed|th|thu|fr|fri|sa|sat|su|sun)(\s+(mo|mon|tu|tue|we|wed|th|thu|fr|fri|sa|sat|su|sun)){1,6}$',
    ).hasMatch(compact)) {
      return true;
    }

    if (RegExp(
      r'^(mon|tue|wed|thu|fri|sat|sun)\w*\s+\d{1,2}([/-]\d{1,2})?$',
      caseSensitive: false,
    ).hasMatch(text.trim())) {
      return true;
    }

    if (RegExp(
      r'^\d{1,2}([/-]\d{1,2})?(\s+\d{1,2}([/-]\d{1,2})?){1,6}$',
    ).hasMatch(compact)) {
      return true;
    }

    return false;
  }

  List<MeetingCandidate> _deduplicateCandidates(
    List<MeetingCandidate> candidates,
  ) {
    final unique = <MeetingCandidate>[];
    for (final candidate in candidates) {
      final exists = unique.any((item) {
        return item.title.toLowerCase() == candidate.title.toLowerCase() &&
            item.startsAt.difference(candidate.startsAt).inMinutes.abs() < 10;
      });
      if (!exists) {
        unique.add(candidate);
      }
    }
    return unique;
  }

  List<MeetingCandidate> _filterCandidates(List<MeetingCandidate> candidates) {
    return candidates.where((candidate) {
      final title = _cleanMeetingTitle(candidate.title);
      candidate.title = title;
      return title.isNotEmpty && !_looksLikeNonEventLine(title);
    }).toList();
  }

  String _cleanMeetingTitle(String text) {
    final cleaned = text
        .replaceAll(RegExp(r'https?://\S+', caseSensitive: false), '')
        .replaceAll(_fuzzyUrlSuffixPattern(), '')
        .replaceAll(_fuzzyMeetingPlatformSuffixPattern(), '')
        .replaceAll(_leadingAttachedTimePattern(), '')
        .replaceAll(_outlookContinuationPattern(), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[\-\u2022\*\s]+'), '')
        .replaceAll(RegExp(r'[;,\s]+$'), '')
        .trim();
    return _normalizeCommonOcrWords(cleaned);
  }

  bool _looksLikeHeaderOrTime(String text) {
    final trimmed = text.trim();
    if (trimmed.length <= 2) {
      return true;
    }
    if (_outlookContinuationPattern().hasMatch(trimmed)) {
      return true;
    }
    return RegExp(
      r'^(mon|tue|wed|thu|fri|sat|sun|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|\d{1,2}(:\d{2})?\s*(am|pm)?)$',
      caseSensitive: false,
    ).hasMatch(trimmed);
  }

  RegExp _outlookContinuationPattern() {
    return RegExp(
      r'\bto\s+(jan|feb|mar|apr|may|jun|jn|jul|aug|sep|sept|oct|nov|dec)\w*\.?\s+\d{1,2}\s*[-\u2013\u2014>]?\s*$',
      caseSensitive: false,
    );
  }

  RegExp _leadingAttachedTimePattern() {
    return RegExp(
      r'^\s*\d{1,2}\s*(?::\s*\d{2})?\s*(a\.?m\.?|p\.?m\.?)\s*',
      caseSensitive: false,
    );
  }

  RegExp _fuzzyMeetingPlatformSuffixPattern() {
    return RegExp(
      r'\b(microsoft\s+teams?|microsoft|microso[l1]|microst|mierosoft|microsol|teamal|zoom|zoo?m)\b.*$',
      caseSensitive: false,
    );
  }

  RegExp _fuzzyUrlSuffixPattern() {
    return RegExp(
      r'\b(h?t?t?p?s?|hps|tps|ttps|titps|itps)[/:;][^\s]*.*$',
      caseSensitive: false,
    );
  }

  RegExp _strongTitleWordPattern() {
    return RegExp(
      r'\b(meeting|stand[- ]?up|review|discussion|sync|touch|base|check[- ]?in|office|hours|board|deck|weekly|daily|okr|sourcing|legal|coreops|workshop|tracker)\b',
      caseSensitive: false,
    );
  }

  String _normalizeCommonOcrWords(String text) {
    return text
        .replaceAll(RegExp(r'\bDeily\b', caseSensitive: false), 'Daily')
        .replaceAll(RegExp(r'\bWokly\b', caseSensitive: false), 'Weekly')
        .replaceAll(RegExp(r'\breganding\b', caseSensitive: false), 'regarding')
        .replaceAll(RegExp(r'\bche?dk\b', caseSensitive: false), 'check')
        .replaceAll(RegExp(r'\bComplek\b', caseSensitive: false), 'Complex')
        .replaceAll(RegExp(r'\bweekh\b', caseSensitive: false), 'weekly')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[;,\s]+$'), '')
        .trim();
  }

  Rect _expanded(Rect rect, double amount) {
    return Rect.fromLTRB(
      rect.left - amount,
      rect.top - amount,
      rect.right + amount,
      rect.bottom + amount,
    );
  }

  int? _monthNumber(String month) {
    const months = {
      'jan': 1,
      'feb': 2,
      'mar': 3,
      'apr': 4,
      'may': 5,
      'jun': 6,
      'jul': 7,
      'aug': 8,
      'sep': 9,
      'sept': 9,
      'oct': 10,
      'nov': 11,
      'dec': 12,
    };
    return months[month.substring(0, min(month.length, 4))] ??
        months[month.substring(0, min(month.length, 3))];
  }

  String _formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  String _formatTime(DateTime date) {
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class _TextLineInfo {
  const _TextLineInfo({required this.text, required this.rect});

  final String text;
  final Rect rect;
}

class _EventBlock {
  const _EventBlock({required this.rect, required this.lines});

  final Rect rect;
  final List<_TextLineInfo> lines;
}

class _ColorCluster {
  const _ColorCluster({required this.rect, required this.count});

  final Rect rect;
  final int count;
}

class _DateAnchor {
  const _DateAnchor({required this.x, required this.date});

  final double x;
  final DateTime date;
}

class _DateAnchorCandidate {
  const _DateAnchorCandidate({
    required this.x,
    required this.y,
    required this.date,
  });

  final double x;
  final double y;
  final DateTime date;
}

class _TimeAnchor {
  const _TimeAnchor({required this.y, required this.minutes});

  final double y;
  final int minutes;
}

class _TimeAnchorCandidate {
  const _TimeAnchorCandidate({
    required this.x,
    required this.y,
    required this.minutes,
  });

  final double x;
  final double y;
  final int minutes;
}
