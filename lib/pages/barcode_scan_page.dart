import 'dart:async';
import 'package:flutter/material.dart';
import 'package:paralled_data/database/history_database.dart';
import 'package:paralled_data/services/barcode_scan_service.dart';

class BarcodeScanPage extends StatefulWidget {
  const BarcodeScanPage({super.key});

  @override
  State<BarcodeScanPage> createState() => _BarcodeScanPageState();
}

class _BarcodeScanPageState extends State<BarcodeScanPage> {
  final BarcodeScanService _scanService = BarcodeScanService();
  List<Map<String, dynamic>> _localData = [];
  StreamSubscription<String>? _subscription;
  Timer? _autoRefreshTimer;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initSetup();
  }

  Future<void> _initSetup() async {
    await _scanService.connect();
    _scanService.attachBarcodeStream();
    await _loadLocal();

    // Cập nhật khi có barcode mới
    _subscription = _scanService.codeStream.listen((_) async {
      await _loadLocal();
    });

    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await _loadLocal();
    });
  }

  Future<void> _loadLocal() async {
    final data = await HistoryDatabase.instance.getAllScans();
    // Mã mới nhất ở đầu danh sách
    setState(() => _localData = data);
  }

  @override
  void dispose() {
    _subscription?.cancel();
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

  /// 📱 Dữ liệu đã quét
  Widget _buildScannedList() {
    if (_localData.isEmpty) {
      return const Center(child: Text('Chưa có dữ liệu'));
    }

    return ListView.builder(
      itemCount: _localData.length,
      itemBuilder: (context, i) {
        final item = _localData[i];
        return Container(
          height: 70,
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.black12)),
          ),
          child: ListTile(
            title: Text(
              item['barcode'] ?? '---',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        );
      },
    );
  }

  /// ☁️ Dữ liệu đồng bộ (hiển thị trạng thái)
  Widget _buildSyncedList() {
    final statusMap = {
      'pending': 'Đang chờ',
      'synced': 'Thành công',
      'failed': 'Thất bại',
    };

    if (_localData.isEmpty) {
      return const Center(child: Text('Không có dữ liệu đồng bộ'));
    }

    return ListView.builder(
      itemCount: _localData.length,
      itemBuilder: (context, i) {
        final item = _localData[i];
        final code = item['barcode'] ?? '---';
        final status = item['status'] ?? 'pending';

        final statusText = statusMap[status] ?? status;

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
          height: 70,
          color: bgColor,
          child: ListTile(
            title: Text(
              code,
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              'Trạng thái: $statusText',
              style: TextStyle(
                fontSize: 13,
                color: status == 'synced'
                    ? Colors.green
                    : (status == 'failed' ? Colors.red : Colors.orange),
              ),
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
        title: const Text('Đồng bộ dữ liệu song song'),
        backgroundColor: Colors.blue.shade700,
      ),
      body: Column(
        children: [
          // ✅ Cụm nút điều khiển — Wrap để không bị overflow
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
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                  ),
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

          // ✅ Hai cột: dữ liệu quét & đồng bộ
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        color: Colors.blue.shade50,
                        padding: const EdgeInsets.all(8.0),
                        width: double.infinity,
                        child: const Text(
                          'Dữ liệu đã quét',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.blue,
                          ),
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
                        color: Colors.green.shade50,
                        padding: const EdgeInsets.all(8.0),
                        width: double.infinity,
                        child: const Text(
                          'Dữ liệu đồng bộ',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.green,
                          ),
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
      ),
    );
  }
}
