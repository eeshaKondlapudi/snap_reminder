import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_appauth/flutter_appauth.dart';

class MicrosoftCalendarService {
  MicrosoftCalendarService({
    HttpClient? httpClient,
  }) : httpClient = httpClient ?? HttpClient();

  static const redirectUri =
      'msauth://com.example.snap_reminder/iwckoFi05XXx3Da9T1NHxfqglac=';

  static const scopes = [
    'openid',
    'profile',
    'Calendars.Read',
  ];

  final HttpClient httpClient;
  final appAuth = const FlutterAppAuth();

  String? _accessToken;
  DateTime? _accessTokenExpiresAt;

  bool get hasValidToken {
    final expiresAt = _accessTokenExpiresAt;
    return _accessToken != null &&
        expiresAt != null &&
        expiresAt.isAfter(DateTime.now().add(const Duration(minutes: 2)));
  }

  Future<void> signIn(String clientId) async {
    if (clientId.trim().isEmpty) {
      throw const MicrosoftCalendarException(
        'Add your Azure Application client ID in Settings first.',
      );
    }

    try {
      final response = await appAuth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          clientId.trim(),
          redirectUri,
          scopes: scopes,
          serviceConfiguration: const AuthorizationServiceConfiguration(
            authorizationEndpoint:
                'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
            tokenEndpoint:
                'https://login.microsoftonline.com/common/oauth2/v2.0/token',
          ),
          promptValues: ['select_account'],
        ),
      );

      _accessToken = response.accessToken;
      final expiresAt = response.accessTokenExpirationDateTime;
      _accessTokenExpiresAt =
          expiresAt ?? DateTime.now().add(const Duration(hours: 1));
      if (_accessToken == null || _accessToken!.isEmpty) {
        throw const MicrosoftCalendarException(
          'Microsoft did not return an access token.',
        );
      }
    } on FlutterAppAuthUserCancelledException {
      throw const MicrosoftCalendarException(
          'Microsoft sign-in was cancelled.');
    } on FlutterAppAuthPlatformException catch (error) {
      throw MicrosoftCalendarException(
        error.platformErrorDetails.errorDescription ??
            error.message ??
            'Microsoft sign-in failed.',
      );
    } on TimeoutException {
      throw const MicrosoftCalendarException('Microsoft sign-in timed out.');
    }
  }

  Future<List<OutlookCalendarEvent>> fetchWeek({
    required String clientId,
    required DateTime weekStart,
  }) async {
    if (!hasValidToken) {
      await signIn(clientId);
    }

    final start = DateTime(weekStart.year, weekStart.month, weekStart.day);
    final end = start.add(const Duration(days: 7));
    final uri = Uri.https(
      'graph.microsoft.com',
      '/v1.0/me/calendarView',
      {
        'startDateTime': start.toUtc().toIso8601String(),
        'endDateTime': end.toUtc().toIso8601String(),
        r'$orderby': 'start/dateTime',
        r'$top': '100',
        r'$select': 'id,subject,start,end,isAllDay,location,webLink',
      },
    );
    final response = await _getJson(uri);
    final values = response['value'] as List<dynamic>? ?? [];
    return values
        .whereType<Map<String, dynamic>>()
        .map(OutlookCalendarEvent.fromJson)
        .where((event) => event.title.trim().isNotEmpty)
        .toList()
      ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
  }

  Future<List<OutlookCalendarEvent>> fetchSharedCalendarWeek({
    required Uri calendarUri,
    required DateTime weekStart,
  }) async {
    final body = await _withNetworkRetry(() async {
      final request = await httpClient.getUrl(calendarUri);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw MicrosoftCalendarException(
          'Could not load shared calendar link (${response.statusCode}).',
        );
      }
      return body;
    });
    return _parseIcsEvents(body, weekStart);
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final token = _accessToken;
    if (token == null) {
      throw const MicrosoftCalendarException('Sign in with Microsoft first.');
    }

    final body = await _withNetworkRetry(() async {
      final request = await httpClient.getUrl(uri);
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
        ..set('Prefer', 'outlook.timezone="UTC"');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final data = jsonDecode(body) as Map<String, dynamic>;
        throw MicrosoftCalendarException(
          (data['error'] as Map<String, dynamic>?)?['message'] as String? ??
              'Could not fetch Outlook calendar events.',
        );
      }
      return body;
    });
    final data = jsonDecode(body) as Map<String, dynamic>;
    return data;
  }

  Future<T> _withNetworkRetry<T>(Future<T> Function() request) async {
    SocketException? lastSocketError;
    for (var attempt = 0; attempt < 3; attempt += 1) {
      try {
        return await request().timeout(const Duration(seconds: 30));
      } on SocketException catch (error) {
        lastSocketError = error;
        await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      } on TimeoutException {
        if (attempt == 2) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }

    throw MicrosoftCalendarException(
      'Could not reach Microsoft login. Check Wi-Fi/mobile data, then try again. '
      'Details: ${lastSocketError?.message ?? 'network timeout'}',
    );
  }

  List<OutlookCalendarEvent> _parseIcsEvents(String body, DateTime weekStart) {
    final start = DateTime(weekStart.year, weekStart.month, weekStart.day);
    final end = start.add(const Duration(days: 7));
    final unfolded = body.replaceAll(RegExp(r'\r?\n[ \t]'), '');
    final lines = unfolded
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final events = <OutlookCalendarEvent>[];
    Map<String, String>? current;
    for (final line in lines) {
      if (line == 'BEGIN:VEVENT') {
        current = {};
        continue;
      }
      if (line == 'END:VEVENT') {
        final event = _eventFromIcsFields(current);
        if (event != null &&
            event.startsAt.isBefore(end) &&
            event.endsAt.isAfter(start)) {
          events.add(event);
        }
        current = null;
        continue;
      }
      if (current == null) {
        continue;
      }
      final separator = line.indexOf(':');
      if (separator <= 0) {
        continue;
      }
      final name = line.substring(0, separator).split(';').first.toUpperCase();
      current[name] = line.substring(separator + 1);
    }

    return events..sort((a, b) => a.startsAt.compareTo(b.startsAt));
  }

  OutlookCalendarEvent? _eventFromIcsFields(Map<String, String>? fields) {
    if (fields == null) {
      return null;
    }
    final startsAt = _parseIcsDate(fields['DTSTART']);
    if (startsAt == null) {
      return null;
    }
    final endsAt = _parseIcsDate(fields['DTEND']) ??
        startsAt.add(const Duration(minutes: 30));
    return OutlookCalendarEvent(
      id: _unescapeIcsText(fields['UID'] ?? '${fields['SUMMARY']}$startsAt'),
      title: OutlookCalendarEvent._cleanTitle(
        _unescapeIcsText(fields['SUMMARY'] ?? 'Untitled event'),
      ),
      startsAt: startsAt,
      endsAt: endsAt,
      isAllDay: fields['DTSTART']?.length == 8,
      location: _unescapeIcsText(fields['LOCATION'] ?? ''),
      webLink: '',
    );
  }

  DateTime? _parseIcsDate(String? rawValue) {
    if (rawValue == null || rawValue.trim().isEmpty) {
      return null;
    }
    final raw = rawValue.trim();
    final dateMatch = RegExp(r'^(\d{4})(\d{2})(\d{2})$').firstMatch(raw);
    if (dateMatch != null) {
      return DateTime(
        int.parse(dateMatch.group(1)!),
        int.parse(dateMatch.group(2)!),
        int.parse(dateMatch.group(3)!),
      );
    }
    final dateTimeMatch = RegExp(
      r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$',
    ).firstMatch(raw);
    if (dateTimeMatch == null) {
      return null;
    }
    final parsed = DateTime(
      int.parse(dateTimeMatch.group(1)!),
      int.parse(dateTimeMatch.group(2)!),
      int.parse(dateTimeMatch.group(3)!),
      int.parse(dateTimeMatch.group(4)!),
      int.parse(dateTimeMatch.group(5)!),
      int.parse(dateTimeMatch.group(6)!),
    );
    if (dateTimeMatch.group(7) == 'Z') {
      return DateTime.utc(
        parsed.year,
        parsed.month,
        parsed.day,
        parsed.hour,
        parsed.minute,
        parsed.second,
      ).toLocal();
    }
    return parsed;
  }

  String _unescapeIcsText(String value) {
    return value
        .replaceAll(r'\n', ' ')
        .replaceAll(r'\N', ' ')
        .replaceAll(r'\,', ',')
        .replaceAll(r'\;', ';')
        .replaceAll(r'\\', r'\')
        .trim();
  }
}

class OutlookCalendarEvent {
  const OutlookCalendarEvent({
    required this.id,
    required this.title,
    required this.startsAt,
    required this.endsAt,
    required this.isAllDay,
    required this.location,
    required this.webLink,
  });

  final String id;
  final String title;
  final DateTime startsAt;
  final DateTime endsAt;
  final bool isAllDay;
  final String location;
  final String webLink;

  factory OutlookCalendarEvent.fromJson(Map<String, dynamic> json) {
    return OutlookCalendarEvent(
      id: json['id'] as String? ?? '',
      title: _cleanTitle(json['subject'] as String? ?? 'Untitled event'),
      startsAt: _parseGraphDateTime(json['start'] as Map<String, dynamic>?),
      endsAt: _parseGraphDateTime(json['end'] as Map<String, dynamic>?),
      isAllDay: json['isAllDay'] as bool? ?? false,
      location: ((json['location'] as Map<String, dynamic>?)?['displayName']
                  as String? ??
              '')
          .trim(),
      webLink: (json['webLink'] as String? ?? '').trim(),
    );
  }

  static DateTime _parseGraphDateTime(Map<String, dynamic>? value) {
    final raw = value?['dateTime'] as String?;
    if (raw == null || raw.trim().isEmpty) {
      return DateTime.now();
    }
    final normalized = raw.endsWith('Z') ? raw : '${raw}Z';
    return DateTime.parse(normalized).toLocal();
  }

  static String _cleanTitle(String title) {
    return title
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[;,\s]+$'), '')
        .trim();
  }
}

class MicrosoftCalendarException implements Exception {
  const MicrosoftCalendarException(this.message);

  final String message;

  @override
  String toString() => message;
}
