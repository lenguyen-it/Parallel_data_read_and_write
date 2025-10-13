// import 'dart:async';
// import 'dart:convert';
// import 'package:flutter/foundation.dart';
// import 'package:http/http.dart' as http;
// import 'package:paralled_data/database/history_database.dart';
// import 'package:paralled_data/plugin/rfid_c72_plugin.dart';

// class RfidScanService {
//   bool isConnected = false;
//   bool isConnecting = false;
//   bool isScanning = false;
//   bool isContinuousMode = false;
//   String lastTag = 'Chưa có dữ liệu';

//   final StreamController<String> _tagController =
//       StreamController<String>.broadcast();
//   Stream<String> get tagStream => _tagController.stream;

//   Timer? _syncTimer;
//   bool _isSyncing = false;

//   final int maxConnectRetry = 3;
//   int _currentRetry = 0;
//   int retryDelaySeconds = 5;
//   final Map<String, int> _retryCounter = {};

//   static const String serverUrl = 'http://192.168.15.194:5000/api/scans';

//   /// ------------------ STREAM RFID ------------------
//   void attachTagStream() {
//     try {
//       RfidC72Plugin.tagsStatusStream.receiveBroadcastStream().listen(
//         (event) async {
//           final tag = event?.toString().trim() ?? '';
//           if (tag.isEmpty) return;

//           lastTag = tag;
//           _tagController.add(tag);

//           final idLocal = await HistoryDatabase.instance.insertScan(
//             tag,
//             status: 'pending',
//           );

//           unawaited(_sendToServer(tag, idLocal));
//         },
//         onError: (err) async {
//           await HistoryDatabase.instance.insertScan(
//             'RFID_STREAM_ERROR',
//             status: 'failed',
//             error: err.toString(),
//           );
//           _tagController.addError(err.toString());
//         },
//       );

//       _startSyncWorker();
//     } catch (e) {
//       debugPrint('Attach RFID stream failed: $e');
//     }
//   }

//   /// ------------------ KẾT NỐI ------------------
//   Future<void> connect() async {
//     if (isConnected || isConnecting) return;
//     isConnecting = true;
//     try {
//       final ok = await RfidC72Plugin.connect;
//       isConnected = ok == true;
//       if (!isConnected && _currentRetry < maxConnectRetry) {
//         _currentRetry++;
//         Future.delayed(Duration(seconds: retryDelaySeconds), connect);
//       }
//     } catch (e) {
//       debugPrint('RFID connect error: $e');
//     } finally {
//       isConnecting = false;
//     }
//   }

//   /// ------------------ QUÉT RFID ------------------
//   Future<void> startSingleScan() async {
//     if (!isConnected) throw Exception('Chưa kết nối thiết bị');
//     isScanning = true;
//     try {
//       await RfidC72Plugin.startSingle;
//     } catch (e) {
//       await HistoryDatabase.instance.insertScan(
//         'RFID_SINGLE_ERROR',
//         status: 'failed',
//         error: e.toString(),
//       );
//     } finally {
//       isScanning = false;
//     }
//   }

//   Future<void> startContinuousScan() async {
//     if (!isConnected) throw Exception('Chưa kết nối thiết bị');
//     isContinuousMode = true;
//     isScanning = true;
//     try {
//       await RfidC72Plugin.startContinuous;
//     } catch (e) {
//       await HistoryDatabase.instance.insertScan(
//         'RFID_CONT_ERROR',
//         status: 'failed',
//         error: e.toString(),
//       );
//       isContinuousMode = false;
//       isScanning = false;
//     }
//   }

//   Future<void> stopScan() async {
//     try {
//       await RfidC72Plugin.stopScan;
//       isScanning = false;
//       isContinuousMode = false;
//       lastTag = 'Đã dừng quét';
//     } catch (e) {
//       debugPrint('Stop RFID scan error: $e');
//     }
//   }

//   /// ------------------ GỬI LÊN SERVER ------------------
//   Future<void> _sendToServer(String tag, String idLocal) async {
//     final url = Uri.parse(serverUrl);
//     final body = {
//       'barcode': tag,
//       'timestamp_device': DateTime.now().toIso8601String(),
//       'status_sync': true,
//     };

//     try {
//       final response = await http
//           .post(url,
//               headers: {'Content-Type': 'application/json'},
//               body: jsonEncode(body))
//           .timeout(const Duration(seconds: 6));

//       if (response.statusCode == 200 || response.statusCode == 201) {
//         await HistoryDatabase.instance.updateStatusById(idLocal, 'synced');
//         _retryCounter.remove(idLocal);
//       } else {
//         _handleRetryFail(idLocal, tag, 'Server error ${response.statusCode}');
//       }
//     } catch (e) {
//       _handleRetryFail(idLocal, tag, e.toString());
//     }
//   }

//   /// ------------------ RETRY & SYNC ------------------
//   void _handleRetryFail(String idLocal, String tag, String error) async {
//     _retryCounter[idLocal] = (_retryCounter[idLocal] ?? 0) + 1;
//     if (_retryCounter[idLocal]! >= 3) {
//       await HistoryDatabase.instance.updateStatusById(idLocal, 'failed');
//       _retryCounter.remove(idLocal);
//     } else {
//       await HistoryDatabase.instance.updateStatusById(idLocal, 'pending');
//     }
//   }

//   void _startSyncWorker() {
//     _syncTimer?.cancel();
//     _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
//       if (_isSyncing) return;
//       _isSyncing = true;
//       try {
//         await retryPendingScans();
//       } finally {
//         _isSyncing = false;
//       }
//     });
//   }

//   Future<void> retryPendingScans() async {
//     final pending = await HistoryDatabase.instance.getPendingScans();
//     for (final scan in pending) {
//       final tag = scan['barcode'] as String;
//       final idLocal = scan['id_local'] as String;
//       unawaited(_sendToServer(tag, idLocal));
//     }
//   }

//   /// ------------------ TIỆN ÍCH ------------------
//   Future<List<Map<String, dynamic>>> loadRecent() =>
//       HistoryDatabase.instance.getAllScans();

//   Future<void> clearHistory() => HistoryDatabase.instance.clearHistory();

//   void dispose() {
//     _syncTimer?.cancel();
//     _tagController.close();
//     RfidC72Plugin.stopScan;
//   }
// }


import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:paralled_data/database/history_database.dart';
import 'package:paralled_data/plugin/rfid_c72_plugin.dart';

class RfidScanService {
  bool isConnected = false;
  bool isConnecting = false;
  bool isScanning = false;
  bool isContinuousMode = false;
  String lastTag = 'Chưa có dữ liệu';

  final StreamController<Map<String, dynamic>> _tagController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get tagStream => _tagController.stream;

  Timer? _syncTimer;
  bool _isSyncing = false;

  final int maxConnectRetry = 3;
  int _currentRetry = 0;
  int retryDelaySeconds = 5;
  final Map<String, int> _retryCounter = {};

  static const String serverUrl = 'http://192.168.15.194:5000/api/scans';

  /// ------------------ STREAM RFID ------------------
  void attachTagStream() {
    try {
      RfidC72Plugin.tagsStatusStream.receiveBroadcastStream().listen(
        (event) async {
          if (event == null) return;

          // ✅ Nếu từ Java gửi về là Map thì parse thẳng
          Map<String, dynamic> data;
          if (event is Map) {
            data = Map<String, dynamic>.from(event);
          } else if (event is String) {
            try {
              data = jsonDecode(event);
            } catch (_) {
              // Nếu không parse được thì bỏ qua
              return;
            }
          } else {
            return;
          }

          final epc = data['epc_ascii'] ?? '';
          if (epc.toString().trim().isEmpty) return;

          lastTag = epc;
          _tagController.add(data);

          // Lưu vào SQLite
          final idLocal = await HistoryDatabase.instance.insertScan(
            epc,
            status: 'pending',
          );

          // Gửi lên server (toàn bộ dữ liệu RFID)
          unawaited(_sendToServer(data, idLocal));
        },
        onError: (err) async {
          await HistoryDatabase.instance.insertScan(
            'RFID_STREAM_ERROR',
            status: 'failed',
            error: err.toString(),
          );
          _tagController.addError(err.toString());
        },
      );

      _startSyncWorker();
    } catch (e) {
      debugPrint('Attach RFID stream failed: $e');
    }
  }

  /// ------------------ KẾT NỐI ------------------
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
      await HistoryDatabase.instance.insertScan(
        'RFID_SINGLE_ERROR',
        status: 'failed',
        error: e.toString(),
      );
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
    } catch (e) {
      await HistoryDatabase.instance.insertScan(
        'RFID_CONT_ERROR',
        status: 'failed',
        error: e.toString(),
      );
      isContinuousMode = false;
      isScanning = false;
    }
  }

  Future<void> stopScan() async {
    try {
      await RfidC72Plugin.stopScan;
      isScanning = false;
      isContinuousMode = false;
      lastTag = 'Đã dừng quét';
    } catch (e) {
      debugPrint('Stop RFID scan error: $e');
    }
  }

  /// ------------------ GỬI LÊN SERVER ------------------
  Future<void> _sendToServer(Map<String, dynamic> data, String idLocal) async {
    final url = Uri.parse(serverUrl);

    final body = {
      'barcode': data['epc_ascii'] ?? '',
      'epc_hex': data['epc_hex'],
      'tid_hex': data['tid_hex'],
      'user_hex': data['user_hex'],
      'rssi': data['rssi'],
      'count': data['count'],
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
        _handleRetryFail(idLocal, data['epc_ascii'], 'Server error ${response.statusCode}');
      }
    } catch (e) {
      _handleRetryFail(idLocal, data['epc_ascii'], e.toString());
    }
  }

  /// ------------------ RETRY & SYNC ------------------
  void _handleRetryFail(String idLocal, String tag, String error) async {
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
      final tag = scan['barcode'] as String;
      final idLocal = scan['id_local'] as String;
      unawaited(_sendToServer({'epc_ascii': tag}, idLocal));
    }
  }

  /// ------------------ TIỆN ÍCH ------------------
  Future<List<Map<String, dynamic>>> loadRecent() =>
      HistoryDatabase.instance.getAllScans();

  Future<void> clearHistory() => HistoryDatabase.instance.clearHistory();

  void dispose() {
    _syncTimer?.cancel();
    _tagController.close();
    RfidC72Plugin.stopScan;
  }
}
