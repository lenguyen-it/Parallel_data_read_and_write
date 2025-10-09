import 'package:flutter/material.dart';
import 'package:paralled_data/plugin/rfid_bluetooth_plugin.dart';
import 'dart:async';
import 'dart:convert';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:paralled_data/database/history_database.dart';

class RfidTestBluetoothConnect extends StatefulWidget {
  const RfidTestBluetoothConnect({super.key});

  @override
  State<RfidTestBluetoothConnect> createState() =>
      _RfidTestBluetoothConnectState();
}

class _RfidTestBluetoothConnectState extends State<RfidTestBluetoothConnect> {
  // Danh sách thiết bị Bluetooth
  final List<Map<String, String>> _deviceList = [];

  // Trạng thái kết nối
  bool _isConnected = false;
  String _connectedDeviceName = '';

  // Trạng thái scanning
  bool _isScanning = false;

  // Trạng thái đọc RFID
  bool _isReading = false;

  // Danh sách RFID đã đọc (hiển thị realtime)
  final List<Map<String, dynamic>> _rfidTags = [];

  // Danh sách dữ liệu local (đã quét)
  List<Map<String, dynamic>> _localData = [];

  // Stream subscriptions
  StreamSubscription? _scanSubscription;
  StreamSubscription? _rfidSubscription;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _configSubscription;

  // Battery level
  int _batteryLevel = 0;

  // Sync worker
  Timer? _syncTimer;
  Timer? _autoRefreshTimer;
  bool _isSyncing = false;
  final Map<String, int> _retryCounter = {};

  static const String serverUrl = 'http://192.168.15.194:5000/api/scans';

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _initializeListeners();
    _startSyncWorker();
    _startAutoRefresh();
  }

  // Yêu cầu quyền
  Future<void> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetooth,
      Permission.location,
      Permission.locationWhenInUse,
    ].request();

    debugPrint('Permission statuses: $statuses');

    bool allGranted =
        statuses.values.every((status) => status.isGranted || status.isLimited);

    if (!allGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Vui lòng cấp đầy đủ quyền Bluetooth và Location'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  // Khởi tạo các listener
  void _initializeListeners() {
    debugPrint('🔵 Setting up listeners...');

    // Lắng nghe kết quả scan
    _scanSubscription = RfidBlePlugin.scanResults.listen(
      (device) {
        debugPrint(
            '📱 Received device: ${device['name']} - ${device['address']}');
        setState(() {
          bool exists =
              _deviceList.any((d) => d['address'] == device['address']);
          if (!exists) {
            _deviceList.add(device);
            debugPrint('✓ Device added to list. Total: ${_deviceList.length}');
          }
        });
      },
      onError: (error) {
        debugPrint('❌ Scan error: $error');
      },
      cancelOnError: false,
    );

    // Lắng nghe trạng thái kết nối
    _connectionSubscription = RfidBlePlugin.connectionState.listen(
      (isConnected) {
        debugPrint('🔗 Connection state changed: $isConnected');
        setState(() {
          _isConnected = isConnected;
          if (!isConnected) {
            _connectedDeviceName = '';
            _rfidTags.clear();
          }
        });
      },
      onError: (error) {
        debugPrint('❌ Connection error: $error');
      },
      cancelOnError: false,
    );

    // Lắng nghe dữ liệu RFID
    _rfidSubscription = RfidBlePlugin.rfidStream.listen(
      (data) async {
        debugPrint('📡 Received RFID data: $data');
        final epc = data['epc_ascii']?.toString().trim() ?? '';
        debugPrint('📡 Received RFID: $epc');

        if (epc.isEmpty) return;

        setState(() {
          // Cập nhật danh sách hiển thị realtime
          int existingIndex =
              _rfidTags.indexWhere((tag) => tag['epc_ascii'] == epc);

          if (existingIndex >= 0) {
            _rfidTags[existingIndex] = data;
          } else {
            _rfidTags.insert(0, data);
          }
        });

        // Lưu vào database local
        final idLocal = await HistoryDatabase.instance.insertScan(
          epc,
          status: 'pending',
        );

        // Gửi lên server
        _sendToServer(epc, idLocal);

        // Reload dữ liệu local
        await _loadLocal();
      },
      onError: (error) async {
        debugPrint('❌ RFID error: $error');
        await HistoryDatabase.instance.insertScan(
          'RFID_STREAM_ERROR',
          status: 'failed',
          error: error.toString(),
        );
      },
      cancelOnError: false,
    );

    // Lắng nghe config (battery, firmware...)
    _configSubscription = RfidBlePlugin.configStream.listen(
      (config) {
        debugPrint('⚙️ Received config: $config');
        if (config['type'] == 'battery') {
          setState(() {
            _batteryLevel = config['battery'] ?? 0;
          });
        }
      },
      onError: (error) {
        debugPrint('❌ Config error: $error');
      },
      cancelOnError: false,
    );

    debugPrint('✓ All listeners set up');
  }

  // Load dữ liệu từ local database
  Future<void> _loadLocal() async {
    final data = await HistoryDatabase.instance.getAllScans();
    setState(() => _localData = data);
  }

  // Auto refresh mỗi 2 giây
  void _startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await _loadLocal();
    });
  }

  // Gửi dữ liệu lên server
  Future<void> _sendToServer(String tag, String idLocal) async {
    final url = Uri.parse(serverUrl);
    final body = {
      'barcode': tag,
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
        await _loadLocal();
      } else {
        _handleRetryFail(idLocal, tag, 'Server error ${response.statusCode}');
      }
    } catch (e) {
      _handleRetryFail(idLocal, tag, e.toString());
    }
  }

  // Xử lý retry khi fail
  void _handleRetryFail(String idLocal, String tag, String error) async {
    _retryCounter[idLocal] = (_retryCounter[idLocal] ?? 0) + 1;
    if (_retryCounter[idLocal]! >= 3) {
      await HistoryDatabase.instance.updateStatusById(idLocal, 'failed');
      _retryCounter.remove(idLocal);
    } else {
      await HistoryDatabase.instance.updateStatusById(idLocal, 'pending');
    }
    await _loadLocal();
  }

  // Worker đồng bộ định kỳ
  void _startSyncWorker() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_isSyncing) return;
      _isSyncing = true;
      try {
        await _retryPendingScans();
      } finally {
        _isSyncing = false;
      }
    });
  }

  // Retry các bản ghi pending
  Future<void> _retryPendingScans() async {
    final pending = await HistoryDatabase.instance.getPendingScans();
    for (final scan in pending) {
      final tag = scan['barcode'] as String;
      final idLocal = scan['id_local'] as String;
      _sendToServer(tag, idLocal);
    }
  }

  // Bắt đầu scan Bluetooth
  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _deviceList.clear();
    });

    await RfidBlePlugin.startScan();

    // Tự động dừng sau 10 giây
    Future.delayed(const Duration(seconds: 10), () {
      if (_isScanning) {
        _stopScan();
      }
    });
  }

  // Dừng scan Bluetooth
  Future<void> _stopScan() async {
    await RfidBlePlugin.stopScan();
    setState(() {
      _isScanning = false;
    });
  }

  // Kết nối với thiết bị
  Future<void> _connectToDevice(String name, String address) async {
    try {
      if (_isScanning) {
        await _stopScan();
      }

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(),
        ),
      );

      String result = await RfidBlePlugin.connectToDevice('', address);

      if (mounted) Navigator.pop(context);

      if (result.isNotEmpty) {
        setState(() {
          _connectedDeviceName = name;
        });

        await Future.delayed(const Duration(seconds: 1));
        await RfidBlePlugin.getBatteryLevel();
        await _loadLocal();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Đã kết nối với $name')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi kết nối: $e')),
        );
      }
    }
  }

  // Ngắt kết nối
  Future<void> _disconnect() async {
    await RfidBlePlugin.disconnectDevice();
    setState(() {
      _isConnected = false;
      _connectedDeviceName = '';
      _isReading = false;
      _rfidTags.clear();
      _batteryLevel = 0;
    });
  }

  // Bắt đầu đọc RFID liên tục
  Future<void> _startReading() async {
    await RfidBlePlugin.startInventory();
    setState(() {
      _isReading = true;
    });
  }

  // Dừng đọc RFID
  Future<void> _stopReading() async {
    await RfidBlePlugin.stopInventory();
    setState(() {
      _isReading = false;
    });
  }

  // Đọc RFID đơn lẻ
  Future<void> _singleRead() async {
    await RfidBlePlugin.singleInventory();
  }

  // Xóa danh sách RFID hiển thị
  void _clearRfidList() {
    setState(() {
      _rfidTags.clear();
    });
  }

  // Xóa lịch sử local
  Future<void> _clearHistory() async {
    await HistoryDatabase.instance.clearHistory();
    await _loadLocal();
    setState(() {
      _rfidTags.clear();
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã xóa lịch sử')),
      );
    }
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _rfidSubscription?.cancel();
    _connectionSubscription?.cancel();
    _configSubscription?.cancel();
    _syncTimer?.cancel();
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RFID Bluetooth - Đồng bộ'),
        actions: [
          if (_isConnected)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Center(
                child: Row(
                  children: [
                    const Icon(Icons.battery_charging_full, size: 20),
                    const SizedBox(width: 4),
                    Text('$_batteryLevel%'),
                  ],
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          _buildConnectionStatus(),
          Expanded(
            child: _isConnected ? _buildRfidSection() : _buildDeviceList(),
          ),
        ],
      ),
    );
  }

  // Hiển thị trạng thái kết nối
  Widget _buildConnectionStatus() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: _isConnected ? Colors.green.shade100 : Colors.grey.shade200,
      child: Row(
        children: [
          Icon(
            _isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            color: _isConnected ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isConnected ? 'Đã kết nối' : 'Chưa kết nối',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                if (_isConnected)
                  Text(
                    _connectedDeviceName,
                    style: TextStyle(
                      color: Colors.grey.shade700,
                      fontSize: 14,
                    ),
                  ),
              ],
            ),
          ),
          if (_isConnected)
            ElevatedButton.icon(
              onPressed: _disconnect,
              icon: const Icon(Icons.close),
              label: const Text('Ngắt'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
            )
          else
            ElevatedButton.icon(
              onPressed: _isScanning ? _stopScan : _startScan,
              icon: Icon(_isScanning ? Icons.stop : Icons.search),
              label: Text(_isScanning ? 'Dừng' : 'Scan'),
            ),
        ],
      ),
    );
  }

  // Danh sách thiết bị Bluetooth
  Widget _buildDeviceList() {
    if (_deviceList.isEmpty && !_isScanning) {
      return const Center(
        child: Text('Nhấn "Scan" để tìm thiết bị Bluetooth'),
      );
    }

    if (_isScanning && _deviceList.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Đang tìm kiếm thiết bị...'),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _deviceList.length,
      itemBuilder: (context, index) {
        final device = _deviceList[index];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: ListTile(
            leading: const Icon(Icons.bluetooth, color: Colors.blue),
            title: Text(device['name'] ?? 'Unknown'),
            subtitle: Text(device['address'] ?? ''),
            trailing: ElevatedButton(
              onPressed: () => _connectToDevice(
                device['name'] ?? 'Unknown',
                device['address'] ?? '',
              ),
              child: const Text('Kết nối'),
            ),
          ),
        );
      },
    );
  }

  // Phần đọc RFID với 2 cột
  Widget _buildRfidSection() {
    return Column(
      children: [
        // Nút điều khiển
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: _isReading ? _stopReading : _startReading,
                icon: Icon(_isReading ? Icons.stop : Icons.play_arrow),
                label: Text(_isReading ? 'Dừng quét' : 'Quét liên tục'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isReading ? Colors.red : Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
              ElevatedButton.icon(
                onPressed: _isReading ? null : _singleRead,
                icon: const Icon(Icons.refresh),
                label: const Text('Quét 1 lần'),
              ),
              ElevatedButton.icon(
                onPressed: _clearRfidList,
                icon: const Icon(Icons.clear_all),
                label: const Text('Xóa hiển thị'),
              ),
              ElevatedButton.icon(
                onPressed: _clearHistory,
                icon: const Icon(Icons.delete_forever),
                label: const Text('Xóa lịch sử'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                ),
              ),
              ElevatedButton.icon(
                onPressed: _loadLocal,
                icon: const Icon(Icons.refresh),
                label: const Text('Tải lại'),
              ),
            ],
          ),
        ),

        const Divider(height: 1),

        // ✅ Hai cột: dữ liệu quét & đồng bộ
        Expanded(
          child: Row(
            children: [
              // Cột 1: Dữ liệu đã quét (từ local database)
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
                        style: const TextStyle(
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
              // Cột 2: Dữ liệu đồng bộ
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
                        style: const TextStyle(
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
    );
  }

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
            // leading: CircleAvatar(
            //   backgroundColor: Colors.blue,
            //   child: Text(
            //     '${i + 1}',
            //     style: const TextStyle(color: Colors.white, fontSize: 12),
            //   ),
            // ),
            title: Text(
              item['barcode'] ?? '---',
              style: const TextStyle(fontSize: 13),
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
        final code = item['barcode'] ?? '---';
        final status = item['status'] ?? 'pending';

        final statusText = statusMap[status] ?? status;

        Color bgColor;
        Color textColor;
        // IconData icon;

        switch (status) {
          case 'synced':
            bgColor = const Color(0xFFE8F5E9);
            textColor = Colors.green;
            // icon = Icons.check_circle;
            break;
          case 'failed':
            bgColor = const Color(0xFFFFEBEE);
            textColor = Colors.red;
            // icon = Icons.error;
            break;
          default:
            bgColor = const Color(0xFFFFF8E1);
            textColor = Colors.orange;
          // icon = Icons.sync;
        }

        return Container(
          height: 70,
          color: bgColor,
          child: ListTile(
            // leading: Icon(icon, color: textColor),
            title: Text(
              code,
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              'Trạng thái: $statusText',
              style: TextStyle(
                fontSize: 12,
                color: textColor,
              ),
            ),
          ),
        );
      },
    );
  }
}
