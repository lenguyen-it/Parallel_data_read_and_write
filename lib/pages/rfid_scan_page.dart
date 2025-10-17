import 'dart:async';
import 'package:flutter/material.dart';
import 'package:paralled_data/database/history_database.dart';
import 'package:paralled_data/services/rfid_scan_service.dart';

class RfidScanPage extends StatefulWidget {
  const RfidScanPage({super.key});

  @override
  State<RfidScanPage> createState() => _RfidScanPageState();
}

class _RfidScanPageState extends State<RfidScanPage> {
  final RfidScanService _scanService = RfidScanService();
  List<Map<String, dynamic>> _localData = [];
  StreamSubscription<Map<String, dynamic>>? _subscription;
  StreamSubscription<Map<String, dynamic>>? _syncSubscription;
  StreamSubscription<Map<String, dynamic>>? _uiUpdateSubscription;
  Timer? _autoRefreshTimer;
  bool _isLoading = false;

  // ignore: unused_field
  Map<String, dynamic>? _lastTagData;

  // Lưu timestamp của các lần quét trong 1 giây
  final List<DateTime> _scanTimestamps = [];

  // Lưu timestamp của các lần đồng bộ trong 1 giây
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

    _subscription = _scanService.tagStream.listen((data) {
      setState(() {
        _lastTagData = data;
        _scanTimestamps.add(DateTime.now());
      });
    });

    _uiUpdateSubscription = _scanService.uiUpdateStream.listen((data) async {
      await _loadLocal();
    });

    _syncSubscription = _scanService.syncStream.listen((data) {
      setState(() {
        _syncTimestamps.add(DateTime.now());
      });
      _loadLocal();
    });

    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await _loadLocal();
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadLocal() async {
    final data = await HistoryDatabase.instance.getAllScans();
    if (mounted) {
      setState(() => _localData = data);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _syncSubscription?.cancel();
    _uiUpdateSubscription?.cancel();
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
      await _scanService.startContinuousScan();
    } catch (e) {
      debugPrint('Continuous scan error: $e');
    }
  }

  Future<void> _handleStopScan() async {
    await _scanService.stopScan();
  }

  /// 🔹 Danh sách dữ liệu đã quét
  Widget _buildScannedList() {
    if (_localData.isEmpty) {
      return const Center(child: Text('Chưa có dữ liệu'));
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
        final code = item['barcode'] ?? '---';
        final status = item['status'] ?? 'pending';
        final statusText = statusMap[status] ?? status;
        final scanDuration = item['scan_duration_ms'];

        Color bgColor;
        switch (status) {
          case 'synced':
            bgColor = const Color(0xFFE8F5E9); // xanh lá nhạt
            break;
          case 'failed':
            bgColor = const Color(0xFFFFEBEE); // đỏ nhạt
            break;
          default:
            bgColor = const Color(0xFFFFF8E1); // cam nhạt
        }

        return Container(
          height: 80,
          color: bgColor,
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
                Text(
                  'Trạng thái: $statusText',
                  style: TextStyle(
                    fontSize: 12,
                    color: status == 'synced'
                        ? Colors.green
                        : (status == 'failed' ? Colors.red : Colors.orange),
                  ),
                ),
                //if (scanDuration != null)
                if (scanDuration != null && status == 'synced')
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

  /// 🔹 Danh sách dữ liệu đồng bộ
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
        final code = item['barcode'] ?? '---';
        final status = item['status'] ?? 'pending';
        final statusText = statusMap[status] ?? status;
        final syncDuration = item['sync_duration_ms'];

        Color bgColor;
        switch (status) {
          case 'synced':
            bgColor = const Color(0xFFE8F5E9); // xanh lá nhạt
            break;
          case 'failed':
            bgColor = const Color(0xFFFFEBEE); // đỏ nhạt
            break;
          default:
            bgColor = const Color(0xFFFFF8E1); // cam nhạt
        }

        return Container(
          height: 80,
          color: bgColor,
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
          // ----------- Điều khiển -----------
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
                  onPressed: _handleContinuousScan,
                  child: const Text('Quét liên tục'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: _handleStopScan,
                  child: const Text('Dừng'),
                ),
                ElevatedButton(
                  onPressed: _loadLocal,
                  child: const Text('Tải lại'),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // ----------- Hai cột dữ liệu -----------
          Expanded(
            child: Row(
              children: [
                // ===== CỘT BÊN TRÁI: DỮ LIỆU ĐÃ QUÉT =====
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

                // ===== CỘT BÊN PHẢI: DỮ LIỆU ĐỒNG BỘ =====
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
          )
        ],
      ),
    );
  }
}
