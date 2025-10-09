package com.example.paralled_data

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.example.paralled_data.connect_bluetooth.RfidBlePlugin

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Đăng ký plugin Java (gọi constructor đúng cú pháp Kotlin)
        flutterEngine.plugins.add(RfidC72Plugin())

        // Đăng ký plugun cho bluetooth
        flutterEngine.plugins.add(RfidBlePlugin())

    }
}
