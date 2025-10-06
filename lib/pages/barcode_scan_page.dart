import 'package:flutter/material.dart';
import 'package:paralled_data/database/history_database.dart';
import 'package:paralled_data/plugin/rfid_c72_plugin.dart';

class BarcodeScanPage extends StatefulWidget {
  const BarcodeScanPage({Key? key}) : super(key: key);

  @override
  State<BarcodeScanPage> createState() => _BarcodeScanPageState();
}

class _BarcodeScanPageState extends State<BarcodeScanPage> {
  bool _isConnected = false;
  bool _isBarcodeScanning = false;
  bool _isContinuousModeBarcode = false;
  String _lastCode = 'Chưa có dữ liệu';
  List<Map<String, dynamic>> _recent = [];

  @override
  void initState() {
    super.initState();
    _attachBarcodeStream();
    _connectBarcode();
    _loadRecent();
  }

  @override
  void dispose() {
    try {
      RfidC72Plugin.stopScanBarcode;
      Future.delayed(const Duration(milliseconds: 150), () {
        RfidC72Plugin.closeScan;
        RfidC72Plugin.close;
      });
    } catch (_) {}
    super.dispose();
  }

  // Lắng nghe dữ liệu barcode trả về từ plugin
  void _attachBarcodeStream() {
    try {
      RfidC72Plugin.barcodeStatusStream.receiveBroadcastStream().listen(
        (event) async {
          final code = event?.toString() ?? '';
          debugPrint('[BARCODE] event: $code');

          if (code == 'SCANNING' || code == 'STOPPED') {
            setState(() => _isBarcodeScanning = code == 'SCANNING');
            return;
          }

          // Hiển thị mã quét được
          setState(() => _lastCode = code);

          final normalized = _normalizeCode(code);

          try {
            await HistoryDatabase.instance
                .insertScan(normalized, status: 'success');
          } catch (e) {
            debugPrint('Lỗi lưu barcode: $e');
          }

          _loadRecent();
        },
        onError: (err) async {
          debugPrint('[BARCODE] stream error: $err');
          await HistoryDatabase.instance.insertScan(
            'BARCODE_STREAM_ERROR',
            status: 'failed',
            error: err.toString(),
          );
          setState(() => _lastCode = 'Lỗi stream: $err');
          _loadRecent();
        },
      );
    } catch (e) {
      debugPrint('Attach barcode stream failed: $e');
    }
  }

  String _normalizeCode(String raw) {
    if (raw.contains('://')) {
      try {
        final parts = raw.split('/');
        return parts.isNotEmpty ? parts.last : raw;
      } catch (_) {
        return raw;
      }
    }
    return raw;
  }

  Future<void> _connectBarcode() async {
    setState(() => _isConnected = false);
    try {
      final ok = await RfidC72Plugin.connectBarcode;
      debugPrint('Barcode connect: $ok');
      setState(() => _isConnected = ok == true);
    } catch (e) {
      debugPrint('Barcode connect error: $e');
      setState(() => _isConnected = false);
    }
  }

  Future<void> _startSingleBarcode() async {
    if (!_isConnected) {
      _showSnack('⚠️ Chưa kết nối thiết bị');
      return;
    }
    try {
      setState(() => _isBarcodeScanning = true);
      await RfidC72Plugin.scanBarcodeSingle;
      setState(() => _isBarcodeScanning = false);
    } catch (e) {
      debugPrint('Start barcode single error: $e');
      await HistoryDatabase.instance.insertScan('BARCODE_SINGLE_ERROR',
          status: 'failed', error: e.toString());
      _loadRecent();
      setState(() => _isBarcodeScanning = false);
    }
  }

  Future<void> _startContinuousBarcode() async {
    if (!_isConnected) {
      _showSnack('⚠️ Chưa kết nối thiết bị');
      return;
    }
    try {
      setState(() {
        _isContinuousModeBarcode = true;
        _isBarcodeScanning = true;
      });
      await RfidC72Plugin.scanBarcodeContinuous;
      _showSnack('Bắt đầu quét barcode liên tục');
    } catch (e) {
      debugPrint('Barcode continuous error: $e');
      await HistoryDatabase.instance.insertScan('BARCODE_CONT_ERROR',
          status: 'failed', error: e.toString());
      _loadRecent();
      setState(() {
        _isContinuousModeBarcode = false;
        _isBarcodeScanning = false;
      });
    }
  }

  Future<void> _stopBarcodeScan() async {
    try {
      await RfidC72Plugin.stopScanBarcode;
      setState(() {
        _isBarcodeScanning = false;
        _isContinuousModeBarcode = false;
        _lastCode = 'Đã dừng quét';
      });
      _showSnack('Đã dừng quét barcode');
    } catch (e) {
      debugPrint('Stop barcode error: $e');
      _showSnack('Lỗi dừng quét: $e');
    }
  }

  Future<void> _loadRecent() async {
    final rows = await HistoryDatabase.instance.getAllScans();
    setState(() => _recent = rows.cast<Map<String, dynamic>>());
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Xoá toàn bộ lịch sử?'),
        content: const Text(
            'Bạn có chắc muốn xoá toàn bộ lịch sử quét trên thiết bị?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Huỷ')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Xoá', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) {
      await HistoryDatabase.instance.clearHistory();
      await _loadRecent();
      _showSnack('Đã xoá lịch sử');
    }
  }

  void _showSnack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Widget _statusChip(String s) {
    if (s == 'success') {
      return Chip(
          backgroundColor: Colors.green.shade100, label: const Text('success'));
    }
    if (s == 'failed') {
      return Chip(
          backgroundColor: Colors.red.shade100, label: const Text('failed'));
    }
    return Chip(backgroundColor: Colors.orange.shade100, label: Text(s));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quét Barcode (C72)'),
        backgroundColor: _isConnected ? Colors.green : Colors.redAccent,
        actions: [
          IconButton(onPressed: _loadRecent, icon: const Icon(Icons.refresh)),
          IconButton(
              onPressed: _clearAll, icon: const Icon(Icons.delete_forever)),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Card(
              elevation: 3,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              child: ListTile(
                leading: CircleAvatar(
                    backgroundColor: Colors.orange.shade50,
                    child: const Icon(Icons.qr_code, color: Colors.orange)),
                title: const Text('Mã mới nhất',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(_lastCode),
                trailing: _statusChip('success'),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _connectBarcode,
                    icon: Icon(_isConnected ? Icons.check_circle : Icons.link),
                    label: Text(_isConnected ? 'Đã kết nối' : 'Kết nối'),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      backgroundColor: _isConnected ? Colors.green : null,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: !_isBarcodeScanning ? _startSingleBarcode : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Quét 1 lần'),
                    style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: !_isContinuousModeBarcode
                        ? _startContinuousBarcode
                        : null,
                    icon: const Icon(Icons.sync),
                    label: const Text('Quét liên tục'),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      backgroundColor: Colors.lightBlueAccent,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed:
                        _isContinuousModeBarcode ? _stopBarcodeScan : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Dừng'),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      backgroundColor: Colors.redAccent,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _loadRecent,
                child: _recent.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          SizedBox(height: 80),
                          Center(child: Text('Chưa có dữ liệu quét'))
                        ],
                      )
                    : ListView.separated(
                        itemCount: _recent.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, idx) {
                          final r = _recent[idx];
                          final ts = DateTime.fromMillisecondsSinceEpoch(
                              r['timestamp_device'] ?? 0);
                          return ListTile(
                            leading:
                                const Icon(Icons.qr_code, color: Colors.orange),
                            title: Text(r['barcode'] ?? ''),
                            subtitle: Text('Quét lúc: ${ts.toString()}'),
                            trailing: _statusChip(r['status'] ?? 'pending'),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
