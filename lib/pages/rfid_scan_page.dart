import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:paralled_data/database/history_database.dart';
import 'package:paralled_data/services/rfid_scan_service.dart';
import 'package:paralled_data/services/temp_storage_service.dart';

class RfidScanPage extends StatefulWidget {
  const RfidScanPage({super.key});

  @override
  State<RfidScanPage> createState() => _RfidScanPageState();
}

class _RfidScanPageState extends State<RfidScanPage> {
  final RfidScanService _scanService = RfidScanService();
  List<Map<String, dynamic>> _localData = [];

  StreamSubscription<Map<String, dynamic>>? _tagSubscription;
  StreamSubscription<Map<String, dynamic>>? _syncSubscription;
  StreamSubscription<int>? _dbCountSubscription;

  Timer? _speedUpdateTimer;
  Timer? _autoRefreshTimer;

  bool _isLoading = false;
  bool _isScanning = false;

  int _currentDbCount = 0;
  int _lastSyncSpeed = 0;

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

  @override
  void initState() {
    super.initState();
    _initSetup();
  }

  Future<void> _initSetup() async {
    await _scanService.connect();
    _scanService.attachTagStream();
    await _loadLocal();

    // ✅ Chỉ track scan speed, KHÔNG load data
    _tagSubscription = _scanService.tagStream.listen((data) {
      if (mounted) {
        setState(() {
          _scanTimestamps.add(DateTime.now());
        });
      }
    });

    // ✅ Chỉ track sync speed, KHÔNG load data
    _syncSubscription = _scanService.syncStream.listen((data) {
      if (mounted) {
        setState(() {
          _syncTimestamps.add(DateTime.now());
        });
      }
    });

    // ✅ Listen DB count stream (chỉ update khi có batch mới)
    _dbCountSubscription = _scanService.dbCountStream.listen((count) {
      if (mounted && count != _currentDbCount) {
        setState(() {
          _currentDbCount = count;
        });
        _loadLocal(); // Chỉ load khi có thay đổi thực sự
      }
    });

    // ✅ Update tốc độ sync mỗi 500ms
    _speedUpdateTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final currentSpeed = _syncsInLastSecond;
      if (mounted && currentSpeed != _lastSyncSpeed) {
        setState(() {
          _lastSyncSpeed = currentSpeed;
        });
      }
    });

    // ✅ Auto refresh mỗi 3s (để catch missed updates)
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      await _loadLocal();
    });
  }

  Future<void> _loadLocal() async {
    final data = await HistoryDatabase.instance.getAllScans();
    if (mounted) {
      setState(() {
        _localData = data;
        _currentDbCount = data.length;
      });
    }
  }

  @override
  void dispose() {
    _tagSubscription?.cancel();
    _syncSubscription?.cancel();
    _dbCountSubscription?.cancel();
    _speedUpdateTimer?.cancel();
    _autoRefreshTimer?.cancel();
    _scanService.dispose();
    super.dispose();
  }

  Future<void> _handleSingleScan() async {
    setState(() => _isLoading = true);
    try {
      await _scanService.startSingleScan();
    } catch (e) {
      debugPrint('Single scan error: $e');
    } finally {
      await _loadLocal();
      setState(() => _isLoading = false);
    }
  }

  Future<void> _handleContinuousScan() async {
    try {
      setState(() => _isScanning = true);
      await _scanService.startContinuousScan();
    } catch (e) {
      debugPrint('Continuous scan error: $e');
    }
  }

  void _handleStopScan() async {
    await _scanService.stopScan();

    await Future.delayed(const Duration(milliseconds: 500));

    await _loadLocal();

    setState(() => _isScanning = false);
  }

  ///TOÀN BỘ FILE UPLOAD VÀO FILE TẠM

  // Future<void> _handleUploadFile() async {
  //   setState(() => _isLoading = true);
  //   try {
  //     // Gọi phương thức import từ TempStorageService
  //     final result = await TempStorageService().importFileFromDevice();

  //     if (!mounted) return;

  //     if (!result['success']) {
  //       ScaffoldMessenger.of(context).showSnackBar(
  //         SnackBar(content: Text(result['message'])),
  //       );
  //       return;
  //     }

  //     // Đồng bộ các bản ghi pending
  //     await _scanService.syncRecordsFromTemp();

  //     // Cập nhật UI
  //     await _loadLocal();
  //     ScaffoldMessenger.of(context).showSnackBar(
  //       SnackBar(content: Text(result['message'])),
  //     );
  //   } catch (e) {
  //     debugPrint('Upload file error: $e');
  //     if (mounted) {
  //       ScaffoldMessenger.of(context).showSnackBar(
  //         SnackBar(content: Text('Lỗi khi nhập file: $e')),
  //       );
  //     }
  //   } finally {
  //     setState(() => _isLoading = false);
  //   }
  // }

  ///CHỈ UPLOAD CÁC RECORDS KHÔNG PHẢI SYNCED

  Future<void> _handleUploadFile() async {
    setState(() => _isLoading = true);
    try {
      final result = await TempStorageService().readFileForUpload();

      if (!mounted) return;

      if (!result['success']) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['message'])),
        );
        return;
      }

      final records = result['records'] as List<Map<String, dynamic>>;

      await _scanService.syncRecordsFromUpload(records);

      // Cập nhật UI
      await _loadLocal();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result['message'])),
      );
    } catch (e) {
      debugPrint('Upload file error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi nhập file: $e')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

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
                    const Text(
                      'Dữ liệu File Tạm',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () async {
                        String selected = 'json';

                        await showDialog(
                          context: context,
                          builder: (context) {
                            return StatefulBuilder(
                              builder: (context, setState) {
                                return AlertDialog(
                                  title: const Text('Chọn định dạng tải về'),
                                  content: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      RadioListTile<String>(
                                        title: const Text('📄 Tải file JSON'),
                                        value: 'json',
                                        groupValue: selected,
                                        onChanged: (value) =>
                                            setState(() => selected = value!),
                                      ),
                                      RadioListTile<String>(
                                        title: const Text('📊 Tải file CSV'),
                                        value: 'csv',
                                        groupValue: selected,
                                        onChanged: (value) =>
                                            setState(() => selected = value!),
                                      ),
                                    ],
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('Hủy'),
                                    ),
                                    ElevatedButton.icon(
                                      icon:
                                          const Icon(Icons.download, size: 18),
                                      label: const Text('Tải về'),
                                      onPressed: () async {
                                        String? path;
                                        String message;

                                        if (selected == 'json') {
                                          path = await TempStorageService()
                                              .downloadTempFileJson();
                                        } else if (selected == 'csv') {
                                          path = await TempStorageService()
                                              .downloadTempFileCSV();
                                        }

                                        if (!context.mounted) return;

                                        if (path != null) {
                                          message =
                                              '✅ Đã lưu file ${selected.toUpperCase()}: $path';
                                        } else {
                                          message =
                                              '❌ Lỗi khi lưu file $selected';
                                        }

                                        await showDialog(
                                          context: context,
                                          builder: (context) => AlertDialog(
                                            title: const Text('Thông báo'),
                                            content: Text(message),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(context),
                                                child: const Text('Đóng'),
                                              ),
                                            ],
                                          ),
                                        );

                                        if (context.mounted) {
                                          Navigator.pop(context);
                                          Navigator.pop(context);
                                        }
                                      },
                                    ),
                                  ],
                                );
                              },
                            );
                          },
                        );
                      },
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Tải về'),
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
                          if (!mounted) return;
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Đã xóa file tạm')),
                          );
                        }
                      },
                      icon: const Icon(Icons.delete, size: 18),
                      label: const Text('Xóa tất cả'),
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

  Widget _buildScannedList() {
    if (_localData.isEmpty) {
      return const Center(child: Text('Chưa có dữ liệu'));
    }

    return ListView.builder(
      itemCount: _localData.length,
      itemBuilder: (context, i) {
        final item = _localData[i];
        final code = item['epc'] ?? '---';
        final scanDuration = item['scan_duration_ms'];

        return Container(
          height: 80,
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.black12)),
          ),
          child: ListTile(
            title: Text(
              code,
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
      'failed': 'Thất bại',
    };

    return ListView.builder(
      itemCount: _localData.length,
      itemBuilder: (context, i) {
        final item = _localData[i];
        final code = item['epc'] ?? '---';
        final status = item['status'] ?? 'pending';
        final statusText = statusMap[status] ?? status;
        final syncDuration = item['sync_duration_ms'];

        Color bgColor;
        switch (status) {
          case 'synced':
            bgColor = const Color(0xFFE8F5E9);
            break;
          case 'failed':
            bgColor = const Color(0xFFFFEBEE);
            break;
          default:
            bgColor = const Color(0xFFFFF8E1);
        }

        return Container(
          height: 80,
          decoration: BoxDecoration(
            color: bgColor,
            border: const Border(
              bottom: BorderSide(color: Colors.black12),
            ),
          ),
          child: ListTile(
            title: Text(
              code,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Đồng bộ dữ liệu RFID'),
        backgroundColor: Colors.blue.shade700,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: _isLoading ? null : _handleSingleScan,
                  child: const Text('Quét 1 lần'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isScanning ? Colors.grey : Colors.green,
                  ),
                  onPressed: _isScanning ? null : _handleContinuousScan,
                  child: const Text('Quét liên tục'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isScanning ? Colors.red : Colors.grey,
                  ),
                  onPressed: _isScanning ? _handleStopScan : null,
                  child: const Text('Dừng'),
                ),
                ElevatedButton(
                  onPressed: _loadLocal,
                  child: const Text('Tải lại'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.lightGreen,
                  ),
                  onPressed: _showTempFileDialog,
                  child: const Text('Xem file tạm'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                  ),
                  onPressed: _isLoading ? null : _handleUploadFile,
                  child: const Text('Upload File'),
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
                        height: 80,
                        color: Colors.blue.shade50,
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8.0, vertical: 6.0),
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
                              '($_currentDbCount)',
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
                        height: 80,
                        color: Colors.green.shade50,
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8.0, vertical: 6.0),
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
                              '(${_localData.where((e) => e['status'] == 'synced').length}/$_currentDbCount)',
                              style: const TextStyle(
                                fontSize: 13,
                                color: Colors.green,
                              ),
                            ),
                            Text(
                              'Tốc độ: $_lastSyncSpeed mã/giây',
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
          )
        ],
      ),
    );
  }
}
