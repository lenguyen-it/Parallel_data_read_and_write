import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:async';

class RfidBlePlugin {
  static const MethodChannel _channel = MethodChannel('rfid_ble_channel');

  // Channel riêng cho scan devices
  static const EventChannel _scanDevicesResultChannel = EventChannel(
    'ble_rfid_scan_result',
  );

  // Channel riêng cho connection status
  static const EventChannel _connectionChannel = EventChannel(
    'ble_rfid_connection',
  );

  static const EventChannel _rfidDataChannel = EventChannel('rfid_ble_data');
  static const EventChannel _configStream = EventChannel("ble_rfid_config");

  static Future<String?> get platformVersion async {
    final String? version = await _channel.invokeMethod('getPlatformVersion');
    return version;
  }

  /// Stream danh sách thiết bị BLE scan được
  static Stream<Map<String, String>> get scanResults {
    return _scanDevicesResultChannel.receiveBroadcastStream().map((event) {
      try {
        return Map<String, String>.from(event);
      } catch (e) {
        if (kDebugMode) {
          print("❌ Error parsing scan result: $e");
        }
        return <String, String>{};
      }
    }).where((map) => map.isNotEmpty);
  }

  /// Stream trạng thái kết nối BLE (true: đã kết nối, false: ngắt kết nối)
  static Stream<bool> get connectionState {
    return _connectionChannel
        .receiveBroadcastStream()
        .map((event) {
          try {
            final data = Map<String, dynamic>.from(event);
            if (data.containsKey('connection')) {
              return data['connection'] == true;
            }
            return null;
          } catch (e) {
            if (kDebugMode) {
              print("❌ Error parsing connection state: $e");
            }
            return null;
          }
        })
        .where((e) => e != null)
        .cast<bool>();
  }

  /// Stream dữ liệu RFID tag
  static Stream<Map<String, dynamic>> get rfidStream {
    return _rfidDataChannel.receiveBroadcastStream().map(
          (event) => Map<String, dynamic>.from(event),
        );
  }

  /// Stream cấu hình (ví dụ: mức pin, firmware...)
  static Stream<Map<String, dynamic>> get configStream {
    return _configStream.receiveBroadcastStream().map((event) {
      return Map<String, dynamic>.from(event);
    });
  }

  /// Bắt đầu scan thiết bị BLE
  static Future<void> startScan() async {
    try {
      await _channel.invokeMethod('startScan');
    } catch (e) {
      if (kDebugMode) {
        print("❌ Error start scan: $e");
      }
    }
  }

  /// Dừng scan thiết bị BLE
  static Future<void> stopScan() async {
    try {
      await _channel.invokeMethod('stopScan');
    } catch (e) {
      if (kDebugMode) {
        print("❌ Error stopping scan: $e");
      }
    }
  }

  /// Kết nối với thiết bị qua UUID và MAC Address
  static Future<String> connectToDevice(String uuid, String mac) async {
    try {
      return await _channel.invokeMethod("connectDevice", {
        "uuid": uuid,
        "mac": mac,
      });
    } catch (e) {
      if (kDebugMode) {
        print("❌ Error connecting to device: $e");
      }
      return "";
    }
  }

  /// Ngắt kết nối thiết bị
  static Future<void> disconnectDevice() async {
    try {
      await _channel.invokeMethod('disconnect');
    } catch (e) {
      if (kDebugMode) {
        print("❌ Error disconnect BLE: $e");
      }
    }
  }

  /// Đọc RFID đơn lẻ (single read)
  static Future<void> singleInventory() async {
    try {
      await _channel.invokeMethod("singleInventory");
    } catch (e) {
      if (kDebugMode) {
        print("❌ Error single read: $e");
      }
    }
  }

  /// Bắt đầu đọc RFID liên tục
  static Future<void> startInventory() async {
    try {
      await _channel.invokeMethod("startInventory");
    } catch (e) {
      if (kDebugMode) {
        print("❌ Error start continuous read: $e");
      }
    }
  }

  /// Dừng đọc RFID liên tục
  static Future<void> stopInventory() async {
    try {
      await _channel.invokeMethod("stopInventory");
    } catch (e) {
      debugPrint("❌ Error stop continuous read: $e");
    }
  }

  /// Lấy mức pin của thiết bị
  static Future<void> getBatteryLevel() async {
    try {
      await _channel.invokeMethod("getBatteryLevel");
    } catch (e) {
      if (kDebugMode) {
        print("❌ Error getting battery level: $e");
      }
    }
  }
}
