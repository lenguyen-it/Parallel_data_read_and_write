import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:flutter/foundation.dart';

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
      // Kiểm tra file có hợp lệ không
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

    // Thêm timestamp nếu chưa có
    if (!tagData.containsKey('timestamp')) {
      tagData['timestamp_savefile'] = DateTime.now().toIso8601String();
    }
    if (!tagData.containsKey('sync_timestamp')) {
      tagData['sync_timestamp'] = null;
    }
    if (!tagData.containsKey('sync_duration_ms')) {
      tagData['sync_duration_ms'] = null;
    }

    // Thêm vào queue
    _writeQueue.add(tagData);

    // Nếu đang ghi, đợi xong
    if (_isWriting) {
      return;
    }

    // Xử lý queue
    await _processWriteQueue();
  }

  /// Thêm batch dữ liệu vào file tạm (cho nhiều items)
  Future<void> appendBatch(List<Map<String, dynamic>> batchData) async {
    await _initTempFile();

    // Thêm timestamp cho từng item
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

    // Thêm all vào queue
    _writeQueue.addAll(batchData);

    // Nếu đang ghi, đợi; else process
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
      // Lấy tất cả items trong queue
      final batch = List<Map<String, dynamic>>.from(_writeQueue);
      _writeQueue.clear();

      // Đọc dữ liệu hiện tại
      List<dynamic> currentData = [];
      final content = await _tempFile!.readAsString();

      if (content.isNotEmpty && content != '[]') {
        try {
          currentData = jsonDecode(content);
        } catch (e) {
          debugPrint('⚠️ Lỗi đọc file, backup và tạo mới: $e');
          // Backup file lỗi
          final backupPath = '${_tempFile!.path}.backup';
          await _tempFile!.copy(backupPath);
          currentData = [];
        }
      }

      // Thêm batch mới
      currentData.addAll(batch);

      // Ghi lại file (atomic write)
      final jsonStr = jsonEncode(currentData);
      await _tempFile!.writeAsString(jsonStr, flush: true);

      debugPrint(
          '✅ Đã lưu ${batch.length} items vào file tạm | Tổng: ${currentData.length}');
    } catch (e) {
      debugPrint('❌ Lỗi processWriteQueue: $e');
      // Đưa lại vào queue để thử lại
      _writeQueue.insertAll(0, _writeQueue);
    } finally {
      _isWriting = false;

      // Nếu còn items trong queue, xử lý tiếp
      if (_writeQueue.isNotEmpty) {
        await _processWriteQueue();
      }
    }
  }

  /// Cập nhật trạng thái sync (với lock)
  Future<void> updateSyncStatus({
    String? epcAscii,
    required String idLocal,
    required String syncStatus,
    double? syncDurationMs,
    String? syncError,
  }) async {
    await _initTempFile();

    // Đợi nếu đang ghi
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

      // Tìm và cập nhật record
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

    // Đợi nếu đang ghi
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

      // Thử khôi phục từ backup
      final backupPath = '${_tempFile!.path}.backup';
      final backupFile = File(backupPath);

      if (await backupFile.exists()) {
        try {
          final backupContent = await backupFile.readAsString();
          final backupData = jsonDecode(backupContent);
          debugPrint('✅ Khôi phục từ backup: ${backupData.length} records');

          // Ghi lại file chính từ backup
          await _tempFile!.writeAsString(backupContent, flush: true);
          return backupData;
        } catch (e2) {
          debugPrint('❌ Không thể khôi phục từ backup: $e2');
        }
      }

      return [];
    }
  }

  /// TẢI file tạm về máy (Downloads/Documents)
  Future<String?> downloadTempFile() async {
    await _initTempFile();

    // Đợi nếu đang ghi
    while (_isWriting) {
      await Future.delayed(const Duration(milliseconds: 10));
    }

    try {
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

  /// Đếm số lượng dữ liệu trong file
  Future<int> getTempDataCount() async {
    final data = await readAllTempData();
    return data.length;
  }

  /// XÓA toàn bộ file tạm
  Future<void> clearTempFile() async {
    // Đợi nếu đang ghi
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
}
