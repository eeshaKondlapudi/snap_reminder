# SnapReminder

SnapReminder is a Flutter app for turning Outlook week-calendar screenshots into saved meeting reminders on iOS and Android.

Current build slice:

- Flutter app shell
- Home, Scan, and Settings screens
- Local SQLite meeting storage through `sqflite`
- Settings storage through `shared_preferences`
- Screenshot selection through `image_picker`

## Why This Structure Exists

- `sqflite` stores meeting records because reminders need structured fields like title, date/time, and reminder offset.
- `shared_preferences` stores small settings such as the default reminder offset and alarm behavior.
- `image_picker` gives the app one cross-platform way to choose calendar screenshots from the photo library.
- `AppState` uses `ChangeNotifier` so the UI can refresh after meetings or settings change.

## First-Time Flutter Setup

This machine did not have the Flutter SDK available in the shell when the scaffold was created. After installing Flutter, run these commands from this folder:

```bash
flutter create --platforms=android,ios .
flutter pub get
flutter run
```

The first command generates the standard `android/` and `ios/` platform folders around the existing `lib/` source code.

## iOS Notes

After the platform folders are generated, the iOS app will need photo-library usage text in `ios/Runner/Info.plist` for screenshot picking.

## Next Build Slice

Improve the OCR meeting extraction accuracy with more real Outlook screenshots and richer test cases.

## OCR + Llama Scan Flow

The app uses on-device OCR through ML Kit, then can pass the OCR text lines to a local Ollama/Llama parser server to filter out calendar headers and keep real meetings.
By default the parser server now uses a fast OCR/event-rectangle parser and does not wait on Ollama. Set `OLLAMA_CLEANUP_ENABLED=true` in `.env` only when you want to experiment with Llama cleanup.

1. Pull the local Llama model. The `1b` model is much easier to run on a laptop and is the default used by the parser server:

```bash
ollama pull llama3.2:1b
```

2. Make sure Ollama is running, then start the local OCR parser server:

```bash
node server/llama_ocr_parse_server.mjs
```

3. Run the app on the Android emulator:

```bash
flutter run -d emulator-5554
```

4. In the app, go to Scan, choose a screenshot, and tap `Analyze`.

The scan screen lists each detected meeting with an empty star. Edit the title or time if needed, then tap the star to schedule an alarm using the default reminder offset.

If the local Llama parser is not running, the app falls back to its simpler OCR-only parser.

## Web Tester

For faster laptop testing, open `web_tester/index.html` in your browser. It uses browser OCR through Tesseract.js, detects colored calendar event rectangles, groups OCR lines inside those rectangles, then sends the grouped event blocks to the same local parser server:

```bash
node server/llama_ocr_parse_server.mjs
```

The web tester is only for extraction testing. It does not schedule alarms.
