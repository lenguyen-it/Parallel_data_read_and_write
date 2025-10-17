import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:paralled_data/database/history_database.dart';
import 'package:paralled_data/plugin/rfid_c72_plugin.dart';

class BarcodeScanService {
  bool isConnected = false;
  bool isConnecting = false;
  bool isScanning = false;
  bool isContinuousMode = false;
  String lastCode = 'Chưa có dữ liệu';

  final StreamController<String> _codeController =
      StreamController<String>.broadcast();
  Stream<String> get codeStream => _codeController.stream;

  Timer? _syncTimer;
  bool _isSyncing = false;

  final int maxConnectRetry = 3;
  int _currentRetry = 0;
  int retryDelaySeconds = 5;
  final Map<String, int> _retryCounter = {};

  static const String serverUrl = 'http://192.168.15.194:5000/api/scans';

  /// ------------------ STREAM BARCODE ------------------
  void attachBarcodeStream() {
    try {
      RfidC72Plugin.barcodeStatusStream.receiveBroadcastStream().listen(
        (event) async {
          final code = event?.toString() ?? '';
          if (code == 'SCANNING' || code == 'STOPPED' || code.isEmpty) return;

          final normalized = _normalizeCode(code);
          lastCode = normalized;
          _codeController.add(normalized);
          debugPrint('[BARCODE] event: $normalized');

          final idLocal = await HistoryDatabase.instance.insertScan(
            normalized,
            status: 'pending',
          );

          unawaited(_sendToServer(normalized, idLocal));
        },
        onError: (err) async {
          debugPrint('[BARCODE] stream error: $err');
          await HistoryDatabase.instance.insertScan(
            'BARCODE_STREAM_ERROR',
            status: 'failed',
            error: err.toString(),
          );
          _codeController.addError(err.toString());
        },
      );

      _startSyncWorker();
    } catch (e) {
      debugPrint('Attach barcode stream failed: $e');
    }
  }

  String _normalizeCode(String raw) {
    if (raw.contains('://')) {
      final parts = raw.split('/');
      return parts.isNotEmpty ? parts.last.trim() : raw.trim();
    }
    return raw.trim();
  }

  /// ------------------ KẾT NỐI ------------------
  Future<void> connect() async {
    if (isConnected || isConnecting) return;
    isConnecting = true;
    try {
      final ok = await RfidC72Plugin.connectBarcode;
      isConnected = ok == true;
      debugPrint('Barcode connect: $ok');

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

  /// ------------------ QUÉT BARCODE ------------------
  Future<void> startSingleScan() async {
    if (!isConnected) throw Exception('Chưa kết nối thiết bị');
    isScanning = true;
    try {
      await RfidC72Plugin.scanBarcodeSingle;
    } catch (e) {
      await HistoryDatabase.instance.insertScan(
        'BARCODE_SINGLE_ERROR',
        status: 'failed',
        error: e.toString(),
      );
      rethrow;
    } finally {
      isScanning = false;
    }
  }

  Future<void> startContinuousScan() async {
    if (!isConnected) throw Exception('Chưa kết nối thiết bị');
    isContinuousMode = true;
    isScanning = true;
    try {
      await RfidC72Plugin.scanBarcodeContinuous;
    } catch (e) {
      await HistoryDatabase.instance.insertScan(
        'BARCODE_CONT_ERROR',
        status: 'failed',
        error: e.toString(),
      );
      isContinuousMode = false;
      isScanning = false;
      rethrow;
    }
  }

  Future<void> stopScan() async {
    try {
      await RfidC72Plugin.stopScanBarcode;
      isScanning = false;
      isContinuousMode = false;
      lastCode = 'Đã dừng quét';
    } catch (e) {
      debugPrint('Stop barcode error: $e');
    }
  }

  /// ------------------ GỬI LÊN SERVER ------------------
  Future<void> _sendToServer(String barcode, String idLocal) async {
    final url = Uri.parse(serverUrl);
    final body = {
      'epc': barcode,
      'timestamp_device': DateTime.now().toIso8601String(),
      'status_sync': true,
    };

    try {
      final response = await http
          .post(url,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 200 || response.statusCode == 201) {
        await HistoryDatabase.instance.updateStatusById(idLocal, 'synced');
        _retryCounter.remove(idLocal);
      } else {
        _handleRetryFail(
            idLocal, barcode, 'Server error ${response.statusCode}');
      }
    } catch (e) {
      _handleRetryFail(idLocal, barcode, e.toString());
    }
  }

  /// ------------------ RETRY & SYNC ------------------
  void _handleRetryFail(String idLocal, String barcode, String error) async {
    _retryCounter[idLocal] = (_retryCounter[idLocal] ?? 0) + 1;
    if (_retryCounter[idLocal]! >= 3) {
      await HistoryDatabase.instance.updateStatusById(idLocal, 'failed');
      _retryCounter.remove(idLocal);
    } else {
      await HistoryDatabase.instance.updateStatusById(idLocal, 'pending');
    }
  }

  void _startSyncWorker() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_isSyncing) return;
      _isSyncing = true;
      try {
        await retryPendingScans();
      } finally {
        _isSyncing = false;
      }
    });
  }

  Future<void> retryPendingScans() async {
    final pending = await HistoryDatabase.instance.getPendingScans();
    for (final scan in pending) {
      final code = scan['epc'] as String;
      final idLocal = scan['id_local'] as String;
      unawaited(_sendToServer(code, idLocal));
    }
  }

  /// ------------------ TIỆN ÍCH ------------------
  Future<List<Map<String, dynamic>>> loadRecent() =>
      HistoryDatabase.instance.getAllScans();

  Future<void> clearHistory() => HistoryDatabase.instance.clearHistory();

  void dispose() {
    _syncTimer?.cancel();
    _codeController.close();
    RfidC72Plugin.stopScanBarcode;
  }
}
