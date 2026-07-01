import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snap_reminder/src/ui/home_screen.dart';

void main() {
  testWidgets('Home screen shows the empty reminder state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(
            meetings: const [],
            activeAlarmMeeting: null,
            onSaveMeeting: (_) async {},
            onDeleteMeeting: (_) async {},
            onSnoozeAlarm: () async {},
            onDismissAlarm: () async {},
          ),
        ),
      ),
    );

    expect(find.text('No reminders yet'), findsOneWidget);
    expect(find.text('Voice reminder'), findsOneWidget);
    expect(find.text('Type'), findsOneWidget);
    expect(find.text('Dictate'), findsOneWidget);
    expect(find.byIcon(Icons.event_available), findsOneWidget);
  });
}
