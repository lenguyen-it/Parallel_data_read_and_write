import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:paralled_data/database/history_database.dart';
import 'package:paralled_data/plugin/rfid_c72_plugin.dart';
import 'package:paralled_data/services/temp_storage_service.dart';

class BarcodeScanService {
  bool isConnected = false;
  bool isConnecting = false;
  bool isScanning = false;
  bool isContinuousMode = false;

  final StreamController<Map<String, dynamic>> _codeController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get codeStream => _codeController.stream;

  final StreamController<Map<String, dynamic>> _syncController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get syncStream => _syncController.stream;

  final StreamController<int> _dbCountController =
      StreamController<int>.broadcast();
  Stream<int> get dbCountStream => _dbCountController.stream;

  Timer? _uiUpdateTimer;

  final Set<String> _sendingIds = {};
  final List<_QueuedRequest> _requestQueue = [];
  int _activeRequests = 0;
  static const int maxConcurrentRequests = 3;

  final Map<String, int> _retryCounter = {};
  static const String serverUrl = 'http://192.168.15.194:5000/api/scans';

  static const int batchSize = 25;
  static const Duration batchInterval = Duration(milliseconds: 300);
  final List<Map<String, dynamic>> _pendingBatch = [];
  Timer? _batchTimer;

  bool _isFlushingBatch = false;

  int totalCount = 0;
  int uniqueCount = 0;
  final Set<String> uniqueCodes = {};

  final int maxConnectRetry = 3;
  int _currentRetry = 0;
  int retryDelaySeconds = 3;

  final List<_StatusUpdate> _statusUpdateQueue = [];
  Timer? _statusUpdateTimer;
  bool _isUpdatingStatus = false;

  /// Kết nối đến thiết bị Barcode
  Future<void> connect() async {
    if (isConnected || isConnecting) return;
    isConnecting = true;
    try {
      final ok = await RfidC72Plugin.connectBarcode;
      isConnected = ok == true;
      if (!isConnected && _currentRetry < maxConnectRetry) {
        _currentRetry++;
        Future.delayed(Duration(seconds: retryDelaySeconds), connect);
      }
    } catch (e) {
      debugPrint('Barcode connect error: $e');
    } finally {
      isConnecting = false;
    }
  }

  /// Quét một lần
  Future<void> startSingleScan() async {
    if (!isConnected) throw Exception('Chưa kết nối thiết bị');
    isScanning = true;
    try {
      attachBarcodeStream();
      await RfidC72Plugin.scanBarcodeSingle;
    } catch (e) {
      debugPrint('Single barcode scan error: $e');
    } finally {
      isScanning = false;
    }
  }

  /// Quét liên tục
  Future<void> startContinuousScan() async {
    if (!isConnected) throw Exception('Chưa kết nối thiết bị');
    isContinuousMode = true;
    isScanning = true;

    try {
      await RfidC72Plugin.scanBarcodeContinuous;
      attachBarcodeStream();
    } catch (e) {
      debugPrint('Continuous barcode scan error: $e');
      isContinuousMode = false;
      isScanning = false;
    }
  }

  /// Dừng quét
  Future<void> stopScan() async {
    try {
      _batchTimer?.cancel();
      _batchTimer = null;
      _uiUpdateTimer?.cancel();
      _uiUpdateTimer = null;
      _statusUpdateTimer?.cancel();
      _statusUpdateTimer = null;

      RfidC72Plugin.stopScanBarcode;
      isScanning = false;
      isContinuousMode = false;

      if (_pendingBatch.isNotEmpty) {
        await _flushBatch(force: true);
      }

      if (_statusUpdateQueue.isNotEmpty) {
        await _processBatchStatusUpdate();
      }

      await TempStorageService().flushQueue();

      debugPrint('✅ Stop barcode scan hoàn tất');
    } catch (e) {
      debugPrint('Stop barcode scan error: $e');
    }
  }

  /// Xem các giá trị trả về từ stream khi quét
  void attachBarcodeStream() {
    RfidC72Plugin.barcodeStatusStream.receiveBroadcastStream().listen(
      (event) async {
        if (event == null) return;

        Map<String, dynamic> data;
        if (event is Map) {
          data = Map<String, dynamic>.from(event);
        } else if (event is String) {
          if (event == 'SCANNING' || event == 'STOPPED' || event.isEmpty) {
            return;
          }
          try {
            data = jsonDecode(event);
          } catch (_) {
            // Nếu không parse được, coi như string thuần
            return;
          }
        } else {
          return;
        }

        final code = data['barcode']?.toString() ?? '';
        if (code.trim().isEmpty) return;

        final normalized = _normalizeCode(code);

        totalCount++;
        if (uniqueCodes.add(normalized)) {
          uniqueCount++;
        }

        debugPrint('Tổng: $totalCount | Duy nhất: $uniqueCount');

        final processedData = {
          'epc': normalized,
          'scan_duration_ms': data['barcode_scan_duration_ms'] ?? 0,
        };

        _codeController.add(processedData);
        _addToBatch(processedData);
      },
      onError: (err) {
        _codeController.addError(err.toString());
      },
    );
  }

  String _normalizeCode(String raw) {
    if (raw.contains('://')) {
      final parts = raw.split('/');
      return parts.isNotEmpty ? parts.last.trim() : raw.trim();
    }
    return raw.trim();
  }

  /// Thêm dữ liệu vào batch chờ xử lý
  void _addToBatch(Map<String, dynamic> data) {
    _pendingBatch.add({
      'epc': data['epc'] ?? '',
      'scan_duration_ms': data['scan_duration_ms'],
    });

    if (_pendingBatch.length >= batchSize) {
      _scheduleFlush();
      return;
    }

    _batchTimer?.cancel();
    _batchTimer = Timer(batchInterval, () => _scheduleFlush());
  }

  Future<void> _scheduleFlush({bool force = false}) async {
    if (!force && _pendingBatch.isEmpty) return;
    if (_isFlushingBatch) return;

    await _flushBatch(force: force);
  }

  /// Xử lý gửi batch lên server và lưu vào DB
  Future<void> _flushBatch({bool force = false}) async {
    if (_isFlushingBatch) return;
    _isFlushingBatch = true;

    try {
      while (_pendingBatch.isNotEmpty) {
        final batch = List<Map<String, dynamic>>.from(_pendingBatch);
        _pendingBatch.clear();
        _batchTimer?.cancel();
        _batchTimer = null;

        final ids = await HistoryDatabase.instance.batchInsertScans(batch);
        if (ids.isEmpty) {
          continue;
        }

        final List<Map<String, dynamic>> items = [];
        for (int i = 0; i < batch.length; i++) {
          items.add({
            'id_local': ids[i],
            'sync_status': 'pending',
            ...batch[i],
          });
        }

        await TempStorageService().appendBatch(items);

        final newCount = await HistoryDatabase.instance.getScansCount();
        _dbCountController.add(newCount);

        for (int i = 0; i < batch.length; i++) {
          unawaited(_sendToServer(batch[i], ids[i]));
        }

        debugPrint('Total DB: $newCount');
      }
    } catch (e, st) {
      debugPrint('❌ Lỗi khi flush batch: $e\n$st');
    } finally {
      _isFlushingBatch = false;
    }
  }

  /// Gửi dữ liệu lên server từng mã quét
  Future<void> _sendToServer(Map<String, dynamic> data, String idLocal) async {
    final code = data['epc'] ?? '';

    if (_sendingIds.contains(idLocal)) return;

    _sendingIds.add(idLocal);
    _activeRequests++;

    final DateTime startTime = DateTime.now();
    final Stopwatch stopwatch = Stopwatch()..start();

    final body = {
      'epc': code,
      'scan_duration_ms': data['scan_duration_ms'],
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
      final double syncDurationMs = stopwatch.elapsedMilliseconds.toDouble();

      if (response.statusCode == 200 || response.statusCode == 201) {
        _addStatusUpdate(
          idLocal: idLocal,
          status: 'synced',
          syncDurationMs: syncDurationMs,
        );

        _syncController.add({
          'id': idLocal,
          'sync_duration_ms': syncDurationMs,
          'status': 'synced',
        });
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

  /// Cập nhật trạng thái (synced/failed) vào hàng đợi
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

  /// Xử lý cập nhật trạng thái hàng loạt vào DB
  Future<void> _processBatchStatusUpdate() async {
    if (_isUpdatingStatus || _statusUpdateQueue.isEmpty) return;

    _isUpdatingStatus = true;

    try {
      final updates = List<_StatusUpdate>.from(_statusUpdateQueue);
      _statusUpdateQueue.clear();

      // Update DB với transaction
      await HistoryDatabase.instance.batchUpdateStatus(updates);

      // Update file tạm
      for (final update in updates) {
        await TempStorageService().updateSyncStatus(
          idLocal: update.idLocal,
          syncStatus: update.status,
          syncDurationMs: update.syncDurationMs,
          syncError: update.error,
        );
      }
    } catch (e) {
      debugPrint('❌ Lỗi batch update status: $e');
    } finally {
      _isUpdatingStatus = false;

      // Nếu còn trong queue, xử lý tiếp
      if (_statusUpdateQueue.isNotEmpty) {
        unawaited(_processBatchStatusUpdate());
      }
    }
  }

  /// Xử lý khi gửi lên server thất bại
  Future<void> _handleRetryFail(
      String idLocal, Map<String, dynamic> data, String error) async {
    _retryCounter[idLocal] = (_retryCounter[idLocal] ?? 0) + 1;
    final retryCount = _retryCounter[idLocal]!;

    if (retryCount <= 1) {
      // Đợi 0.5s rồi gửi lại
      await Future.delayed(const Duration(milliseconds: 500));
      Future.microtask(() => _sendToServer(data, idLocal));
      return;
    }

    _addStatusUpdate(
      idLocal: idLocal,
      status: 'failed',
      error: error,
    );

    _syncController.add({
      'id': idLocal,
      'status': 'failed',
    });

    _retryCounter.remove(idLocal);
  }

  /// Đồng bộ các bản ghi từ file tạm
  Future<void> syncRecordsFromTemp() async {
    try {
      final records = await TempStorageService().getUnsyncedRecords();

      if (records.isEmpty) {
        debugPrint('ℹ️ Không có bản ghi để đồng bộ');
        return;
      }

      debugPrint(
          '📤 Bắt đầu đồng bộ ${records.length} bản ghi (pending/failed)');

      final List<Map<String, dynamic>> batch = [];
      for (var record in records) {
        batch.add({
          'epc': record['epc']?.toString() ?? '',
          'scan_duration_ms': record['scan_duration_ms'],
        });
      }

      // Thêm vào database
      final ids = await HistoryDatabase.instance.batchInsertScans(batch);
      if (ids.isEmpty) {
        debugPrint('⚠️ Không thể thêm bản ghi vào database');
        return;
      }

      for (int i = 0; i < batch.length; i++) {
        final idLocal = ids[i];
        final record = batch[i];
        final oldIdLocal = records[i]['id_local']?.toString() ?? '';

        // Gửi lên server với ID mới
        unawaited(_sendToServerWithOldId(record, idLocal, oldIdLocal));
      }

      debugPrint('✅ Đã gửi ${ids.length} bản ghi để đồng bộ');
    } catch (e) {
      debugPrint('❌ Lỗi khi đồng bộ pending records: $e');
    }
  }

  /// Gửi lên server và cập nhật cả ID cũ trong file tạm
  Future<void> _sendToServerWithOldId(
      Map<String, dynamic> data, String newIdLocal, String oldIdLocal) async {
    final code = data['epc'] ?? '';

    if (_sendingIds.contains(newIdLocal)) return;

    _sendingIds.add(newIdLocal);
    _activeRequests++;

    final DateTime startTime = DateTime.now();
    final Stopwatch stopwatch = Stopwatch()..start();

    final body = {
      'epc': code,
      'scan_duration_ms': data['scan_duration_ms'],
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
      final double syncDurationMs = stopwatch.elapsedMilliseconds.toDouble();

      if (response.statusCode == 200 || response.statusCode == 201) {
        // Cập nhật DB với ID mới
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

        _syncController.add({
          'id': newIdLocal,
          'sync_duration_ms': syncDurationMs,
          'status': 'synced',
        });
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

  /// Xử lý khi gửi lên server thất bại với ID mới và cũ
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
    _addStatusUpdate(
      idLocal: newIdLocal,
      status: 'failed',
      error: error,
    );

    await TempStorageService().updateSyncStatus(
      idLocal: oldIdLocal,
      syncStatus: 'failed',
      syncError: error,
    );

    _syncController.add({
      'id': newIdLocal,
      'status': 'failed',
    });

    _retryCounter.remove(newIdLocal);
  }

  /// Đồng bộ các bản ghi từ file upload
  Future<void> syncRecordsFromUpload(List<Map<String, dynamic>> records) async {
    try {
      if (records.isEmpty) {
        debugPrint('Không có bản ghi để đồng bộ');
        return;
      }

      // Lọc chỉ lấy pending/failed
      final unsyncedRecords = records.where((record) {
        final status = record['sync_status']?.toString() ?? 'pending';
        return status == 'pending' || status == 'failed';
      }).toList();

      if (unsyncedRecords.isEmpty) {
        debugPrint('Tất cả records đã được sync, không cần gửi lại');
        return;
      }

      debugPrint(
          '📤 Bắt đầu đồng bộ ${unsyncedRecords.length} bản ghi (pending/failed)');

      // Chuẩn bị batch để insert vào DB
      final List<Map<String, dynamic>> batch = [];
      for (var record in unsyncedRecords) {
        batch.add({
          'epc': record['epc']?.toString() ?? '',
          'scan_duration_ms': record['scan_duration_ms'],
        });
      }

      // Thêm vào database
      final ids = await HistoryDatabase.instance.batchInsertScans(batch);
      if (ids.isEmpty) {
        debugPrint('⚠️ Không thể thêm bản ghi vào database');
        return;
      }

      // Gửi lên server
      for (int i = 0; i < batch.length; i++) {
        final idLocal = ids[i];
        final record = batch[i];

        // Gửi với callback để lưu vào file tạm khi thành công
        unawaited(_sendToServerAndSaveToTemp(record, idLocal));
      }

      debugPrint('✅ Đã gửi ${ids.length} bản ghi để đồng bộ');
    } catch (e) {
      debugPrint('❌ Lỗi khi đồng bộ upload records: $e');
    }
  }

  /// Gửi lên server và CHỈ lưu vào file tạm khi thành công
  Future<void> _sendToServerAndSaveToTemp(
      Map<String, dynamic> data, String idLocal) async {
    final code = data['epc'] ?? '';

    if (_sendingIds.contains(idLocal)) return;

    _sendingIds.add(idLocal);
    _activeRequests++;

    final DateTime startTime = DateTime.now();
    final Stopwatch stopwatch = Stopwatch()..start();

    final body = {
      'epc': code,
      'scan_duration_ms': data['scan_duration_ms'],
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
      final double syncDurationMs = stopwatch.elapsedMilliseconds.toDouble();

      if (response.statusCode == 200 || response.statusCode == 201) {
        await TempStorageService().appendBatch([
          {
            'id_local': idLocal,
            'epc': code,
            'sync_status': 'synced',
            'scan_duration_ms': data['scan_duration_ms'],
            'sync_timestamp': DateTime.now().toIso8601String(),
            'sync_duration_ms': syncDurationMs,
          }
        ]);

        // Cập nhật DB
        _addStatusUpdate(
          idLocal: idLocal,
          status: 'synced',
          syncDurationMs: syncDurationMs,
        );

        _syncController.add({
          'id': idLocal,
          'sync_duration_ms': syncDurationMs,
          'status': 'synced',
        });
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

  /// Xử lý khi gửi lên server thất bại nhưng cho file upload
  Future<void> _handleUploadRetryFail(
      String idLocal, Map<String, dynamic> data, String error) async {
    _retryCounter[idLocal] = (_retryCounter[idLocal] ?? 0) + 1;
    final retryCount = _retryCounter[idLocal]!;

    if (retryCount <= 1) {
      await Future.delayed(const Duration(milliseconds: 500));
      Future.microtask(() => _sendToServerAndSaveToTemp(data, idLocal));
      return;
    }

    await TempStorageService().appendBatch([
      {
        'id_local': idLocal,
        'epc': data['epc'] ?? '',
        'sync_status': 'failed',
        'scan_duration_ms': data['scan_duration_ms'],
        'sync_error': error,
      }
    ]);

    // Cập nhật DB
    _addStatusUpdate(
      idLocal: idLocal,
      status: 'failed',
      error: error,
    );

    _syncController.add({
      'id': idLocal,
      'status': 'failed',
    });

    _retryCounter.remove(idLocal);
  }

  /// Tiện ích - Load lịch sử
  Future<List<Map<String, dynamic>>> loadRecent() =>
      HistoryDatabase.instance.getAllScans();

  /// Tiện ích - Xóa lịch sử
  Future<void> clearHistory() => HistoryDatabase.instance.clearHistory();

  void dispose() {
    _codeController.close();
    _syncController.close();
    _dbCountController.close();
    _batchTimer?.cancel();
    _uiUpdateTimer?.cancel();
    _statusUpdateTimer?.cancel();
    TempStorageService().clearTempFile();
    RfidC72Plugin.stopScanBarcode;
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
