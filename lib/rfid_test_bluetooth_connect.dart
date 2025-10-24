// ignore_for_file: unused_field
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:paralled_data/services/temp_storage_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:paralled_data/database/history_database.dart';
import 'package:paralled_data/plugin/rfid_bluetooth_plugin.dart';
import 'package:paralled_data/services/encryption_security_service.dart';

class RfidTestBluetoothConnect extends StatefulWidget {
  const RfidTestBluetoothConnect({super.key});

  @override
  State<RfidTestBluetoothConnect> createState() =>
      _RfidTestBluetoothConnectState();
}

class _RfidTestBluetoothConnectState extends State<RfidTestBluetoothConnect> {
  // =================== Trạng thái ===================
  bool _isConnected = false;
  bool _showRfidSection = false;
  bool _isBluetoothEnabled = false;
  bool _isScanning = false;
  bool _isReading = false;
  bool _isCheckingConnection = true;
  bool _isLoading = false;
  bool _isImportSyncing = false;

  String _connectedDeviceName = '';
  String _lastConnectedDeviceName = '';
  String _lastConnectedDeviceAddress = '';
  int _batteryLevel = 0;

  // =================== Danh sách & dữ liệu ===================
  final List<Map<String, String>> _deviceList = [];
  final List<Map<String, dynamic>> _rfidTags = [];
  List<Map<String, dynamic>> _localData = [];

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
  bool _encryptionInitialized = false;

  final List<DateTime> _scanTimestamps = [];
  final List<DateTime> _syncTimestamps = [];

  int get _scansInLastSecond {
    final now = DateTime.now();
    final oneSecondAgo = now.subtract(const Duration(seconds: 1));
    _scanTimestamps.removeWhere((t) => t.isBefore(oneSecondAgo));
    return _scanTimestamps.length;
  }

  int get _syncsInLastSecond {
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

  @override
  void initState() {
    super.initState();
    _initEncryption();
    _requestPermissions();
    _checkBluetoothStatus();
    _checkExistingConnection();
    _initializeListeners();
    _startSyncWorker();
    _startAutoRefresh();
  }

  Future<void> _initEncryption() async {
    if (!_encryption.isInitialized) {
      await _encryption.initializeEncryption();
      if (mounted) {
        setState(() {
          _encryptionInitialized = true;
        });
      }
      debugPrint('Encryption đã được khởi tạo');
    }
  }

  @override
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
    super.dispose();
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

  Future<void> _checkExistingConnection() async {
    try {
      final isConnected = await RfidBlePlugin.getConnectionStatus();

      if (mounted) {
        setState(() {
          _isConnected = isConnected;
          _showRfidSection = isConnected;
          _isCheckingConnection = false;
        });

        if (isConnected) {
          await _loadLocal();
          await RfidBlePlugin.getBatteryLevel();

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Đã khôi phục kết nối thiết bị'),
                duration: Duration(seconds: 2),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('Lỗi kiểm tra kết nối: $e');
      if (mounted) {
        setState(() {
          _isCheckingConnection = false;
          _showRfidSection = false;
          _isConnected = false;
        });
      }
    }
  }

  // =================== Bluetooth ===================
  Future<void> _checkBluetoothStatus() async {
    final isEnabled = await RfidBlePlugin.checkBluetoothEnabled();
    if (mounted) setState(() => _isBluetoothEnabled = isEnabled);
  }

  Future<void> _enableBluetooth() async {
    await RfidBlePlugin.enableBluetooth();
  }

  Future<void> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetooth,
      Permission.location,
      Permission.locationWhenInUse,
    ].request();

    bool allGranted =
        statuses.values.every((status) => status.isGranted || status.isLimited);

    if (!allGranted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng cấp đầy đủ quyền Bluetooth và Location'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  void _initializeListeners() {
    _scanSubscription = RfidBlePlugin.scanResults.listen(
      (device) {
        if (!mounted) return;
        setState(() {
          bool exists =
              _deviceList.any((d) => d['address'] == device['address']);
          if (!exists) _deviceList.add(device);
        });
      },
    );

    _connectionSubscription =
        RfidBlePlugin.connectionState.listen((isConnected) {
      if (!mounted) return;
      setState(() {
        _isConnected = isConnected;
        if (!isConnected) {
          _connectedDeviceName = '';
          _rfidTags.clear();
          _batteryLevel = 0;
          _showRfidSection = true;
        }
      });
    });

    _rfidSubscription = RfidBlePlugin.rfidStream.listen(
      (data) async {
        final epc = (data['epc_ascii']?.toString().trim() ?? '');
        if (epc.isEmpty || !mounted) return;

        totalCount++;
        if (uniqueEpcs.add(epc)) {
          uniqueCount++;
        }

        debugPrint('Tổng: $totalCount | Duy nhất: $uniqueCount');

        _scanTimestamps.add(DateTime.now());
        _scheduleUIUpdate(data);
        _addToBatch(data);
      },
    );

    _configSubscription = RfidBlePlugin.configStream.listen((cfg) {
      if (cfg['type'] == 'battery' && mounted) {
        setState(() {
          _batteryLevel = cfg['battery'] ?? 0;
        });
      }
    });
  }

  // =================== Scan / Connect ===================
  Future<void> _startScanBluetooth() async {
    if (!_isBluetoothEnabled) {
      await _enableBluetooth();
      return;
    }
    setState(() {
      _isScanning = true;
      _deviceList.clear();
    });
    await RfidBlePlugin.startScan();
    Future.delayed(const Duration(seconds: 10), () {
      if (_isScanning) _stopScan();
    });
  }

  Future<void> _stopScan() async {
    await RfidBlePlugin.stopScan();
    if (!mounted) return;
    setState(() => _isScanning = false);
  }

  Future<void> _connectToDevice(String name, String address) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      String result = await RfidBlePlugin.connectToDevice('', address);
      if (!mounted) return;
      Navigator.pop(context);
      if (result.isNotEmpty) {
        setState(() {
          _connectedDeviceName = name;
          _lastConnectedDeviceName = name;
          _lastConnectedDeviceAddress = address;
          _isConnected = true;
          _showRfidSection = true;
        });
        await _loadLocal();
        await RfidBlePlugin.getBatteryLevel();
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Lỗi kết nối: $e')));
    }
  }

  Future<void> _disconnect() async {
    await RfidBlePlugin.disconnectDevice();
    if (!mounted) return;
    setState(() {
      _isConnected = false;
      _connectedDeviceName = '';
      _rfidTags.clear();
      _batteryLevel = 0;
    });
  }

  // =================== UI UPDATE với THROTTLE ===================
  void _scheduleUIUpdate(Map<String, dynamic> data) {
    if (_hasPendingUIUpdate) return;

    _hasPendingUIUpdate = true;
    _uiUpdateTimer?.cancel();

    _uiUpdateTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;

      final epc = data['epc_ascii']?.toString().trim() ?? '';

      setState(() {
        int idx = _rfidTags.indexWhere((t) => t['epc_ascii'] == epc);
        if (idx >= 0) {
          _rfidTags[idx] = data;
        } else {
          _rfidTags.insert(0, data);
        }
      });

      _hasPendingUIUpdate = false;
    });
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

      await _loadLocal();
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

      await _loadLocal();
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

  Future<void> _loadLocal() async {
    final data = await HistoryDatabase.instance.getAllScans();
    if (mounted) {
      setState(() {
        _localData = data;
      });
    }
  }

  void _startAutoRefresh() {
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      await _loadLocal();
    });
  }

  void _startSyncWorker() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_isSyncing) return;
      _isSyncing = true;

      try {
        // === CHỈ ĐỒNG BỘ PENDING TRONG DB (realtime) ===
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
    if (_isImportSyncing || _isSyncing) {
      debugPrint('Sync đang chạy, bỏ qua syncRecordsFromTemp');
      return;
    }

    _isImportSyncing = true;

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

      // Gửi từng bản ghi với cả ID mới và ID cũ
      for (int i = 0; i < batch.length; i++) {
        final idLocal = ids[i];
        final data = batch[i];
        final oldIdLocal = oldIds[i];

        unawaited(_sendToServerWithOldId(data, idLocal, oldIdLocal));
      }

      debugPrint('Đã gửi ${ids.length} bản ghi từ import lên server');
      await _loadLocal();
    } catch (e) {
      debugPrint('Lỗi syncRecordsFromTemp: $e');
    } finally {
      _isImportSyncing = false;
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
        // Cập nhật DB với ID mới
        _addStatusUpdate(
          idLocal: newIdLocal,
          status: 'synced',
          syncDurationMs: syncDurationMs,
        );

        // CẬP NHẬT FILE TẠM VỚI ID CŨ
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

    // Cập nhật DB
    _addStatusUpdate(idLocal: newIdLocal, status: 'failed', error: error);

    // Cập nhật file tạm với ID cũ
    await TempStorageService().updateSyncStatus(
      idLocal: oldIdLocal,
      syncStatus: 'failed',
      syncError: error,
    );

    _syncController.add({'id': newIdLocal, 'status': 'failed'});
    _retryCounter.remove(newIdLocal);
  }

  /// Gửi lên server + lưu vào file tạm khi thành công
  Future<void> _sendToServerAndSaveToTemp(
      Map<String, dynamic> data, String idLocal) async {
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

        await TempStorageService().updateSyncStatus(
          idLocal: idLocal,
          syncStatus: 'synced',
          syncDurationMs: syncDurationMs,
        );

        await _loadLocal();
      } else {
        await _handleUploadRetryFail(
            idLocal, data, 'Server error ${response.statusCode}');
      }
    } catch (e) {
      stopwatch.stop();
      await _handleUploadRetryFail(idLocal, data, e.toString());
    } finally {
      _sendingIds.remove(idLocal);
      _activeRequests--;

      if (_requestQueue.isNotEmpty) {
        final next = _requestQueue.removeAt(0);
        unawaited(_sendToServer(next.data, next.idLocal));
      }
    }
  }

  /// Xử lý thất bại khi upload từ file tạm
  Future<void> _handleUploadRetryFail(
      String idLocal, Map<String, dynamic> data, String error) async {
    _retryCounter[idLocal] = (_retryCounter[idLocal] ?? 0) + 1;
    final retryCount = _retryCounter[idLocal]!;

    if (retryCount <= 1) {
      await Future.delayed(const Duration(milliseconds: 500));
      unawaited(_sendToServerAndSaveToTemp(data, idLocal));
      return;
    }

    // Lưu failed vào file tạm
    await TempStorageService().appendBatch([
      {
        'id_local': idLocal,
        'epc': data['epc'] ?? '',
        'sync_status': 'failed',
        'scan_duration_ms': data['scan_duration_ms'],
        'epc_hex': data['epc_hex'],
        'tid_hex': data['tid_hex'],
        'user_hex': data['user_hex'],
        'rssi': data['rssi'],
        'count': data['count'],
        'sync_error': error,
      }
    ]);

    await TempStorageService().updateSyncStatus(
      idLocal: idLocal,
      syncStatus: 'failed',
      syncError: error,
    );

    await _loadLocal();
    _retryCounter.remove(idLocal);
  }

  // =================== Connection Status ===================
  Widget _buildConnectionStatus() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: _isConnected ? Colors.green.shade100 : Colors.grey.shade200,
      child: Row(
        children: [
          Icon(
            _isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            color: _isConnected ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isConnected ? 'Đã kết nối' : 'Chưa kết nối',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                if (_isConnected)
                  Text(
                    _connectedDeviceName,
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 14),
                  )
                else if (_lastConnectedDeviceName.isNotEmpty)
                  Text(
                    _lastConnectedDeviceName,
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 14),
                  ),
              ],
            ),
          ),
          _buildActionButton(),
        ],
      ),
    );
  }

  Widget _buildActionButton() {
    if (_showRfidSection) {
      return ElevatedButton.icon(
        onPressed: _isConnected
            ? _disconnect
            : (_lastConnectedDeviceAddress.isNotEmpty
                ? () => _connectToDevice(
                    _lastConnectedDeviceName, _lastConnectedDeviceAddress)
                : null),
        icon: Icon(_isConnected ? Icons.close : Icons.bluetooth),
        label: Text(_isConnected ? 'Ngắt' : 'Kết nối lại'),
        style: ElevatedButton.styleFrom(
          backgroundColor: _isConnected ? Colors.red : null,
        ),
      );
    }
    return ElevatedButton.icon(
      onPressed: _isScanning ? _stopScan : _startScanBluetooth,
      icon: Icon(_isScanning ? Icons.stop : Icons.search),
      label: Text(_isScanning ? 'Dừng' : 'Scan'),
    );
  }

  // =================== Device List ===================
  Widget _buildDeviceList() {
    if (!_isBluetoothEnabled) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.bluetooth_disabled, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('Bluetooth chưa được bật',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _enableBluetooth,
              icon: const Icon(Icons.bluetooth),
              label: const Text('Bật Bluetooth'),
            ),
          ],
        ),
      );
    }

    if (_deviceList.isEmpty && !_isScanning) {
      return const Center(child: Text('Nhấn "Scan" để tìm thiết bị Bluetooth'));
    }

    if (_isScanning && _deviceList.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Đang tìm kiếm thiết bị...'),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _deviceList.length,
      itemBuilder: (context, i) {
        final device = _deviceList[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: ListTile(
            leading: const Icon(Icons.bluetooth, color: Colors.blue),
            title: Text(device['name'] ?? 'Unknown'),
            subtitle: Text(device['address'] ?? ''),
            trailing: ElevatedButton(
              onPressed: () => _connectToDevice(
                  device['name'] ?? 'Unknown', device['address'] ?? ''),
              child: const Text('Kết nối'),
            ),
          ),
        );
      },
    );
  }

  // =================== Xem file tạm ===================
  Future<void> _showTempFileDialog() async {
    try {
      final tempData = List<Map<String, dynamic>>.from(
        await TempStorageService().readAllTempData(),
      ).reversed.toList();

      final count = tempData.length;
      final filePath = await TempStorageService().getTempFilePath();

      if (!mounted) return;

      showDialog(
        context: context,
        builder: (context) => Dialog(
          child: Container(
            width: MediaQuery.of(context).size.width * 0.9,
            height: MediaQuery.of(context).size.height * 0.8,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Dữ liệu File Tạm',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Row(
                          children: [
                            Icon(
                              _encryptionInitialized
                                  ? Icons.lock
                                  : Icons.lock_open,
                              size: 14,
                              color: _encryptionInitialized
                                  ? Colors.green
                                  : Colors.orange,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _encryptionInitialized
                                  ? 'Đã mã hóa'
                                  : 'Chưa mã hóa',
                              style: TextStyle(
                                fontSize: 11,
                                color: _encryptionInitialized
                                    ? Colors.green
                                    : Colors.orange,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Tổng số: $count records',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Đường dẫn: $filePath',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const Divider(height: 20),
                Expanded(
                  child: tempData.isEmpty
                      ? const Center(child: Text('File tạm trống'))
                      : ListView.builder(
                          itemCount: tempData.length,
                          itemBuilder: (context, index) {
                            final item = tempData[index];
                            final jsonStr = const JsonEncoder.withIndent('  ')
                                .convert(item);

                            return Card(
                              margin: const EdgeInsets.only(bottom: 12),
                              child: ExpansionTile(
                                title: Text(
                                  '${index + 1}. ${item['epc'] ?? 'N/A'}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text(
                                  'Status: ${item['sync_status'] ?? 'N/A'}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                children: [
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(12),
                                    color: Colors.grey.shade100,
                                    child: SelectableText(
                                      jsonStr,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 12),

                // ✅ Nút Export/Download
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () => _showDownloadOptionsDialog(),
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Tải về'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => _showImportOptionsDialog(),
                      icon: const Icon(Icons.upload, size: 18),
                      label: const Text('Import'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Xác nhận'),
                            content: const Text(
                                'Bạn có chắc muốn xóa toàn bộ dữ liệu file tạm?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Hủy'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Xóa'),
                              ),
                            ],
                          ),
                        );

                        if (confirm == true) {
                          await TempStorageService().clearTempFile();
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Đã xóa dữ liệu file tạm')),
                          );
                        }
                      },
                      icon: const Icon(Icons.delete, size: 18),
                      label: const Text('Xóa file tạm'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      debugPrint('❌ Lỗi khi hiển thị file tạm: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi: $e')),
      );
    }
  }

  Future<void> _showDownloadOptionsDialog() async {
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Chọn định dạng tải về'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.lock, color: Colors.green),
                title: const Text('File mã hóa (.encrypted)'),
                subtitle: const Text('Bảo mật, cần key để đọc'),
                onTap: () async {
                  Navigator.pop(context);
                  await _downloadEncrypted();
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.description, color: Colors.blue),
                title: const Text('File JSON (đã giải mã)'),
                subtitle: const Text('Dễ đọc, không bảo mật'),
                onTap: () async {
                  Navigator.pop(context);
                  await _downloadJson();
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.table_chart, color: Colors.orange),
                title: const Text('File CSV (đã giải mã)'),
                subtitle: const Text('Excel, không bảo mật'),
                onTap: () async {
                  Navigator.pop(context);
                  await _downloadCsv();
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy'),
            ),
          ],
        );
      },
    );
  }

  /// ✅ Download file encrypted
  Future<void> _downloadEncrypted() async {
    try {
      final path = await TempStorageService().downloadEncryptedFile();
      if (!mounted) return;

      if (path != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Đã lưu file mã hóa: $path'),
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ Lỗi khi lưu file')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Lỗi: $e')),
      );
    }
  }

  /// ✅ Download file JSON (đã giải mã)
  Future<void> _downloadJson() async {
    try {
      final path = await TempStorageService().downloadDecryptedJson();
      if (!mounted) return;

      if (path != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Đã lưu file JSON: $path'),
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ Lỗi khi lưu file')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Lỗi: $e')),
      );
    }
  }

  /// ✅ Download file CSV (đã giải mã)
  Future<void> _downloadCsv() async {
    try {
      final path = await TempStorageService().downloadDecryptedCSV();
      if (!mounted) return;

      if (path != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Đã lưu file CSV: $path'),
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ Lỗi khi lưu file')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Lỗi: $e')),
      );
    }
  }

  /// ✅ Dialog chọn loại import
  Future<void> _showImportOptionsDialog() async {
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Import file'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.lock, color: Colors.green),
                title: const Text('Import file mã hóa'),
                subtitle: const Text('.encrypted'),
                onTap: () async {
                  Navigator.pop(context);
                  await _importEncrypted();
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.description, color: Colors.blue),
                title: const Text('Import file thường'),
                subtitle: const Text('JSON, CSV'),
                onTap: () async {
                  Navigator.pop(context);
                  await _importPlain();
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy'),
            ),
          ],
        );
      },
    );
  }

  /// ✅ Import file mã hóa
  Future<void> _importEncrypted() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      final result = await TempStorageService().importEncryptedFile();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message']),
          backgroundColor: result['success'] ? Colors.green : Colors.red,
        ),
      );

      if (result['success']) {
        await syncRecordsFromTemp(); // ← GỌI HÀM MỚI
        await _loadLocal();
      }
    } catch (e) {
      debugPrint('Import encrypted error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Lỗi import: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Import file plain (JSON/CSV)
  Future<void> _importPlain() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      final result = await TempStorageService().importPlainFile();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message']),
          backgroundColor: result['success'] ? Colors.green : Colors.red,
        ),
      );

      if (result['success']) {
        await syncRecordsFromTemp(); // ← GỌI HÀM MỚI
        await _loadLocal();
      }
    } catch (e) {
      debugPrint('Import plain error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Lỗi import: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // =================== RFID Section ===================
  Widget _buildRfidSection() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: (!_isConnected)
                    ? null
                    : (_isReading ? _stopReading : _startReading),
                icon: Icon(_isReading ? Icons.stop : Icons.play_arrow),
                label: Text(_isReading ? 'Dừng quét' : 'Quét liên tục'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isReading ? Colors.red : Colors.green,
                ),
              ),
              ElevatedButton.icon(
                onPressed: (!_isConnected || _isReading) ? null : _singleRead,
                icon: const Icon(Icons.radar),
                label: const Text('Quét 1 lần'),
              ),
              ElevatedButton.icon(
                onPressed: _clearHistory,
                icon: const Icon(Icons.delete_forever),
                label: const Text('Xóa lịch sử'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                ),
              ),
              ElevatedButton.icon(
                onPressed: _loadLocal,
                icon: const Icon(Icons.refresh),
                label: const Text('Tải lại'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.limeAccent,
                ),
                onPressed: _showTempFileDialog,
                child: const Text('Xem file tạm'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Container(
                      height: 90,
                      color: Colors.blue.shade50,
                      padding: const EdgeInsets.all(8),
                      width: double.infinity,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            'Dữ liệu đã quét',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.blue,
                            ),
                          ),
                          Text(
                            '(${_localData.length})',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.blueGrey,
                            ),
                          ),
                          Text(
                            'Tốc độ: $_scansInLastSecond mã/giây',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(child: _buildScannedList()),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    Container(
                      height: 90,
                      color: Colors.green.shade50,
                      padding: const EdgeInsets.all(8),
                      width: double.infinity,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            'Dữ liệu đồng bộ',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.green,
                            ),
                          ),
                          Text(
                            '(${_localData.where((e) => e['status'] == 'synced').length}/${_localData.length})',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.green,
                            ),
                          ),
                          Text(
                            'Tốc độ: $_syncsInLastSecond mã/giây',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.green,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(child: _buildSyncedList()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildScannedList() {
    if (_localData.isEmpty) return const Center(child: Text('Chưa có dữ liệu'));
    return ListView.builder(
      itemCount: _localData.length,
      itemBuilder: (_, i) {
        final item = _localData[i];
        final scanDuration = item['scan_duration_ms'];
        return Container(
          height: 80,
          decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.black12))),
          child: ListTile(
            title: Text(
              _localData[i]['epc'] ?? '---',
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Trạng thái: ${item['status'] ?? '---'}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                if (scanDuration != null)
                  Text(
                    'Tốc độ quét: ${scanDuration.toStringAsFixed(2)}ms/mã',
                    style: const TextStyle(fontSize: 11, color: Colors.blue),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSyncedList() {
    if (_localData.isEmpty) {
      return const Center(child: Text('Không có dữ liệu đồng bộ'));
    }

    final statusMap = {
      'pending': 'Đang chờ',
      'synced': 'Thành công',
      'failed': 'Thất bại'
    };

    return ListView.builder(
      itemCount: _localData.length,
      itemBuilder: (_, i) {
        final item = _localData[i];
        final status = item['status'] ?? 'pending';
        final statusText = statusMap[status] ?? status;
        final syncDuration = item['sync_duration_ms'];

        Color backgroundColor;
        // ignore: unused_local_variable
        Color textColor;

        switch (status) {
          case 'synced':
            backgroundColor = const Color(0xFFE8F5E9);
            textColor = Colors.green;
            break;
          case 'failed':
            backgroundColor = const Color(0xFFFFEBEE);
            textColor = Colors.red;
            break;
          default:
            backgroundColor = const Color(0xFFFFF8E1);
            textColor = Colors.orange;
        }

        return Container(
          height: 80,
          decoration: BoxDecoration(
            color: backgroundColor,
            border: const Border(bottom: BorderSide(color: Colors.black12)),
          ),
          child: ListTile(
            title: Text(
              item['epc'] ?? '---',
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Trạng thái: $statusText',
                  style: TextStyle(
                    fontSize: 13,
                    color: status == 'synced'
                        ? Colors.green
                        : (status == 'failed' ? Colors.red : Colors.orange),
                  ),
                ),
                if (syncDuration != null && status == 'synced')
                  Text(
                    'Tốc độ đồng bộ: ${syncDuration.toStringAsFixed(2)}ms/mã',
                    style: const TextStyle(fontSize: 11, color: Colors.green),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // =================== UI ===================
  @override
  Widget build(BuildContext context) {
    if (_isCheckingConnection) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('RFID Bluetooth - Đồng bộ'),
        ),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Đang kiểm tra kết nối...'),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Expanded(
              child: Text(
                'RFID Bluetooth - Đồng bộ',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              _encryptionInitialized ? Icons.lock : Icons.lock_open,
              size: 18,
              color: _encryptionInitialized ? Colors.white : Colors.orange,
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Icon(
                  _isBluetoothEnabled
                      ? Icons.bluetooth
                      : Icons.bluetooth_disabled,
                  size: 20,
                  color: _isBluetoothEnabled ? Colors.blue : Colors.red,
                ),
                if (!_isBluetoothEnabled)
                  TextButton(
                    onPressed: _enableBluetooth,
                    child: const Text('Bật', style: TextStyle(fontSize: 12)),
                  ),
                if (_isConnected)
                  Row(
                    children: [
                      const SizedBox(width: 8),
                      const Icon(Icons.battery_charging_full, size: 20),
                      const SizedBox(width: 4),
                      Text('$_batteryLevel%'),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildConnectionStatus(),
          Expanded(
            child: _showRfidSection ? _buildRfidSection() : _buildDeviceList(),
          ),
        ],
      ),
    );
  }

  Future<void> _singleRead() async {
    if (!_isConnected) return;
    await RfidBlePlugin.singleInventory();
  }

  Future<void> _startReading() async {
    if (!_isConnected) return;
    await RfidBlePlugin.startInventory();
    if (!mounted) return;
    setState(() => _isReading = true);
  }

  Future<void> _stopReading() async {
    if (!_isConnected) return;

    _batchTimer?.cancel();
    _batchTimer = null;
    _uiUpdateTimer?.cancel();
    _uiUpdateTimer = null;

    await RfidBlePlugin.stopInventory();
    _isReading = false;

    // if (!mounted) return;
    // setState(() => _isReading = false);

    await _flushBatch(force: true);
    await TempStorageService().flushQueue();

    debugPrint('✅ Dừng scan liên tục hoàn tất');
  }

  Future<void> _clearHistory() async {
    await HistoryDatabase.instance.clearHistory();
    await _loadLocal();
    _rfidTags.clear();
    _retryCounter.clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã xóa lịch sử')),
      );
    }
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
  _StatusUpdate(
      {required this.idLocal,
      required this.status,
      this.syncDurationMs,
      this.error});
}
