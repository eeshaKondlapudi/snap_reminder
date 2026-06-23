# SnapReminder

SnapReminder is a Flutter app for saving meeting and task alarms from quick phrases, Outlook shared-calendar links, and experimental Outlook calendar screenshot scanning.

## Current App

The active app shell has three tabs:

- **Home**: Shows saved upcoming reminders, lets you delete them, and supports typed or dictated reminders such as `at 6:30, go get groceries`.
- **Outlook**: Loads a week of events from an Outlook shared calendar link and lets you star events to schedule alarms.
- **Settings**: Configures the default reminder offset and reminder style.

Local alarms are scheduled with `flutter_local_notifications`. Saved reminders are stored in SQLite through `sqflite`, and settings are stored with `shared_preferences`.

## Feature Status

- Voice/manual reminder parsing is active on the Home tab.
- Outlook shared-calendar `.ics` link parsing is active on the Outlook tab.
- Microsoft Graph sign-in code exists in `lib/src/outlook/microsoft_calendar_service.dart`, but the client-ID settings field and sign-in button are currently hidden in the UI.
- Screenshot OCR scanning code still exists in `lib/src/ui/scan_screen.dart`, `lib/src/scan/`, and `server/`, but the Scan tab is currently commented out of `lib/src/app/snap_reminder_app.dart`.

## Requirements

- Flutter SDK compatible with Dart `>=3.4.0 <4.0.0`
- Xcode/CocoaPods for iOS builds
- Android Studio or an Android SDK/emulator for Android builds
- Node.js if you want to run the optional OCR parser server or web tester

## Run the App

Install Flutter packages:

```bash
flutter pub get
```

Run on an available device or simulator:

```bash
flutter run
```

Run on a specific Android emulator:

```bash
flutter run -d emulator-5554
```

## Install on an Android Phone

The easiest way to put the app on your own Android phone while developing is to connect the phone and run it from Flutter.

1. Enable Developer Options on the phone:
   - Open **Settings**.
   - Go to **About phone**.
   - Tap **Build number** 7 times.
   - Enter your PIN if Android asks.
   - Go back to **Settings** and open **Developer options**.
   - Turn on **USB debugging**.

2. Connect the phone to your computer:
   - Plug the phone in with a USB cable.
   - Approve the **Allow USB debugging?** popup on the phone.
   - If Android asks for a USB mode, choose **File transfer** or **MTP**.

3. Check that Flutter can see the phone:

```bash
flutter devices
```

4. Install packages:

```bash
flutter pub get
```

5. Build, install, and open the app on the phone:

```bash
flutter run
```

After the first install, SnapReminder should appear in the Android app drawer like a normal app.

To build an APK that can be copied to the phone manually:

```bash
flutter build apk --debug
```

The APK will be created at:

```text
build/app/outputs/flutter-apk/app-debug.apk
```

Send that file to the phone, open it, and allow **Install unknown apps** if Android asks.

## Test

```bash
flutter test
```

Current tests cover the voice reminder parser and the Home screen empty state.

## Platform Notes

Android permissions are configured for notifications, audio recording, exact alarms, full-screen alarm behavior, vibration, internet access, and boot recovery.

iOS permission text is configured for photo library, camera, microphone, and speech recognition access.

## Outlook Shared Calendar Flow

1. Open Outlook calendar sharing settings and copy a public/shared calendar link.
2. Open the Outlook tab in SnapReminder.
3. Paste the link into **Shared calendar link**.
4. Tap **Load shared link**.
5. Star any loaded event to save it as a local reminder using the current default reminder offset.

The week picker loads Monday through Sunday for the selected week and filters out events that have already ended.

## Optional Screenshot OCR Flow

The screenshot scanner is not active in the current navigation, but the code is still available for development. It uses ML Kit text recognition in the app and can call a local parser server for grouped OCR event blocks.

Start the local parser server:

```bash
node server/llama_ocr_parse_server.mjs
```

By default, the server uses a fast rule-based parser and does not require Ollama. To experiment with Llama cleanup, install Ollama, pull the default model, and enable cleanup:

```bash
ollama pull llama3.2:1b
OLLAMA_CLEANUP_ENABLED=true node server/llama_ocr_parse_server.mjs
```

Useful environment variables:

- `OCR_PARSE_PORT`: Parser server port. Defaults to `8788`.
- `HOST`: Parser server host. Defaults to `127.0.0.1`.
- `OLLAMA_MODEL`: Ollama model name. Defaults to `llama3.2:1b`.
- `OLLAMA_BASE_URL`: Ollama base URL. Defaults to `http://127.0.0.1:11434`.
- `OLLAMA_TIMEOUT_MS`: Ollama request timeout. Defaults to `60000`.
- `OLLAMA_CLEANUP_ENABLED`: Set to `true` to call Ollama when the fast parser does not find meetings.

## Web Tester

For faster laptop OCR extraction testing, open `web_tester/index.html` in a browser after starting the parser server. The web tester uses Tesseract.js in the browser, detects colored calendar event rectangles, groups OCR lines inside those rectangles, and posts grouped event blocks to the local parser server.

The web tester is only for extraction testing. It does not schedule alarms.

## Project Layout

- `lib/main.dart`: Flutter entry point.
- `lib/src/app/`: App shell and active tab wiring.
- `lib/src/ui/`: Home, Outlook, Settings, and inactive Scan screens.
- `lib/src/data/`: Models, repositories, SQLite reminder storage, and settings persistence.
- `lib/src/reminders/`: Local notification scheduling and cancellation.
- `lib/src/outlook/`: Microsoft Graph and shared-calendar event loading.
- `lib/src/voice/`: Dictation support and phrase-to-reminder parsing.
- `lib/src/scan/`: Screenshot OCR analysis and meeting candidate extraction.
- `server/`: Local OCR parser server.
- `web_tester/`: Browser-based OCR extraction tester.
- `test/`: Widget and parser tests.

## Next Useful Work

- Decide whether to restore the Scan tab or keep screenshot OCR as a separate experiment.
- Re-enable Microsoft Graph setup in Settings if direct Outlook sign-in is needed.
- Add tests for Outlook shared-calendar parsing and reminder scheduling edge cases.
