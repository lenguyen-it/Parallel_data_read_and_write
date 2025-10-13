import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:async';

class RfidBlePlugin {
  static const MethodChannel _channel = MethodChannel('rfid_ble_channel');

  static const EventChannel _scanDevicesResultChannel = EventChannel(
    'ble_rfid_scan_result',
  );

  static const EventChannel _connectionChannel = EventChannel(
    'ble_rfid_connection',
  );

  static const EventChannel _rfidDataChannel = EventChannel('rfid_ble_data');
  static const EventChannel _configStream = EventChannel("ble_rfid_config");

  static const EventChannel _bluetoothStateChannel =
      EventChannel('bluetooth_state_channel');

  static Future<String?> get platformVersion async {
    final String? version = await _channel.invokeMethod('getPlatformVersion');
    return version;
  }

  // Stream lắng nghe thay đổi Bluetooth state
  static Stream<bool> get bluetoothStateStream {
    return _bluetoothStateChannel.receiveBroadcastStream().map((event) {
      try {
        return event as bool;
      } catch (e) {
        if (kDebugMode) {
          print("❌ Error parsing Bluetooth state: $e");
        }
        return false;
      }
    });
  }

  /// Kiểm tra Bluetooth đã bật chưa
  static Future<bool> checkBluetoothEnabled() async {
    try {
      final bool isEnabled =
          await _channel.invokeMethod('checkBluetoothEnabled');
      return isEnabled;
    } catch (e) {
      if (kDebugMode) {
        print("❌ Error checking Bluetooth: $e");
      }
      return false;
    }
  }

  /// Yêu cầu bật Bluetooth
  static Future<bool> enableBluetooth() async {
    try {
      await _channel.invokeMethod('enableBluetooth');
      return true;
    } catch (e) {
      if (kDebugMode) {
        print("❌ Error enabling Bluetooth: $e");
      }
      return false;
    }
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
      rethrow;
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

  /// Lấy trạng thái kết nối hiện tại
  static Future<bool> getConnectionStatus() async {
    try {
      final bool isConnected =
          await _channel.invokeMethod('getConnectionStatus');
      return isConnected;
    } catch (e) {
      if (kDebugMode) {
        print("❌ Error getting connection status: $e");
      }
      return false;
    }
  }
}
