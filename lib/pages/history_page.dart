import 'package:flutter/material.dart';
import 'package:paralled_data/database/history_database.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await HistoryDatabase.instance.getAllScans();
    setState(() => _items = rows.cast<Map<String, dynamic>>());
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Xoá toàn bộ lịch sử?'),
        content: const Text('Bạn có chắc muốn xoá toàn bộ lịch sử quét?'),
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

    if (confirm == true) {
      await HistoryDatabase.instance.clearHistory();
      await _load();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Đã xoá lịch sử')));
    }
  }

  Widget _statusBadge(String status) {
    if (status == 'success') {
      return Chip(
          backgroundColor: Colors.green.shade100, label: const Text('success'));
    }
    if (status == 'failed') {
      return Chip(
          backgroundColor: Colors.red.shade100, label: const Text('failed'));
    }
    return Chip(
        backgroundColor: Colors.lightBlue.shade100, label: Text(status));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lịch sử quét'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
          IconButton(
              onPressed: _clearAll, icon: const Icon(Icons.delete_forever)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _items.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 80),
                  Center(child: Text('Chưa có dữ liệu'))
                ],
              )
            : ListView.separated(
                itemCount: _items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final it = _items[i];
                  final ts = DateTime.fromMillisecondsSinceEpoch(
                      it['timestamp_device'] ?? 0);
                  return ListTile(
                    leading: Icon(
                        it['epc']?.startsWith('E') == true
                            ? Icons.nfc
                            : Icons.qr_code,
                        color: it['epc']?.startsWith('E') == true
                            ? Colors.blue
                            : Colors.orange),
                    title: Text(it['epc'] ?? ''),
                    subtitle:
                        Text('${ts.toString()}\n${it['last_error'] ?? ''}'),
                    trailing: _statusBadge(it['status'] ?? 'pending'),
                    isThreeLine: it['last_error'] != null,
                  );
                },
              ),
      ),
    );
  }
}
