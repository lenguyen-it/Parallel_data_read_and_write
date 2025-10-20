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
  String? _latestRawCode;

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
    // _subscription = _scanService.codeStream.listen((_) async {
    //   await _loadLocal();
    // });

    _subscription = _scanService.codeStream.listen((rawCode) async {
      setState(() {
        // thêm một biến mới để hiển thị mã gốc tạm thời
        _latestRawCode = rawCode;
      });
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

  Widget _buildScannedLastest() {
    if (_localData.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8.0),
        child: Center(
          child: Text('Chưa có dữ liệu'),
        ),
      );
    }

    // final latest = _localData.first;

    final latestCode = _latestRawCode ??
        (_localData.isNotEmpty ? _localData.first['epc'] : '---');

    return Container(
      width: double.infinity,
      color: Colors.blue.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      margin: const EdgeInsets.only(top: 6, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'QRcode mới nhất',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'Mã: $latestCode',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
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
              item['epc'] ?? '---',
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
        final code = item['epc'] ?? '---';
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

          _buildScannedLastest(),

          const Divider(height: 1),

          // ✅ Hai cột: dữ liệu quét & đồng bộ
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        height: 60,
                        color: Colors.blue.shade50,
                        padding: const EdgeInsets.all(8.0),
                        width: double.infinity,
                        child: Text(
                          'Dữ liệu đã quét (${_localData.length})',
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
                        height: 60,
                        color: Colors.green.shade50,
                        padding: const EdgeInsets.all(8.0),
                        width: double.infinity,
                        child: Text(
                          'Dữ liệu đồng bộ (${_localData.where((e) => e['status'] == 'synced').length}/${_localData.length})',
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
