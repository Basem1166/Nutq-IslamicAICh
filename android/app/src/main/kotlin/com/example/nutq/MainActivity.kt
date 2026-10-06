package com.example.nutq

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
	private val channelName = "phonetizer"

	// Python runs off the main thread so phonetizing never stalls the platform
	// thread (which also delivers mic audio). Single-threaded: the interpreter
	// work isn't safe to run concurrently.
	private val phonetizerExecutor: ExecutorService = Executors.newSingleThreadExecutor()
	private val mainHandler = Handler(Looper.getMainLooper())

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
					val text = call.argument<String>("uthmaniText") ?: ""
					val removeSpaces = call.argument<Boolean>("removeSpaces") ?: false
					val moshafAttr = call.argument<Map<String, Any?>>("moshafAttr") ?: emptyMap()
					phonetizerExecutor.execute {
						try {
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
							mainHandler.post { result.success(jsonText) }
						} catch (error: Exception) {
							mainHandler.post { result.error("PHONETIZER_ERROR", error.message, null) }
						}
					}
				}
				else -> result.notImplemented()
			}
		}
	}

	override fun onDestroy() {
		phonetizerExecutor.shutdown()
		super.onDestroy()
	}
}
