import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:paralled_data/database/history_database.dart';
import 'package:paralled_data/plugin/rfid_bluetooth_plugin.dart';

class RfidScanBluetoothService {
  bool isConnected = false;
  bool isBluetoothEnabled = false;
  bool isScanning = false;
  bool isReading = false;

  String connectedDeviceName = '';
  String lastConnectedDeviceAddress = '';
  int batteryLevel = 0;

  final List<Map<String, String>> deviceList = [];
  final List<Map<String, dynamic>> rfidTags = [];
  List<Map<String, dynamic>> localData = [];

  StreamSubscription? scanSubscription;
  StreamSubscription? rfidSubscription;
  StreamSubscription? connectionSubscription;
  StreamSubscription? configSubscription;
  StreamSubscription? bluetoothStateSubscription;

  Timer? syncTimer;
  Timer? autoRefreshTimer;
  final Map<String, int> retryCounter = {};
  bool isSyncing = false;

  static const String serverUrl = 'http://192.168.15.194:5000/api/scans';

  // =================== Init ===================
  void initializeListeners(Function onUpdate) {
    scanSubscription = RfidBlePlugin.scanResults.listen(
      (device) {
        bool exists = deviceList.any((d) => d['address'] == device['address']);
        if (!exists) deviceList.add(device);
        onUpdate();
      },
    );

    connectionSubscription =
        RfidBlePlugin.connectionState.listen((state) {
      isConnected = state;
      if (!state) {
        connectedDeviceName = '';
        rfidTags.clear();
        batteryLevel = 0;
      }
      onUpdate();
    });

    rfidSubscription = RfidBlePlugin.rfidStream.listen((data) async {
      final epc = (data['epc_ascii']?.toString().trim() ?? '');
      if (epc.isEmpty) return;

      int idx = rfidTags.indexWhere((t) => t['epc_ascii'] == epc);
      if (idx >= 0) {
        rfidTags[idx] = data;
      } else {
        rfidTags.insert(0, data);
      }

      final idLocal =
          await HistoryDatabase.instance.insertScan(epc, status: 'pending');
      _sendToServer(epc, idLocal);
      await loadLocal();
      onUpdate();
    });

    configSubscription = RfidBlePlugin.configStream.listen((cfg) {
      if (cfg['type'] == 'battery') {
        batteryLevel = cfg['battery'] ?? 0;
        onUpdate();
      }
    });
  }

  // =================== Permissions / Bluetooth ===================
  Future<void> requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetooth,
      Permission.location,
      Permission.locationWhenInUse,
    ].request();

    bool allGranted =
        statuses.values.every((status) => status.isGranted || status.isLimited);

    if (!allGranted) {
      throw Exception('Vui lòng cấp đầy đủ quyền Bluetooth và Location');
    }
  }

  Future<void> checkBluetoothStatus() async {
    isBluetoothEnabled = await RfidBlePlugin.checkBluetoothEnabled();
  }

  Future<void> enableBluetooth() async {
    await RfidBlePlugin.enableBluetooth();
  }

  // =================== Scan / Connect ===================
  Future<void> startScanBluetooth() async {
    if (!isBluetoothEnabled) {
      await enableBluetooth();
      return;
    }
    isScanning = true;
    deviceList.clear();
    await RfidBlePlugin.startScan();
    Future.delayed(const Duration(seconds: 10), () {
      if (isScanning) stopScan();
    });
  }

  Future<void> stopScan() async {
    await RfidBlePlugin.stopScan();
    isScanning = false;
  }

  Future<void> connectToDevice(String name, String address,
      Function onSuccess, Function(String) onError) async {
    try {
      String result = await RfidBlePlugin.connectToDevice('', address);
      if (result.isNotEmpty) {
        connectedDeviceName = name;
        lastConnectedDeviceAddress = address;
        isConnected = true;
        await loadLocal();
        await RfidBlePlugin.getBatteryLevel();
        onSuccess();
      }
    } catch (e) {
      onError('Lỗi kết nối: $e');
    }
  }

  Future<void> disconnect() async {
    await RfidBlePlugin.disconnectDevice();
    isConnected = false;
    connectedDeviceName = '';
    rfidTags.clear();
    batteryLevel = 0;
  }

  // =================== RFID ===================
  Future<void> singleRead() async {
    if (!isConnected) return;
    await RfidBlePlugin.singleInventory();
  }

  Future<void> startReading() async {
    if (!isConnected) return;
    await RfidBlePlugin.startInventory();
    isReading = true;
  }

  Future<void> stopReading() async {
    if (!isConnected) return;
    await RfidBlePlugin.stopInventory();
    isReading = false;
  }

  Future<void> clearHistory() async {
    await HistoryDatabase.instance.clearHistory();
    rfidTags.clear();
    await loadLocal();
  }

  // =================== Local / Server ===================
  Future<void> loadLocal() async {
    localData = await HistoryDatabase.instance.getAllScans();
  }

  Future<void> _sendToServer(String tag, String idLocal) async {
    final url = Uri.parse(serverUrl);
    final body = {
      'barcode': tag,
      'timestamp_device': DateTime.now().toIso8601String(),
      'status_sync': true,
    };

    try {
      final resp = await http.post(url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body));

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        await HistoryDatabase.instance.updateStatusById(idLocal, 'synced');
        retryCounter.remove(idLocal);
        await loadLocal();
      } else {
        _handleRetryFail(idLocal);
      }
    } catch (_) {
      _handleRetryFail(idLocal);
    }
  }

  void _handleRetryFail(String idLocal) async {
    retryCounter[idLocal] = (retryCounter[idLocal] ?? 0) + 1;
    if (retryCounter[idLocal]! >= 3) {
      await HistoryDatabase.instance.updateStatusById(idLocal, 'failed');
      retryCounter.remove(idLocal);
    } else {
      await HistoryDatabase.instance.updateStatusById(idLocal, 'pending');
    }
    await loadLocal();
  }

  void startSyncWorker() {
    syncTimer?.cancel();
    syncTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (isSyncing) return;
      isSyncing = true;
      try {
        final pending = await HistoryDatabase.instance.getPendingScans();
        for (final scan in pending) {
          final tag = scan['barcode'] as String;
          final idLocal = scan['id_local'] as String;
          _sendToServer(tag, idLocal);
        }
      } finally {
        isSyncing = false;
      }
    });
  }

  void startAutoRefresh() {
    autoRefreshTimer?.cancel();
    autoRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await loadLocal();
    });
  }

  void dispose() {
    scanSubscription?.cancel();
    rfidSubscription?.cancel();
    connectionSubscription?.cancel();
    configSubscription?.cancel();
    bluetoothStateSubscription?.cancel();
    syncTimer?.cancel();
    autoRefreshTimer?.cancel();
  }
}
