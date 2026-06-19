package com.example.snap_reminder

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val dictationChannelName = "snap_reminder/dictation"
    private val audioPermissionRequestCode = 6301
    private var pendingSpeechResult: MethodChannel.Result? = null
    private var speechRecognizer: SpeechRecognizer? = null
    private var dictationChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        dictationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            dictationChannelName
        )
        dictationChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "listen" -> listenForSpeech(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun listenForSpeech(result: MethodChannel.Result) {
        if (pendingSpeechResult != null) {
            result.error("busy", "Dictation is already listening.", null)
            return
        }

        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            result.error("unavailable", "Speech recognition is not available on this device.", null)
            return
        }

        pendingSpeechResult = result
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.RECORD_AUDIO),
                audioPermissionRequestCode
            )
            return
        }

        startSpeechRecognizer()
    }

    private fun startSpeechRecognizer() {
        val result = pendingSpeechResult ?: return
        speechRecognizer?.destroy()
        speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this)

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
            )
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PROMPT, "Say your reminder")
        }

        speechRecognizer?.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) = Unit
            override fun onBeginningOfSpeech() = Unit
            override fun onRmsChanged(rmsdB: Float) = Unit
            override fun onBufferReceived(buffer: ByteArray?) = Unit
            override fun onEndOfSpeech() = Unit
            override fun onPartialResults(partialResults: Bundle?) {
                val matches = partialResults
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val transcript = matches?.firstOrNull()?.trim().orEmpty()
                if (transcript.isNotEmpty()) {
                    dictationChannel?.invokeMethod("transcriptChanged", transcript)
                }
            }
            override fun onEvent(eventType: Int, params: Bundle?) = Unit

            override fun onError(error: Int) {
                finishWithError(error)
            }

            override fun onResults(results: Bundle?) {
                val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val transcript = matches?.firstOrNull()?.trim().orEmpty()
                if (transcript.isNotEmpty()) {
                    dictationChannel?.invokeMethod("transcriptChanged", transcript)
                }
                finishWithSuccess(transcript)
            }
        })

        try {
            speechRecognizer?.startListening(intent)
        } catch (error: Exception) {
            cleanupSpeechRecognizer()
            pendingSpeechResult = null
            result.error("start_failed", error.localizedMessage, null)
        }
    }

    private fun finishWithSuccess(transcript: String) {
        val result = pendingSpeechResult ?: return
        cleanupSpeechRecognizer()
        pendingSpeechResult = null
        result.success(transcript)
    }

    private fun finishWithError(error: Int) {
        val result = pendingSpeechResult ?: return
        cleanupSpeechRecognizer()
        pendingSpeechResult = null
        result.error("speech_error", speechErrorMessage(error), null)
    }

    private fun cleanupSpeechRecognizer() {
        speechRecognizer?.destroy()
        speechRecognizer = null
    }

    private fun speechErrorMessage(error: Int): String {
        return when (error) {
            SpeechRecognizer.ERROR_AUDIO -> "Audio recording failed."
            SpeechRecognizer.ERROR_CLIENT -> "Speech recognition stopped."
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission is required."
            SpeechRecognizer.ERROR_NETWORK -> "Network error while listening."
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Speech recognition timed out."
            SpeechRecognizer.ERROR_NO_MATCH -> "I did not catch a reminder."
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Speech recognition is busy."
            SpeechRecognizer.ERROR_SERVER -> "Speech recognition service failed."
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech was heard."
            else -> "Dictation failed."
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != audioPermissionRequestCode) {
            return
        }

        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            startSpeechRecognizer()
            return
        }

        val result = pendingSpeechResult ?: return
        pendingSpeechResult = null
        result.error("permission_denied", "Microphone permission is required.", null)
    }

    override fun onDestroy() {
        cleanupSpeechRecognizer()
        pendingSpeechResult = null
        super.onDestroy()
    }
}
