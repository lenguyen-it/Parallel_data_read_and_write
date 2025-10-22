import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

class TempStorageService {
  static final TempStorageService _instance = TempStorageService._internal();
  factory TempStorageService() => _instance;
  TempStorageService._internal();

  static const String _fileName = 'rfid_temp_data.json';
  File? _tempFile;

  bool _isWriting = false;
  final List<Map<String, dynamic>> _writeQueue = [];

  /// Khởi tạo file tạm (nếu chưa có)
  Future<void> _initTempFile() async {
    if (_tempFile != null) return;

    Directory tempDir = await getTemporaryDirectory();
    _tempFile = File(path.join(tempDir.path, _fileName));

    if (await _tempFile!.exists()) {
      if (!await _validateJsonFile()) {
        debugPrint('⚠️ File tạm bị lỗi, tạo mới...');
        await _tempFile!.delete();
      }
    }

    if (!await _tempFile!.exists()) {
      await _tempFile!.create(recursive: true);
      await _tempFile!.writeAsString('[]');
      debugPrint('✅ Đã tạo file tạm mới: ${_tempFile!.path}');
    } else {
      debugPrint('ℹ️ File tạm đã tồn tại: ${_tempFile!.path}');
    }
  }

  /// Kiểm tra file JSON có hợp lệ không
  Future<bool> _validateJsonFile() async {
    try {
      final content = await _tempFile!.readAsString();
      if (content.isEmpty) return true;
      jsonDecode(content);
      return true;
    } catch (e) {
      debugPrint('❌ File JSON không hợp lệ: $e');
      return false;
    }
  }

  /// THÊM dữ liệu quét được vào file tạm (cho một item)
  Future<void> appendScanData(Map<String, dynamic> tagData) async {
    await _initTempFile();

    if (!tagData.containsKey('timestamp')) {
      tagData['timestamp_savefile'] = DateTime.now().toIso8601String();
    }
    if (!tagData.containsKey('sync_timestamp')) {
      tagData['sync_timestamp'] = null;
    }
    if (!tagData.containsKey('sync_duration_ms')) {
      tagData['sync_duration_ms'] = null;
    }

    _writeQueue.add(tagData);

    if (_isWriting) {
      return;
    }

    await _processWriteQueue();
  }

  /// Thêm batch dữ liệu vào file tạm (cho nhiều items)
  Future<void> appendBatch(List<Map<String, dynamic>> batchData) async {
    await _initTempFile();

    for (var tagData in batchData) {
      if (!tagData.containsKey('timestamp')) {
        tagData['timestamp_savefile'] = DateTime.now().toIso8601String();
      }
      if (!tagData.containsKey('sync_timestamp')) {
        tagData['sync_timestamp'] = null;
      }
      if (!tagData.containsKey('sync_duration_ms')) {
        tagData['sync_duration_ms'] = null;
      }
    }

    _writeQueue.addAll(batchData);

    if (_isWriting) {
      return;
    }

    await _processWriteQueue();
  }

  /// Xử lý queue ghi file (batch write)
  Future<void> _processWriteQueue() async {
    if (_isWriting || _writeQueue.isEmpty) return;

    _isWriting = true;

    try {
      final batch = List<Map<String, dynamic>>.from(_writeQueue);
      _writeQueue.clear();

      List<dynamic> currentData = [];
      final content = await _tempFile!.readAsString();

      if (content.isNotEmpty && content != '[]') {
        try {
          currentData = jsonDecode(content);
        } catch (e) {
          debugPrint('⚠️ Lỗi đọc file, backup và tạo mới: $e');
          final backupPath = '${_tempFile!.path}.backup';
          await _tempFile!.copy(backupPath);
          currentData = [];
        }
      }

      currentData.addAll(batch);

      final jsonStr = jsonEncode(currentData);
      await _tempFile!.writeAsString(jsonStr, flush: true);

      debugPrint(
          '✅ Đã lưu ${batch.length} items vào file tạm | Tổng: ${currentData.length}');
    } catch (e) {
      debugPrint('❌ Lỗi processWriteQueue: $e');
      _writeQueue.insertAll(0, _writeQueue);
    } finally {
      _isWriting = false;

      if (_writeQueue.isNotEmpty) {
        await _processWriteQueue();
      }
    }
  }

  /// Cập nhật trạng thái sync
  Future<void> updateSyncStatus({
    String? epcAscii,
    required String idLocal,
    required String syncStatus,
    double? syncDurationMs,
    String? syncError,
  }) async {
    await _initTempFile();

    while (_isWriting) {
      await Future.delayed(const Duration(milliseconds: 10));
    }

    _isWriting = true;

    try {
      final content = await _tempFile!.readAsString();
      if (content.isEmpty) return;

      List<dynamic> currentData;
      try {
        currentData = jsonDecode(content);
      } catch (e) {
        debugPrint('⚠️ Lỗi đọc file khi update sync: $e');
        return;
      }

      bool updated = false;
      for (var item in currentData) {
        if (item['id_local'] == idLocal) {
          if (item['sync_status'] == 'synced' && syncStatus == 'failed') {
            continue;
          }

          item['sync_status'] = syncStatus;

          if (syncStatus == 'synced') {
            item['sync_timestamp'] = DateTime.now().toIso8601String();
            if (syncDurationMs != null) {
              item['sync_duration_ms'] = syncDurationMs;
            }
          } else if (syncStatus == 'failed') {
            item['sync_error'] = syncError ?? 'Unknown error';
          }

          updated = true;
          break;
        }
      }

      if (updated) {
        await _tempFile!.writeAsString(jsonEncode(currentData), flush: true);
        // debugPrint('✅ Cập nhật sync_status: $idLocal -> $syncStatus');
      }
    } catch (e) {
      debugPrint('❌ Lỗi updateSyncStatus: $e');
    } finally {
      _isWriting = false;
    }
  }

  /// XEM lại dữ liệu trong file tạm
  Future<List<dynamic>> readAllTempData() async {
    await _initTempFile();

    while (_isWriting) {
      await Future.delayed(const Duration(milliseconds: 10));
    }

    try {
      final content = await _tempFile!.readAsString();
      if (content.isEmpty || content == '[]') {
        debugPrint('📋 File tạm rỗng');
        return [];
      }

      final List<dynamic> jsonData = jsonDecode(content);
      debugPrint('📋 Đọc file tạm: ${jsonData.length} records');
      return jsonData;
    } catch (e) {
      debugPrint('❌ Lỗi readAllTempData: $e');

      final backupPath = '${_tempFile!.path}.backup';
      final backupFile = File(backupPath);

      if (await backupFile.exists()) {
        try {
          final backupContent = await backupFile.readAsString();
          final backupData = jsonDecode(backupContent);
          debugPrint('✅ Khôi phục từ backup: ${backupData.length} records');

          await _tempFile!.writeAsString(backupContent, flush: true);
          return backupData;
        } catch (e2) {
          debugPrint('❌ Không thể khôi phục từ backup: $e2');
        }
      }

      return [];
    }
  }

  Future<String?> downloadTempFileJson() async {
    await _initTempFile();

    while (_isWriting) {
      await Future.delayed(const Duration(milliseconds: 10));
    }

    try {
      final content = await _tempFile!.readAsString();

      if (content.trim().isEmpty || content.trim() == '[]') {
        debugPrint('⚠️ Không có dữ liệu để tải JSON');
        return null;
      }

      Directory? targetDir;

      if (Platform.isAndroid) {
        targetDir = Directory('/storage/emulated/0/Download');
        if (!await targetDir.exists()) {
          targetDir = await getExternalStorageDirectory();
        }
      } else if (Platform.isIOS) {
        targetDir = await getApplicationDocumentsDirectory();
      } else {
        targetDir = await getDownloadsDirectory();
      }

      if (targetDir == null) {
        debugPrint('❌ Không tìm thấy thư mục lưu file');
        return null;
      }

      final timestamp =
          DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
      final fileName = 'rfid_backup_$timestamp.json';
      final targetPath = path.join(targetDir.path, fileName);

      final targetFile = await _tempFile!.copy(targetPath);

      debugPrint('✅ Đã tải file về: ${targetFile.path}');
      return targetFile.path;
    } catch (e) {
      debugPrint('❌ Lỗi downloadTempFile: $e');
      return null;
    }
  }

  /// Xuất file CSV từ dữ liệu tạm
  Future<String?> downloadTempFileCSV() async {
    await _initTempFile();
    while (_isWriting) {
      await Future.delayed(const Duration(milliseconds: 10));
    }

    final List<Map<String, dynamic>> data =
        List<Map<String, dynamic>>.from(await readAllTempData());

    if (data.isEmpty) {
      debugPrint('Không có dữ liệu để xuất CSV');
      return null;
    }

    const List<String> headers = [
      'id_local',
      'epc',
      'sync_status',
      'scan_duration_ms',
      'epc_hex',
      'tid_hex',
      'user_hex',
      'rssi',
      'count',
      'timestamp_savefile',
      'sync_timestamp',
      'sync_duration_ms',
      'sync_error'
    ];

    final List<List<dynamic>> rows = data
        .map((item) => [
              item['id_local'] ?? '',
              item['epc'] ?? '',
              item['sync_status'] ?? 'pending',
              item['scan_duration_ms'] ?? '',
              item['epc_hex'] ?? '',
              item['tid_hex'] ?? '',
              item['user_hex'] ?? '',
              item['rssi'] ?? '',
              item['count'] ?? '',
              item['timestamp_savefile'] ?? '',
              item['sync_timestamp'] ?? '',
              item['sync_duration_ms'] ?? '',
              item['sync_error'] ?? '',
            ])
        .toList();

    rows.insert(0, headers);
    final csv = const ListToCsvConverter().convert(rows);

    Directory? dir;
    if (Platform.isAndroid) {
      dir = Directory('/storage/emulated/0/Download');
      if (!await dir.exists()) dir = await getExternalStorageDirectory();
    } else if (Platform.isIOS) {
      dir = await getApplicationDocumentsDirectory();
    } else {
      dir = await getDownloadsDirectory();
    }

    if (dir == null) return null;

    final timestamps =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final path = '${dir.path}/rfid_backup_$timestamps.csv';
    await File(path).writeAsString(csv, flush: true);
    debugPrint('CSV saved: $path');
    return path;
  }

  /// Đếm số lượng dữ liệu trong file
  Future<int> getTempDataCount() async {
    final data = await readAllTempData();
    return data.length;
  }

  /// XÓA toàn bộ file tạm
  Future<void> clearTempFile() async {
    while (_isWriting) {
      await Future.delayed(const Duration(milliseconds: 10));
    }

    await _initTempFile();

    _writeQueue.clear();

    await _tempFile!.writeAsString('[]', flush: true);
    debugPrint('✅ Đã xóa toàn bộ dữ liệu file tạm');
  }

  /// Lấy đường dẫn file tạm
  Future<String> getTempFilePath() async {
    await _initTempFile();
    return _tempFile!.path;
  }

  /// Force flush queue (gọi khi cần đảm bảo tất cả đã được ghi)
  Future<void> flushQueue() async {
    while (_writeQueue.isNotEmpty || _isWriting) {
      await _processWriteQueue();
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  //Import file JSON và csv
  Future<Map<String, dynamic>> importFileFromDevice() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'csv'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        return {
          'success': false,
          'message': 'Đã hủy chọn file',
          'newRecords': [],
          'stats': {'synced': 0, 'pending': 0, 'failed': 0}
        };
      }

      final file = File(result.files.first.path!);
      final extension = result.files.single.extension?.toLowerCase();

      List<Map<String, dynamic>> records = [];

      if (extension == 'json') {
        final content = await file.readAsString();
        final jsonData = jsonDecode(content);
        if (jsonData is List) {
          records = List<Map<String, dynamic>>.from(jsonData);
        }
      } else if (extension == 'csv') {
        final content = await file.readAsString();
        final csvRows = const CsvToListConverter().convert(content);
        if (csvRows.isEmpty) {
          return {
            'success': false,
            'message': 'File CSV rỗng',
            'newRecords': [],
            'stats': {'synced': 0, 'pending': 0, 'failed': 0}
          };
        }

        final headers = csvRows[0].map((e) => e.toString()).toList();
        records = csvRows.skip(1).map((row) {
          final map = <String, dynamic>{};
          for (int i = 0; i < headers.length && i < row.length; i++) {
            map[headers[i]] = row[i];
          }
          return map;
        }).toList();
      }

      if (records.isEmpty) {
        return {
          'success': false,
          'message': 'File không có dữ liệu',
          'newRecords': [],
          'stats': {'synced': 0, 'pending': 0, 'failed': 0}
        };
      }

      final mergeResult = await _mergeImportedData(records);

      return {
        'success': mergeResult['addedCount'] > 0,
        'message': 'Import thành công ${mergeResult['addedCount']} record',
        'recordCount': mergeResult['addedCount'],
        'newRecords': records,
        'stats': mergeResult['stats'],
      };
    } catch (e) {
      debugPrint("Lỗi import file: $e");
      return {
        'success': false,
        'message': 'Lỗi: $e',
        'newRecords': [],
        'stats': {'synced': 0, 'pending': 0, 'failed': 0}
      };
    }
  }

  Future<Map<String, dynamic>> _mergeImportedData(
      List<Map<String, dynamic>> importedRecords) async {
    await _initTempFile();

    while (_isWriting) {
      await Future.delayed(const Duration(milliseconds: 10));
    }

    _isWriting = true;

    try {
      List<dynamic> currentData = [];
      final content = await _tempFile!.readAsString();

      if (content.isNotEmpty && content != '[]') {
        try {
          currentData = jsonDecode(content);
        } catch (e) {
          debugPrint('⚠️ Lỗi đọc file hiện tại: $e');
          currentData = [];
        }
      }

      int addedCount = 0;
      int skippedCount = 0;

      int syncedCount = 0;
      int pendingCount = 0;
      int failedCount = 0;

      for (var record in importedRecords) {
        final epc = record['epc']?.toString() ?? '';

        if (epc.isEmpty) {
          skippedCount++;
          continue;
        }

        final syncStatus = record['sync_status']?.toString() ?? 'pending';

        final normalizedRecord = {
          'id_local': const Uuid().v4(),
          'epc': epc,
          'sync_status': syncStatus,
          'scan_duration_ms': record['scan_duration_ms'],
          'epc_hex': record['epc_hex'],
          'tid_hex': record['tid_hex'],
          'user_hex': record['user_hex'],
          'rssi': record['rssi'],
          'count': record['count'],
          'timestamp_savefile':
              record['timestamp_savefile'] ?? DateTime.now().toIso8601String(),
          'sync_timestamp': record['sync_timestamp'],
          'sync_duration_ms': record['sync_duration_ms'],
          'sync_error': record['sync_error'],
        };

        currentData.add(normalizedRecord);
        addedCount++;

        if (syncStatus == 'synced') {
          syncedCount++;
        } else if (syncStatus == 'failed') {
          failedCount++;
        } else {
          pendingCount++;
        }
      }

      await _tempFile!.writeAsString(jsonEncode(currentData), flush: true);

      debugPrint(
          '✅ Import: +$addedCount mới | ⭐ $skippedCount skip (epc empty) | 📊 Tổng: ${currentData.length}');
      debugPrint(
          '📈 Stats: $syncedCount synced | $pendingCount pending | $failedCount failed');

      return {
        'addedCount': addedCount,
        'stats': {
          'synced': syncedCount,
          'pending': pendingCount,
          'failed': failedCount,
        }
      };
    } catch (e) {
      debugPrint('❌ Lỗi _mergeImportedData: $e');
      rethrow;
    } finally {
      _isWriting = false;
    }
  }

  /// Lấy danh sách records cần sync (chỉ pending/failed)
  Future<List> getUnsyncedRecords() async {
    await _initTempFile();

    while (_isWriting) {
      await Future.delayed(const Duration(milliseconds: 10));
    }

    try {
      final allData = await readAllTempData();

      return allData.where((item) {
        final status = item['sync_status']?.toString() ?? 'pending';
        return status == 'pending' || status == 'failed';
      }).toList();
    } catch (e) {
      debugPrint('❌ Lỗi getUnsyncedRecords: $e');
      return [];
    }
  }

  //Đọc file upload
  Future<Map<String, dynamic>> readFileForUpload() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'csv'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        return {
          'success': false,
          'message': 'Đã hủy chọn file',
          'records': [],
          'stats': {'synced': 0, 'pending': 0, 'failed': 0, 'total': 0}
        };
      }

      final file = File(result.files.first.path!);
      final extension = result.files.single.extension?.toLowerCase();

      List<Map<String, dynamic>> records = [];

      if (extension == 'json') {
        final content = await file.readAsString();
        final jsonData = jsonDecode(content);
        if (jsonData is List) {
          records = List<Map<String, dynamic>>.from(jsonData);
        }
      } else if (extension == 'csv') {
        final content = await file.readAsString();
        final csvRows = const CsvToListConverter().convert(content);
        if (csvRows.isEmpty) {
          return {
            'success': false,
            'message': 'File CSV rỗng',
            'records': [],
            'stats': {'synced': 0, 'pending': 0, 'failed': 0, 'total': 0}
          };
        }

        final headers = csvRows[0].map((e) => e.toString()).toList();
        records = csvRows.skip(1).map((row) {
          final map = <String, dynamic>{};
          for (int i = 0; i < headers.length && i < row.length; i++) {
            map[headers[i]] = row[i];
          }
          return map;
        }).toList();
      }

      if (records.isEmpty) {
        return {
          'success': false,
          'message': 'File không có dữ liệu',
          'records': [],
          'stats': {'synced': 0, 'pending': 0, 'failed': 0, 'total': 0}
        };
      }

      // Đếm stats
      int syncedCount = 0;
      int pendingCount = 0;
      int failedCount = 0;
      int validCount = 0;

      for (var record in records) {
        final epc = record['epc']?.toString() ?? '';
        if (epc.isEmpty) continue;

        validCount++;
        final status = record['sync_status']?.toString() ?? 'pending';

        if (status == 'synced') {
          syncedCount++;
        } else if (status == 'failed') {
          failedCount++;
        } else {
          pendingCount++;
        }
      }

      debugPrint('📂 Đọc file upload: $validCount records');
      debugPrint(
          '📈 Stats: $syncedCount synced | $pendingCount pending | $failedCount failed');

      return {
        'success': true,
        'message': 'Đọc file thành công',
        'records': records,
        'stats': {
          'synced': syncedCount,
          'pending': pendingCount,
          'failed': failedCount,
          'total': validCount,
        }
      };
    } catch (e) {
      debugPrint("Lỗi đọc file: $e");
      return {
        'success': false,
        'message': 'Lỗi: $e',
        'records': [],
        'stats': {'synced': 0, 'pending': 0, 'failed': 0, 'total': 0}
      };
    }
  }
}
