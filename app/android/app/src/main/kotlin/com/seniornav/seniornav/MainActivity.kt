package com.seniornav.seniornav

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val bridgeOwner = Any()
    private var baiduChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        baiduChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "seniornav/baidu").also {
            it.setMethodCallHandler { call, result ->
                BaiduBridge.handle(applicationContext, bridgeOwner, call, result)
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        baiduChannel?.setMethodCallHandler(null)
        baiduChannel = null
        BaiduBridge.detach(bridgeOwner)
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
