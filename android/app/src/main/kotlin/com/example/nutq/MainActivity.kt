package com.example.nutq

import android.os.Bundle
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val channelName = "phonetizer"

	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		if (!Python.isStarted()) {
			Python.start(AndroidPlatform(this))
		}
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
			when (call.method) {
				"phonetize" -> {
					try {
						val text = call.argument<String>("uthmaniText") ?: ""
						val removeSpaces = call.argument<Boolean>("removeSpaces") ?: false
						val moshafAttr = call.argument<Map<String, Any?>>("moshafAttr") ?: emptyMap()

						val py = Python.getInstance()
						val module = py.getModule("phonetizer")
						val output = module.callAttr(
							"phonetize_payload",
							text,
							moshafAttr,
							removeSpaces,
						)

						val jsonModule = py.getModule("json")
						val jsonText = jsonModule.callAttr("dumps", output).toString()
						result.success(jsonText)
					} catch (error: Exception) {
						result.error("PHONETIZER_ERROR", error.message, null)
					}
				}
				else -> result.notImplemented()
			}
		}
	}
}
