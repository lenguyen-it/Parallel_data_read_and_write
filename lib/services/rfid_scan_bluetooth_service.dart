// ignore_for_file: unused_field
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:paralled_data/services/temp_storage_service.dart';
import 'package:paralled_data/database/history_database.dart';
import 'package:paralled_data/plugin/rfid_bluetooth_plugin.dart';
import 'package:paralled_data/services/encryption_security_service.dart';

class RfidScanBluetoothService {
  // =================== Trạng thái ===================
  bool isConnected = false;
  bool isBluetoothEnabled = false;
  bool isScanning = false;
  bool isReading = false;
  bool isLoading = false;
  bool isImportSyncing = false;

  String connectedDeviceName = '';
  String lastConnectedDeviceName = '';
  String lastConnectedDeviceAddress = '';
  int batteryLevel = 0;

  // =================== Danh sách & dữ liệu ===================
  final List<Map<String, String>> deviceList = [];
  final List<Map<String, dynamic>> rfidTags = [];
  List<Map<String, dynamic>> localData = [];

  // =================== Stream & Timer ===================
  StreamSubscription? _scanSubscription;
  StreamSubscription? _rfidSubscription;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _configSubscription;
  StreamSubscription? _bluetoothStateSubscription;

  Timer? _syncTimer;
  Timer? _autoRefreshTimer;

  // =================== BATCH CONFIG ===================
  static const int batchSize = 25;
  static const Duration batchInterval = Duration(milliseconds: 300);
  final List<Map<String, dynamic>> _pendingBatch = [];
  Timer? _batchTimer;
  bool _isFlushingBatch = false;

  // =================== CONCURRENT REQUEST ===================
  final Set<String> _sendingIds = {};
  final List<_QueuedRequest> _requestQueue = [];
  int _activeRequests = 0;
  static const int maxConcurrentRequests = 3;

  // =================== UI THROTTLING ===================
  Timer? _uiUpdateTimer;
  bool _hasPendingUIUpdate = false;

  final Map<String, int> _retryCounter = {};
  bool _isSyncing = false;

  static const String serverUrl = 'http://192.168.15.194:5000/api/scans';
  static const int maxRetryAttempts = 2;

  // =================== MÃ HÓA & TỐC ĐỘ ===================
  final EncryptionSecurityService _encryption = EncryptionSecurityService();
  bool encryptionInitialized = false;

  final List<DateTime> _scanTimestamps = [];
  final List<DateTime> _syncTimestamps = [];

  int get scansInLastSecond {
    final now = DateTime.now();
    final oneSecondAgo = now.subtract(const Duration(seconds: 1));
    _scanTimestamps.removeWhere((t) => t.isBefore(oneSecondAgo));
    return _scanTimestamps.length;
  }

  int get syncsInLastSecond {
    final now = DateTime.now();
    final oneSecondAgo = now.subtract(const Duration(seconds: 1));
    _syncTimestamps.removeWhere((t) => t.isBefore(oneSecondAgo));
    return _syncTimestamps.length;
  }

  // Đếm số
  int totalCount = 0;
  int uniqueCount = 0;
  final Set<String> uniqueEpcs = {};

  final StreamController<Map<String, dynamic>> _syncController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get syncStream => _syncController.stream;

  // Status update queue
  final List<_StatusUpdate> _statusUpdateQueue = [];
  Timer? _statusUpdateTimer;
  bool _isUpdatingStatus = false;

  // Callbacks
  Function()? onStateChanged;
  Function(Map<String, dynamic>)? onRfidDataReceived;

  Future<void> initEncryption() async {
    if (!_encryption.isInitialized) {
      await _encryption.initializeEncryption();
      encryptionInitialized = true;
      debugPrint('Encryption đã được khởi tạo');
    }
  }

  void dispose() {
    _scanSubscription?.cancel();
    _rfidSubscription?.cancel();
    _connectionSubscription?.cancel();
    _configSubscription?.cancel();
    _bluetoothStateSubscription?.cancel();

    _syncTimer?.cancel();
    _autoRefreshTimer?.cancel();
    _batchTimer?.cancel();
    _uiUpdateTimer?.cancel();
    _statusUpdateTimer?.cancel();

    unawaited(_cleanupTempFile());
  }

  Future<void> _cleanupTempFile() async {
    try {
      if (_pendingBatch.isNotEmpty) {
        await _flushBatch(force: true);
      }
      if (_statusUpdateQueue.isNotEmpty) {
        await _processBatchStatusUpdate();
      }
      await TempStorageService().flushQueue();
      await TempStorageService().clearTempFile();
      debugPrint('Đã xóa file tạm');
    } catch (e) {
      debugPrint('Lỗi cleanup: $e');
    }
  }

  Future<bool> checkExistingConnection() async {
    try {
      final connected = await RfidBlePlugin.getConnectionStatus();
      isConnected = connected;

      if (connected) {
        await loadLocal();
        await RfidBlePlugin.getBatteryLevel();
      }

      return connected;
    } catch (e) {
      debugPrint('Lỗi kiểm tra kết nối: $e');
      isConnected = false;
      return false;
    }
  }

  // =================== Bluetooth ===================
  Future<void> checkBluetoothStatus() async {
    isBluetoothEnabled = await RfidBlePlugin.checkBluetoothEnabled();
    onStateChanged?.call();
  }

  Future<void> enableBluetooth() async {
    await RfidBlePlugin.enableBluetooth();
  }

  void initializeListeners() {
    _scanSubscription = RfidBlePlugin.scanResults.listen(
      (device) {
        bool exists = deviceList.any((d) => d['address'] == device['address']);
        if (!exists) {
          deviceList.add(device);
          onStateChanged?.call();
        }
      },
    );

    _connectionSubscription = RfidBlePlugin.connectionState.listen((connected) {
      isConnected = connected;
      if (!connected) {
        connectedDeviceName = '';
        rfidTags.clear();
        batteryLevel = 0;
      }
      onStateChanged?.call();
    });

    _rfidSubscription = RfidBlePlugin.rfidStream.listen(
      (data) async {
        final epc = (data['epc_ascii']?.toString().trim() ?? '');
        if (epc.isEmpty) return;

        totalCount++;
        if (uniqueEpcs.add(epc)) {
          uniqueCount++;
        }

        debugPrint('Tổng: $totalCount | Duy nhất: $uniqueCount');

        _scanTimestamps.add(DateTime.now());
        onRfidDataReceived?.call(data);
        _addToBatch(data);
      },
    );

    _configSubscription = RfidBlePlugin.configStream.listen((cfg) {
      if (cfg['type'] == 'battery') {
        batteryLevel = cfg['battery'] ?? 0;
        onStateChanged?.call();
      }
    });
  }

  // =================== Scan / Connect ===================
  Future<void> startScanBluetooth() async {
    if (!isBluetoothEnabled) {
      await enableBluetooth();
      return;
    }
    isScanning = true;
    deviceList.clear();
    onStateChanged?.call();

    await RfidBlePlugin.startScan();

    Future.delayed(const Duration(seconds: 10), () {
      if (isScanning) stopScan();
    });
  }

  Future<void> stopScan() async {
    await RfidBlePlugin.stopScan();
    isScanning = false;
    onStateChanged?.call();
  }

  Future<String> connectToDevice(String name, String address) async {
    try {
      String result = await RfidBlePlugin.connectToDevice('', address);
      if (result.isNotEmpty) {
        connectedDeviceName = name;
        lastConnectedDeviceName = name;
        lastConnectedDeviceAddress = address;
        isConnected = true;
        await loadLocal();
        await RfidBlePlugin.getBatteryLevel();
        onStateChanged?.call();
      }
      return result;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> disconnect() async {
    await RfidBlePlugin.disconnectDevice();
    isConnected = false;
    connectedDeviceName = '';
    rfidTags.clear();
    batteryLevel = 0;
    onStateChanged?.call();
  }

  // =================== BATCH BUFFER ===================
  void _addToBatch(Map<String, dynamic> data) {
    _pendingBatch.add({
      'epc': data['epc_ascii'] ?? '',
      'scan_duration_ms': data['scan_duration_ms'],
      'epc_hex': data['epc_hex'],
      'tid_hex': data['tid_hex'],
      'user_hex': data['user_hex'],
      'rssi': data['rssi'],
      'count': data['count'],
    });

    if (_pendingBatch.length >= batchSize) {
      unawaited(_flushBatch());
      return;
    }

    _batchTimer?.cancel();
    _batchTimer = Timer(batchInterval, () => _flushBatch());
  }

  // =================== GOM BATCH & FLUSH ===================
  Future<void> _flushBatch({bool force = false}) async {
    if (!force && (_isFlushingBatch || _pendingBatch.isEmpty)) return;
    if (_pendingBatch.isEmpty) return;

    _isFlushingBatch = true;

    try {
      final batch = List<Map<String, dynamic>>.from(_pendingBatch);
      _pendingBatch.clear();
      _batchTimer?.cancel();
      _batchTimer = null;

      final ids = await HistoryDatabase.instance.batchInsertScans(batch);
      if (ids.isEmpty) return;

      final List<Map<String, dynamic>> items = [];
      for (int i = 0; i < batch.length; i++) {
        items.add({
          'id_local': ids[i],
          'sync_status': 'pending',
          ...batch[i],
        });
      }

      await TempStorageService().appendBatch(items);

      for (int i = 0; i < batch.length; i++) {
        unawaited(_sendToServer(batch[i], ids[i]));
      }

      await loadLocal();
    } catch (e, st) {
      debugPrint('Lỗi flush batch: $e\n$st');
    } finally {
      _isFlushingBatch = false;
    }
  }

  // Gửi lên server
  Future<void> _sendToServer(Map<String, dynamic> data, String idLocal) async {
    final epc = data['epc'] ?? '';
    if (_sendingIds.contains(idLocal)) return;

    _sendingIds.add(idLocal);
    _activeRequests++;

    final startTime = DateTime.now();
    final stopwatch = Stopwatch()..start();

    final body = {
      'epc': epc,
      'epc_hex': data['epc_hex'],
      'tid_hex': data['tid_hex'],
      'user_hex': data['user_hex'],
      'rssi': data['rssi'],
      'count': data['count'],
      'timestamp_device': startTime.toIso8601String(),
      'status_sync': true,
    };

    try {
      final response = await http
          .post(Uri.parse(serverUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 3));

      stopwatch.stop();
      final syncDurationMs = stopwatch.elapsedMilliseconds.toDouble();

      if (response.statusCode == 200 || response.statusCode == 201) {
        _addStatusUpdate(
          idLocal: idLocal,
          status: 'synced',
          syncDurationMs: syncDurationMs,
        );
        _syncTimestamps.add(DateTime.now());
      } else {
        await _handleRetryFail(
            idLocal, data, 'Server error ${response.statusCode}');
      }
    } catch (e) {
      stopwatch.stop();
      await _handleRetryFail(idLocal, data, e.toString());
    } finally {
      _sendingIds.remove(idLocal);
      _activeRequests--;
      if (_requestQueue.isNotEmpty) {
        final next = _requestQueue.removeAt(0);
        unawaited(_sendToServer(next.data, next.idLocal));
      }
    }
  }

  void _addStatusUpdate({
    required String idLocal,
    required String status,
    double? syncDurationMs,
    String? error,
  }) {
    _statusUpdateQueue.add(_StatusUpdate(
      idLocal: idLocal,
      status: status,
      syncDurationMs: syncDurationMs,
      error: error,
    ));

    _statusUpdateTimer?.cancel();
    _statusUpdateTimer = Timer(const Duration(milliseconds: 100), () {
      _processBatchStatusUpdate();
    });
  }

  Future<void> _processBatchStatusUpdate() async {
    if (_isUpdatingStatus || _statusUpdateQueue.isEmpty) return;
    _isUpdatingStatus = true;

    try {
      final updates = List<_StatusUpdate>.from(_statusUpdateQueue);
      _statusUpdateQueue.clear();

      await HistoryDatabase.instance.batchUpdateStatus(updates);

      for (final update in updates) {
        await TempStorageService().updateSyncStatus(
          idLocal: update.idLocal,
          syncStatus: update.status,
          syncDurationMs: update.syncDurationMs,
          syncError: update.error,
        );
      }

      await loadLocal();
    } catch (e) {
      debugPrint('Lỗi update status: $e');
    } finally {
      _isUpdatingStatus = false;
    }
  }

  Future<void> _handleRetryFail(
      String idLocal, Map<String, dynamic> data, String error) async {
    _retryCounter[idLocal] = (_retryCounter[idLocal] ?? 0) + 1;
    final retryCount = _retryCounter[idLocal]!;

    if (retryCount <= 1) {
      await Future.delayed(const Duration(milliseconds: 500));
      unawaited(_sendToServer(data, idLocal));
      return;
    }

    _addStatusUpdate(idLocal: idLocal, status: 'failed', error: error);
    _retryCounter.remove(idLocal);
  }

  Future<void> loadLocal() async {
    final data = await HistoryDatabase.instance.getAllScans();
    localData = data;
    onStateChanged?.call();
  }

  void startAutoRefresh() {
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      await loadLocal();
    });
  }

  void startSyncWorker() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_isSyncing) return;
      _isSyncing = true;

      try {
        final pending = await HistoryDatabase.instance.getPendingScans();
        for (final scan in pending) {
          final idLocal = scan['id_local'] as String;
          final data = {
            'epc': scan['epc'],
            'epc_hex': scan['epc_hex'],
            'tid_hex': scan['tid_hex'],
            'user_hex': scan['user_hex'],
            'rssi': scan['rssi'],
            'count': scan['count'],
          };
          await _sendToServer(data, idLocal);
        }
      } finally {
        _isSyncing = false;
      }
    });
  }

  Future<void> syncRecordsFromTemp() async {
    if (isImportSyncing || _isSyncing) {
      debugPrint('Sync đang chạy, bỏ qua syncRecordsFromTemp');
      return;
    }

    isImportSyncing = true;

    try {
      final unsyncedRecords = await TempStorageService().getUnsyncedRecords();
      if (unsyncedRecords.isEmpty) {
        debugPrint('Không có bản ghi nào cần đồng bộ từ file tạm');
        return;
      }

      debugPrint(
          'Bắt đầu đồng bộ ${unsyncedRecords.length} bản ghi từ file tạm');

      final List<Map<String, dynamic>> batch = [];
      final List<String> oldIds = [];

      for (var record in unsyncedRecords) {
        final idLocal = record['id_local']?.toString();
        if (idLocal == null) continue;

        final epc = record['epc']?.toString() ?? '';
        if (epc.isEmpty) continue;

        batch.add({
          'epc': epc,
          'epc_hex': record['epc_hex'],
          'tid_hex': record['tid_hex'],
          'user_hex': record['user_hex'],
          'rssi': record['rssi'],
          'count': record['count'],
          'scan_duration_ms': record['scan_duration_ms'],
        });
        oldIds.add(idLocal);
      }

      if (batch.isEmpty) return;

      final ids = await HistoryDatabase.instance.batchInsertScans(batch);
      if (ids.length != batch.length) return;

      for (int i = 0; i < batch.length; i++) {
        final idLocal = ids[i];
        final data = batch[i];
        final oldIdLocal = oldIds[i];

        unawaited(_sendToServerWithOldId(data, idLocal, oldIdLocal));
      }

      debugPrint('Đã gửi ${ids.length} bản ghi từ import lên server');
      await loadLocal();
    } catch (e) {
      debugPrint('Lỗi syncRecordsFromTemp: $e');
    } finally {
      isImportSyncing = false;
    }
  }

  Future<void> _sendToServerWithOldId(
      Map<String, dynamic> data, String newIdLocal, String oldIdLocal) async {
    if (_sendingIds.contains(newIdLocal)) return;

    _sendingIds.add(newIdLocal);
    _activeRequests++;

    final startTime = DateTime.now();
    final stopwatch = Stopwatch()..start();

    final body = {
      'epc': data['epc'] ?? '',
      'epc_hex': data['epc_hex'],
      'tid_hex': data['tid_hex'],
      'user_hex': data['user_hex'],
      'rssi': data['rssi'],
      'count': data['count'],
      'timestamp_device': startTime.toIso8601String(),
      'status_sync': true,
    };

    try {
      final response = await http
          .post(Uri.parse(serverUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 3));

      stopwatch.stop();
      final syncDurationMs = stopwatch.elapsedMilliseconds.toDouble();

      if (response.statusCode == 200 || response.statusCode == 201) {
        _addStatusUpdate(
          idLocal: newIdLocal,
          status: 'synced',
          syncDurationMs: syncDurationMs,
        );

        await TempStorageService().updateSyncStatus(
          idLocal: oldIdLocal,
          syncStatus: 'synced',
          syncDurationMs: syncDurationMs,
        );

        _syncTimestamps.add(DateTime.now());
        _syncController.add({'id': newIdLocal, 'status': 'synced'});
      } else {
        await _handleRetryFailWithOldId(newIdLocal, oldIdLocal, data,
            'Server error ${response.statusCode}');
      }
    } catch (e) {
      stopwatch.stop();
      await _handleRetryFailWithOldId(
          newIdLocal, oldIdLocal, data, e.toString());
    } finally {
      _sendingIds.remove(newIdLocal);
      _activeRequests--;

      if (_requestQueue.isNotEmpty) {
        final next = _requestQueue.removeAt(0);
        unawaited(_sendToServer(next.data, next.idLocal));
      }
    }
  }

  Future<void> _handleRetryFailWithOldId(String newIdLocal, String oldIdLocal,
      Map<String, dynamic> data, String error) async {
    _retryCounter[newIdLocal] = (_retryCounter[newIdLocal] ?? 0) + 1;
    final retryCount = _retryCounter[newIdLocal]!;

    if (retryCount <= 1) {
      await Future.delayed(const Duration(milliseconds: 500));
      Future.microtask(
          () => _sendToServerWithOldId(data, newIdLocal, oldIdLocal));
      return;
    }

    _addStatusUpdate(idLocal: newIdLocal, status: 'failed', error: error);

    await TempStorageService().updateSyncStatus(
      idLocal: oldIdLocal,
      syncStatus: 'failed',
      syncError: error,
    );

    _syncController.add({'id': newIdLocal, 'status': 'failed'});
    _retryCounter.remove(newIdLocal);
  }

  Future<void> singleRead() async {
    if (!isConnected) return;
    await RfidBlePlugin.singleInventory();
  }

  Future<void> startReading() async {
    if (!isConnected) return;
    await RfidBlePlugin.startInventory();
    isReading = true;
    onStateChanged?.call();
  }

  Future<void> stopReading() async {
    if (!isConnected) return;

    _batchTimer?.cancel();
    _batchTimer = null;
    _uiUpdateTimer?.cancel();
    _uiUpdateTimer = null;

    await RfidBlePlugin.stopInventory();
    isReading = false;

    await _flushBatch(force: true);
    await TempStorageService().flushQueue();

    debugPrint('✅ Dừng scan liên tục hoàn tất');
    onStateChanged?.call();
  }

  Future<void> clearHistory() async {
    await HistoryDatabase.instance.clearHistory();
    await loadLocal();
    rfidTags.clear();
    _retryCounter.clear();
    onStateChanged?.call();
  }
}

class _QueuedRequest {
  final Map<String, dynamic> data;
  final String idLocal;
  _QueuedRequest(this.data, this.idLocal);
}

class _StatusUpdate {
  final String idLocal;
  final String status;
  final double? syncDurationMs;
  final String? error;
  _StatusUpdate({
    required this.idLocal,
    required this.status,
    this.syncDurationMs,
    this.error,
  });
}
