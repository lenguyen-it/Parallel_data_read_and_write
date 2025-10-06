import 'package:flutter/material.dart';
import 'package:paralled_data/database/history_database.dart';
import 'package:paralled_data/plugin/rfid_c72_plugin.dart';

class RfidScanPage extends StatefulWidget {
  const RfidScanPage({Key? key}) : super(key: key);

  @override
  State<RfidScanPage> createState() => _RfidScanPageState();
}

class _RfidScanPageState extends State<RfidScanPage> {
  bool _isConnected = false;
  bool _isScanning = false;
  bool _isContinuous = false;
  String _lastTag = 'Chưa có dữ liệu';
  List<Map<String, dynamic>> _recent = [];

  @override
  void initState() {
    super.initState();
    _attachStream();
    _connect();
    _loadRecent();
  }

  @override
  void dispose() {
    try {
      // đảm bảo dừng scan trước khi rời
      // RfidC72Plugin.stopScan;
      Future.delayed(const Duration(milliseconds: 120), () {
        RfidC72Plugin.close;
        RfidC72Plugin.closeScan;
      });
    } catch (_) {}
    super.dispose();
  }

  void _attachStream() {
    // Lắng nghe stream tags từ native plugin
    try {
      RfidC72Plugin.tagsStatusStream.receiveBroadcastStream().listen(
        (event) async {
          final tag = event?.toString() ?? '';
          debugPrint('[RFID] event: $tag');

          // update UI
          setState(() {
            _lastTag = tag;
          });

          // lưu vào DB (dùng helper chung)
          try {
            await HistoryDatabase.instance.insertScan(tag, status: 'success');
          } catch (e) {
            debugPrint('Lỗi lưu RFID vào DB: $e');
          }

          // refresh recent list
          _loadRecent();
        },
        onError: (err) async {
          debugPrint('[RFID] stream error: $err');
          setState(() {
            _lastTag = 'Lỗi stream: $err';
          });
          // optional: lưu lỗi
          try {
            await HistoryDatabase.instance.insertScan('RFID_STREAM_ERROR',
                status: 'failed', error: err.toString());
            _loadRecent();
          } catch (_) {}
        },
      );
    } catch (e) {
      debugPrint('Attach RFID stream failed: $e');
    }
  }

  Future<void> _connect() async {
    setState(() => _isConnected = false);
    try {
      final ok = await RfidC72Plugin.connect;
      debugPrint('RFID connect: $ok');
      setState(() => _isConnected = ok == true);
    } catch (e) {
      debugPrint('RFID connect error: $e');
      setState(() => _isConnected = false);
    }
  }

  Future<void> _scanSingle() async {
    if (!_isConnected) {
      _showSnack('Chưa kết nối thiết bị');
      return;
    }
    try {
      setState(() => _isScanning = true);
      await RfidC72Plugin.startSingle;
      // kết quả sẽ đến qua stream; không cần chờ trả về
    } catch (e) {
      debugPrint('Start single error: $e');
      _showSnack('Lỗi khi bắt đầu quét: $e');
      await HistoryDatabase.instance.insertScan('RFID_SINGLE_ERROR',
          status: 'failed', error: e.toString());
      _loadRecent();
    } finally {
      setState(() => _isScanning = false);
    }
  }

  Future<void> _startContinuous() async {
    if (!_isConnected) {
      _showSnack('Chưa kết nối thiết bị');
      return;
    }
    try {
      setState(() {
        _isContinuous = true;
        _isScanning = true;
      });
      await RfidC72Plugin.startContinuous;
      _showSnack('Bắt đầu quét liên tục');
    } catch (e) {
      debugPrint('Start continuous error: $e');
      _showSnack('Lỗi khi bắt đầu quét liên tục: $e');
      await HistoryDatabase.instance
          .insertScan('RFID_CONT_ERROR', status: 'failed', error: e.toString());
      _loadRecent();
      setState(() {
        _isContinuous = false;
        _isScanning = false;
      });
    }
  }

  Future<void> _stopScan() async {
    try {
      await RfidC72Plugin.stopScan;
      setState(() {
        _isContinuous = false;
        _isScanning = false;
        _lastTag = 'Đã dừng quét';
      });
      _showSnack('Đã dừng quét');
    } catch (e) {
      debugPrint('Stop scan error: $e');
      _showSnack('Lỗi khi dừng quét: $e');
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

  Widget _buildStatusChip(String status) {
    Color c;
    IconData ic;
    if (status == 'success') {
      c = Colors.green.shade100;
      ic = Icons.check_circle;
    } else if (status == 'failed') {
      c = Colors.red.shade100;
      ic = Icons.error;
    } else {
      c = Colors.orange.shade100;
      ic = Icons.sync;
    }
    return Chip(
      avatar: Icon(ic, size: 18, color: Colors.black54),
      label: Text(status),
      backgroundColor: c,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quét RFID (C72)'),
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
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                leading: CircleAvatar(
                    backgroundColor: Colors.blue.shade50,
                    child: const Icon(Icons.nfc, color: Colors.blue)),
                title: const Text('Tag mới nhất',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(_lastTag),
                trailing: _buildStatusChip('success'),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _connect,
                    icon: Icon(_isConnected ? Icons.check_circle : Icons.link),
                    label: Text(_isConnected ? 'Đã kết nối' : 'Kết nối'),
                    style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: _isConnected ? Colors.green : null),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _scanSingle,
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
                    onPressed: !_isScanning ? _startContinuous : null,
                    icon: const Icon(Icons.sync),
                    label: const Text('Quét liên tục'),
                    style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: Colors.lightBlueAccent),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isContinuous ? _stopScan : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Dừng'),
                    style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: Colors.redAccent),
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
                            leading: const Icon(Icons.nfc, color: Colors.blue),
                            title: Text(r['barcode'] ?? ''),
                            subtitle: Text('Quét lúc: ${ts.toString()}'),
                            trailing:
                                _buildStatusChip(r['status'] ?? 'pending'),
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
