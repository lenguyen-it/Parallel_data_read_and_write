import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:paralled_data/database/history_database.dart';
import 'package:paralled_data/plugin/rfid_bluetooth_plugin.dart';

class RfidScanBluetoothService {
  static const String serverUrl = 'http://192.168.15.194:5000/api/scans';

  // =================== Các stream subscription để lắng nghe sự kiện từ plugin ===================
  StreamSubscription? _scanSubscription;
  StreamSubscription? _rfidSubscription;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _configSubscription;

  // =================== Timer cho đồng bộ tự động và làm mới dữ liệu ===================
  Timer? _syncTimer;
  Timer? _autoRefreshTimer;

  // =================== Bộ đếm số lần retry cho từng bản ghi khi đồng bộ thất bại ===================
  final Map<String, int> _retryCounter = {};

  // =================== Cờ đánh dấu đang trong quá trình đồng bộ để tránh gọi đồng thời ===================
  bool _isSyncing = false;

  // =================== Callback functions để cập nhật UI từ service ===================
  Function(Map<String, String>)? onDeviceFound;
  Function(bool)? onConnectionStateChanged;
  Function(Map<String, dynamic>)? onRfidTagScanned;
  Function(int)? onBatteryLevelChanged;
  Function()? onDataUpdated;

  void initializeListeners() {
    _scanSubscription = RfidBlePlugin.scanResults.listen((device) {
      onDeviceFound?.call(device);
    });

    _connectionSubscription =
        RfidBlePlugin.connectionState.listen((isConnected) {
      onConnectionStateChanged?.call(isConnected);
    });

    _rfidSubscription = RfidBlePlugin.rfidStream.listen((data) async {
      final epc = (data['epc_ascii']?.toString().trim() ?? '');
      if (epc.isEmpty) return;

      onRfidTagScanned?.call(data);

      final idLocal =
          await HistoryDatabase.instance.insertScan(epc, status: 'pending');

      await sendToServer(epc, idLocal);

      onDataUpdated?.call();
    });

    _configSubscription = RfidBlePlugin.configStream.listen((cfg) {
      if (cfg['type'] == 'battery') {
        final batteryLevel = cfg['battery'] ?? 0;
        onBatteryLevelChanged?.call(batteryLevel);
      }
    });
  }

  // =================== Các phương thức kiểm tra và điều khiển Bluetooth ===================

  Future<bool> checkBluetoothStatus() async {
    return await RfidBlePlugin.checkBluetoothEnabled();
  }

  Future<void> enableBluetooth() async {
    await RfidBlePlugin.enableBluetooth();
  }

  Future<bool> checkExistingConnection() async {
    try {
      final isConnected = await RfidBlePlugin.getConnectionStatus();
      if (isConnected) {
        await RfidBlePlugin.getBatteryLevel();
      }
      return isConnected;
    } catch (e) {
      return false;
    }
  }

  // =================== Các phương thức quét và kết nối thiết bị Bluetooth ===================

  Future<void> startScanBluetooth() async {
    await RfidBlePlugin.startScan();
  }

  Future<void> stopScan() async {
    await RfidBlePlugin.stopScan();
  }

  Future<String> connectToDevice(String name, String address) async {
    try {
      String result = await RfidBlePlugin.connectToDevice('', address);
      if (result.isNotEmpty) {
        await RfidBlePlugin.getBatteryLevel();
        return name;
      }
      return '';
    } catch (e) {
      rethrow;
    }
  }

  Future<void> disconnect() async {
    await RfidBlePlugin.disconnectDevice();
  }

  // =================== Các phương thức quét RFID tag ===================

  Future<void> singleRead() async {
    await RfidBlePlugin.singleInventory();
  }

  Future<void> startReading() async {
    await RfidBlePlugin.startInventory();
  }

  Future<void> stopReading() async {
    await RfidBlePlugin.stopInventory();
  }

  // =================== Các phương thức quản lý dữ liệu local ===================

  Future<List<Map<String, dynamic>>> loadLocalData() async {
    return await HistoryDatabase.instance.getAllScans();
  }

  Future<void> clearHistory() async {
    await HistoryDatabase.instance.clearHistory();
  }

  // =================== Các phương thức đồng bộ dữ liệu lên server ===================

  Future<void> sendToServer(String tag, String idLocal) async {
    final url = Uri.parse(serverUrl);
    final body = {
      'barcode': tag,
      'timestamp_device': DateTime.now().toIso8601String(),
      'status_sync': true,
    };

    try {
      final resp = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        await HistoryDatabase.instance.updateStatusById(idLocal, 'synced');
        _retryCounter.remove(idLocal);
        onDataUpdated?.call();
      } else {
        await _handleRetryFail(idLocal);
      }
    } catch (_) {
      await _handleRetryFail(idLocal);
    }
  }

  Future<void> _handleRetryFail(String idLocal) async {
    _retryCounter[idLocal] = (_retryCounter[idLocal] ?? 0) + 1;
    if (_retryCounter[idLocal]! >= 3) {
      await HistoryDatabase.instance.updateStatusById(idLocal, 'failed');
      _retryCounter.remove(idLocal);
    } else {
      await HistoryDatabase.instance.updateStatusById(idLocal, 'pending');
    }
    onDataUpdated?.call();
  }

  // =================== Các worker tự động chạy nền ===================

  void startSyncWorker() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_isSyncing) return;
      _isSyncing = true;
      try {
        final pending = await HistoryDatabase.instance.getPendingScans();
        for (final scan in pending) {
          final tag = scan['barcode'] as String;
          final idLocal = scan['id_local'] as String;
          await sendToServer(tag, idLocal);
        }
      } finally {
        _isSyncing = false;
      }
    });
  }

  void startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      onDataUpdated?.call();
    });
  }

  // =================== Dọn dẹp tài nguyên khi dispose ===================

  void dispose() {
    _scanSubscription?.cancel();
    _rfidSubscription?.cancel();
    _connectionSubscription?.cancel();
    _configSubscription?.cancel();
    _syncTimer?.cancel();
    _autoRefreshTimer?.cancel();
  }
}
