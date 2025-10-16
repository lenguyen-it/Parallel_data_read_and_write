import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:paralled_data/database/history_database.dart';
import 'package:paralled_data/plugin/rfid_c72_plugin.dart';

class RfidScanService {
  /// ------------------ TRẠNG THÁI ------------------
  bool isConnected = false;
  bool isConnecting = false;
  bool isScanning = false;
  bool isContinuousMode = false;

  /// ------------------ STREAM ------------------
  final StreamController<Map<String, dynamic>> _tagController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get tagStream => _tagController.stream;

  final StreamController<Map<String, dynamic>> _syncController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get syncStream => _syncController.stream;

  /// ------------------ UI REAL-TIME STREAM ------------------
  final StreamController<Map<String, dynamic>> _uiUpdateController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get uiUpdateStream => _uiUpdateController.stream;

  Timer? _uiUpdateTimer;
  bool _hasPendingUIUpdate = false;
  Map<String, dynamic>? _lastScannedData;

  /// ------------------ QUEUE & CONCURRENT ------------------
  final Set<String> _sendingIds = {};
  // ignore: unused_field
  final Set<String> _recentEpcs = {};
  final List<_QueuedRequest> _requestQueue = [];
  int _activeRequests = 0;
  static const int maxConcurrentRequests = 3;

  final Map<String, int> _retryCounter = {};
  static const String serverUrl = 'http://192.168.15.194:5000/api/scans';

  /// ------------------ BATCH CONFIG ------------------
  static const int batchSize = 25;
  static const Duration batchInterval = Duration(milliseconds: 300);
  final List<Map<String, dynamic>> _pendingBatch = [];
  Timer? _batchTimer;

  bool _isFlushingBatch = false;

  //Đếm số
  int totalCount = 0;
  int uniqueCount = 0;
  final Set<String> uniqueEpcs = {};

  /// ------------------ KẾT NỐI ------------------
  final int maxConnectRetry = 3;
  int _currentRetry = 0;
  int retryDelaySeconds = 3;

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

  /// ------------------ QUÉT RFID ------------------
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

      await RfidC72Plugin.stopScan;
      isScanning = false;
      isContinuousMode = false;

      await _flushBatch(force: true);
    } catch (e) {
      debugPrint('Stop scan error: $e');
    }
  }

  /// ------------------ ATTACH STREAM ------------------
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

        _lastScannedData = data;
        _scheduleUIUpdate();

        _addToBatch(data);
      },
      onError: (err) {
        _tagController.addError(err.toString());
      },
    );
  }

  /// ------------------ UI UPDATE với THROTTLE ------------------
  void _scheduleUIUpdate() {
    if (_hasPendingUIUpdate) return;

    _hasPendingUIUpdate = true;
    _uiUpdateTimer?.cancel();

    _uiUpdateTimer = Timer(const Duration(milliseconds: 500), () {
      if (_lastScannedData != null) {
        _uiUpdateController.add(_lastScannedData!);
        _lastScannedData = null;
      }
      _hasPendingUIUpdate = false;
    });
  }

  /// ------------------ BATCH BUFFER ------------------
  void _addToBatch(Map<String, dynamic> data) {
    _pendingBatch.add({
      'barcode': data['epc_ascii'] ?? '',
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

  /// ------------------ GOM BATCH & FLUSH ------------------
  Future<void> _flushBatch({bool force = false}) async {
    if (!force && (_isFlushingBatch || _pendingBatch.isEmpty)) {
      return;
    }

    if (_pendingBatch.isEmpty) {
      debugPrint('⚠️ Không có batch để flush.');
      return;
    }

    _isFlushingBatch = true;

    try {
      final batch = List<Map<String, dynamic>>.from(_pendingBatch);
      _pendingBatch.clear();
      _batchTimer?.cancel();
      _batchTimer = null;

      final ids = await HistoryDatabase.instance.batchInsertScans(batch);
      if (ids.isEmpty) {
        debugPrint('⚠️ Không insert được batch.');
        return;
      }

      for (int i = 0; i < batch.length; i++) {
        unawaited(_sendToServer(batch[i], ids[i]));
      }
    } catch (e, st) {
      debugPrint('❌ Lỗi khi flush batch: $e\n$st');
    } finally {
      _isFlushingBatch = false;
    }
  }

  /// ------------------ GỬI SERVER SONG SONG ------------------
  Future<void> _sendToServer(Map<String, dynamic> data, String idLocal) async {
    final epc = data['barcode'] ?? '';

    if (_sendingIds.contains(idLocal) ||
        _requestQueue.any((r) => r.idLocal == idLocal)) {
      return;
    }

    if (_activeRequests >= maxConcurrentRequests) {
      _requestQueue.add(_QueuedRequest(data, idLocal));
      return;
    }

    _sendingIds.add(idLocal);
    _activeRequests++;

    final DateTime startTime = DateTime.now();
    final Stopwatch stopwatch = Stopwatch()..start();

    final body = {
      'barcode': epc,
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
          .timeout(const Duration(seconds: 6));

      stopwatch.stop();
      final double syncDurationMs = stopwatch.elapsedMilliseconds.toDouble();

      if (response.statusCode == 200 || response.statusCode == 201) {
        await HistoryDatabase.instance.updateStatusById(
          idLocal,
          'synced',
          syncDurationMs: syncDurationMs,
        );
        _syncController.add({'id': idLocal, 'duration_ms': syncDurationMs});
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

  Future<void> _handleRetryFail(
      String idLocal, Map<String, dynamic> data, String error) async {
    _retryCounter[idLocal] = (_retryCounter[idLocal] ?? 0) + 1;
    final retryCount = _retryCounter[idLocal]!;

    if (retryCount >= 3) {
      await HistoryDatabase.instance.updateStatusById(idLocal, 'failed');
      _retryCounter.remove(idLocal);
    } else {
      await Future.delayed(const Duration(milliseconds: 500));
      unawaited(_sendToServer(data, idLocal));
    }
  }

  void dispose() {
    _tagController.close();
    _syncController.close();
    _uiUpdateController.close();
    _batchTimer?.cancel();
    _uiUpdateTimer?.cancel();
    RfidC72Plugin.stopScan;
  }
}

class _QueuedRequest {
  final Map<String, dynamic> data;
  final String idLocal;
  _QueuedRequest(this.data, this.idLocal);
}
