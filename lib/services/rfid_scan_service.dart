import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:paralled_data/database/history_database.dart';
import 'package:paralled_data/plugin/rfid_c72_plugin.dart';
import 'package:paralled_data/services/temp_storage_service.dart';

class RfidScanService {
  bool isConnected = false;
  bool isConnecting = false;
  bool isScanning = false;
  bool isContinuousMode = false;

  final StreamController<Map<String, dynamic>> _tagController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get tagStream => _tagController.stream;

  final StreamController<Map<String, dynamic>> _syncController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get syncStream => _syncController.stream;

  final StreamController<int> _dbCountController =
      StreamController<int>.broadcast();
  Stream<int> get dbCountStream => _dbCountController.stream;

  Timer? _uiUpdateTimer;

  final Set<String> _sendingIds = {};
  // final Set<String> _recentEpcs = {};
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
  final Set<String> uniqueEpcs = {};

  final int maxConnectRetry = 3;
  int _currentRetry = 0;
  int retryDelaySeconds = 3;

  final List<_StatusUpdate> _statusUpdateQueue = [];
  Timer? _statusUpdateTimer;
  bool _isUpdatingStatus = false;

  Future<void> connect() async {
    if (isConnected || isConnecting) return;
    isConnecting = true;
    try {
      final ok = await RfidC72Plugin.connect;
      isConnected = ok == true;
      if (!isConnected && _currentRetry < maxConnectRetry) {
        _currentRetry++;
        Future.delayed(Duration(seconds: retryDelaySeconds), connect);
      }
    } catch (e) {
      debugPrint('RFID connect error: $e');
    } finally {
      isConnecting = false;
    }
  }

  Future<void> startSingleScan() async {
    if (!isConnected) throw Exception('Chưa kết nối thiết bị');
    isScanning = true;
    try {
      await RfidC72Plugin.startSingle;
    } catch (e) {
      debugPrint('Single scan error: $e');
    } finally {
      isScanning = false;
    }
  }

  Future<void> startContinuousScan() async {
    if (!isConnected) throw Exception('Chưa kết nối thiết bị');
    isContinuousMode = true;
    isScanning = true;

    try {
      await RfidC72Plugin.startContinuous;
      attachTagStream();
    } catch (e) {
      debugPrint('Continuous scan error: $e');
      isContinuousMode = false;
      isScanning = false;
    }
  }

  Future<void> stopScan() async {
    try {
      _batchTimer?.cancel();
      _batchTimer = null;
      _uiUpdateTimer?.cancel();
      _uiUpdateTimer = null;
      _statusUpdateTimer?.cancel();
      _statusUpdateTimer = null;

      await RfidC72Plugin.stopScan;
      isScanning = false;
      isContinuousMode = false;

      if (_pendingBatch.isNotEmpty) {
        await _flushBatch(force: true);
      }

      if (_statusUpdateQueue.isNotEmpty) {
        await _processBatchStatusUpdate();
      }

      await TempStorageService().flushQueue();

      debugPrint('✅ Stop scan hoàn tất');
    } catch (e) {
      debugPrint('Stop scan error: $e');
    }
  }

  void attachTagStream() {
    RfidC72Plugin.tagsStatusStream.receiveBroadcastStream().listen(
      (event) async {
        if (event == null) return;

        Map<String, dynamic> data;
        if (event is Map) {
          data = Map<String, dynamic>.from(event);
        } else if (event is String) {
          try {
            data = jsonDecode(event);
          } catch (_) {
            return;
          }
        } else {
          return;
        }

        final epc = data['epc_ascii'] ?? '';
        if (epc.toString().trim().isEmpty) return;

        totalCount++;
        if (uniqueEpcs.add(epc)) {
          uniqueCount++;
        }

        debugPrint('Tổng: $totalCount | Duy nhất: $uniqueCount');

        _tagController.add(data);
        _addToBatch(data);
      },
      onError: (err) {
        _tagController.addError(err.toString());
      },
    );
  }

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

  Future<void> _sendToServer(Map<String, dynamic> data, String idLocal) async {
    final epc = data['epc'] ?? '';

    if (_sendingIds.contains(idLocal)) return;

    _sendingIds.add(idLocal);
    _activeRequests++;

    final DateTime startTime = DateTime.now();
    final Stopwatch stopwatch = Stopwatch()..start();

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

    // Schedule batch update
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

  Future<void> _handleRetryFail(
      String idLocal, Map<String, dynamic> data, String error) async {
    _retryCounter[idLocal] = (_retryCounter[idLocal] ?? 0) + 1;
    final retryCount = _retryCounter[idLocal]!;

    if (retryCount <= 1) {
      // Đợi 0.5s rồi gửi lại
      await Future.delayed(const Duration(milliseconds: 500));
      // unawaited(_sendToServer(data, idLocal));
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

  void dispose() {
    _tagController.close();
    _syncController.close();
    _dbCountController.close();
    _batchTimer?.cancel();
    _uiUpdateTimer?.cancel();
    _statusUpdateTimer?.cancel();
    TempStorageService().clearTempFile();
    RfidC72Plugin.stopScan;
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
