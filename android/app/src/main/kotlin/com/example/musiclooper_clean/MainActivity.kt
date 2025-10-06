package com.example.musiclooper_clean

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "app.channel.shared.data"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Rien de spécial ici, tout se passe dans configureFlutterEngine + onNewIntent
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Appelé au démarrage (voir main.dart)
                    "getSharedText" -> {
                        val sharedText = extractSharedText(intent)
                        result.success(sharedText)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Quand l'app est déjà ouverte et qu'on partage vers elle,
    // on reçoit un nouvel intent ici.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent) // important pour que main.dart lise le bon intent
    }

    /** Récupère le texte (URL…) depuis l’intent Android */
    private fun extractSharedText(intent: Intent?): String? {
        if (intent == null) return null
        val action = intent.action
        val type = intent.type ?: return null

        return when {
            Intent.ACTION_SEND == action && type == "text/plain" ->
                intent.getStringExtra(Intent.EXTRA_TEXT)

            Intent.ACTION_SEND_MULTIPLE == action && type == "text/plain" -> {
                // Rare, mais on concatène si plusieurs textes
                val list = intent.getStringArrayListExtra(Intent.EXTRA_TEXT)
                list?.joinToString("\n")
            }

            else -> null
        }
    }
}