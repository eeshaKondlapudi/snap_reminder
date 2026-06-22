import AVFoundation
import Flutter
import Speech
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let dictationChannelName = "snap_reminder/dictation"
  private let audioEngine = AVAudioEngine()
  private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
  private var dictationChannel: FlutterMethodChannel?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var pendingSpeechResult: FlutterResult?
  private var silenceTimer: Timer?
  private var latestTranscript = ""

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "SnapReminderDictationPlugin")
    else {
      return
    }
    let channel = FlutterMethodChannel(
      name: dictationChannelName,
      binaryMessenger: registrar.messenger())
    dictationChannel = channel
    channel.setMethodCallHandler { [weak self] (
      call: FlutterMethodCall,
      result: @escaping FlutterResult
    ) in
      guard call.method == "listen" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.listenForSpeech(result: result)
    }
  }

  private func listenForSpeech(result: @escaping FlutterResult) {
    if pendingSpeechResult != nil {
      result(FlutterError(
        code: "busy",
        message: "Dictation is already listening.",
        details: nil))
      return
    }

    guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
      result(FlutterError(
        code: "unavailable",
        message: "Speech recognition is not available on this device.",
        details: nil))
      return
    }

    pendingSpeechResult = result
    requestSpeechPermission()
  }

  private func requestSpeechPermission() {
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      DispatchQueue.main.async {
        guard let self = self else { return }
        guard status == .authorized else {
          self.finishWithError(
            code: "permission_denied",
            message: "Speech recognition permission is required.")
          return
        }
        self.requestMicrophonePermission()
      }
    }
  }

  private func requestMicrophonePermission() {
    AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
      DispatchQueue.main.async {
        guard let self = self else { return }
        guard granted else {
          self.finishWithError(
            code: "permission_denied",
            message: "Microphone permission is required.")
          return
        }
        self.startSpeechRecognizer()
      }
    }
  }

  private func startSpeechRecognizer() {
    cleanupSpeechRecognizer()
    latestTranscript = ""

    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
      try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      finishWithError(code: "audio_session_failed", message: error.localizedDescription)
      return
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    recognitionRequest = request

    let inputNode = audioEngine.inputNode
    recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
      DispatchQueue.main.async {
        guard let self = self, self.pendingSpeechResult != nil else { return }

        if let transcript = result?.bestTranscription.formattedString.trimmingCharacters(
          in: .whitespacesAndNewlines), !transcript.isEmpty {
          self.latestTranscript = transcript
          self.dictationChannel?.invokeMethod("transcriptChanged", arguments: transcript)
          self.scheduleSilenceTimeout(seconds: result?.isFinal == true ? 0.1 : 1.6)
        }

        if result?.isFinal == true {
          self.finishWithSuccess(self.latestTranscript)
          return
        }

        if let error = error {
          self.finishWithError(code: "speech_error", message: error.localizedDescription)
        }
      }
    }

    let recordingFormat = inputNode.outputFormat(forBus: 0)
    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
      request.append(buffer)
    }

    do {
      audioEngine.prepare()
      try audioEngine.start()
      scheduleSilenceTimeout(seconds: 8)
    } catch {
      finishWithError(code: "start_failed", message: error.localizedDescription)
    }
  }

  private func scheduleSilenceTimeout(seconds: TimeInterval) {
    silenceTimer?.invalidate()
    silenceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      guard let self = self else { return }
      if self.latestTranscript.isEmpty {
        self.finishWithError(code: "speech_error", message: "No speech was heard.")
      } else {
        self.finishWithSuccess(self.latestTranscript)
      }
    }
  }

  private func finishWithSuccess(_ transcript: String) {
    guard let result = pendingSpeechResult else { return }
    cleanupSpeechRecognizer()
    pendingSpeechResult = nil
    result(transcript)
  }

  private func finishWithError(code: String, message: String) {
    guard let result = pendingSpeechResult else { return }
    cleanupSpeechRecognizer()
    pendingSpeechResult = nil
    result(FlutterError(code: code, message: message, details: nil))
  }

  private func cleanupSpeechRecognizer() {
    silenceTimer?.invalidate()
    silenceTimer = nil
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    audioEngine.inputNode.removeTap(onBus: 0)
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest = nil
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation)
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    cleanupSpeechRecognizer()
    pendingSpeechResult = nil
    super.applicationWillTerminate(application)
  }
}
