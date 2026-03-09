package com.dtonon.manent

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "manent/process_text"
    private var pendingText: String? = null
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).also {
            it.setMethodCallHandler { call, result ->
                // Flutter calls this on startup to retrieve text received before Dart was ready
                if (call.method == "getInitialProcessText") {
                    result.success(pendingText?.also { pendingText = null })
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent) {
        if (intent.action != Intent.ACTION_PROCESS_TEXT) return
        val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString() ?: return
        val ch = methodChannel
        if (ch != null) {
            ch.invokeMethod("onProcessText", text)
        } else {
            // Engine not ready yet; Flutter will poll via getInitialProcessText
            pendingText = text
        }
    }
}
