import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:paralled_data/database/history_database.dart';
import 'package:paralled_data/plugin/rfid_bluetooth_plugin.dart';

class RfidTestBluetoothConnect extends StatefulWidget {
  const RfidTestBluetoothConnect({super.key});

  @override
  State<RfidTestBluetoothConnect> createState() =>
      _RfidTestBluetoothConnectState();
}

class _RfidTestBluetoothConnectState extends State<RfidTestBluetoothConnect> {
  // =================== Trạng thái ===================
  bool _isConnected = false;
  bool _showRfidSection = false;
  bool _isBluetoothEnabled = false;
  bool _isScanning = false;
  bool _isReading = false;

  bool _isCheckingConnection = true;

  String _connectedDeviceName = '';
  String _lastConnectedDeviceName = '';

  String _lastConnectedDeviceAddress = '';
  int _batteryLevel = 0;

  // =================== Danh sách & dữ liệu ===================
  final List<Map<String, String>> _deviceList = [];
  final List<Map<String, dynamic>> _rfidTags = [];
  List<Map<String, dynamic>> _localData = [];

  // =================== Stream & Timer ===================
  StreamSubscription? _scanSubscription;
  StreamSubscription? _rfidSubscription;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _configSubscription;
  StreamSubscription? _bluetoothStateSubscription;

  Timer? _syncTimer;
  Timer? _autoRefreshTimer;
  final Map<String, int> _retryCounter = {};
  bool _isSyncing = false;

  static const String serverUrl = 'http://192.168.15.194:5000/api/scans';

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _checkBluetoothStatus();
    _checkExistingConnection();
    _initializeListeners();
    _startSyncWorker();
    _startAutoRefresh();
  }

  Future<void> _checkExistingConnection() async {
    try {
      final isConnected = await RfidBlePlugin.getConnectionStatus();

      if (mounted) {
        setState(() {
          _isConnected = isConnected;
          _showRfidSection = isConnected;
          _isCheckingConnection = false;
        });

        if (isConnected) {
          // Nếu đã kết nối, load dữ liệu và lấy battery
          await _loadLocal();
          await RfidBlePlugin.getBatteryLevel();

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Đã khôi phục kết nối thiết bị'),
                duration: Duration(seconds: 2),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('Lỗi kiểm tra kết nối: $e');
      if (mounted) {
        setState(() {
          _isCheckingConnection = false;
          _showRfidSection = false;
          _isConnected = false;
        });
      }
    }
  }

  // =================== Bluetooth ===================
  Future<void> _checkBluetoothStatus() async {
    final isEnabled = await RfidBlePlugin.checkBluetoothEnabled();
    if (mounted) setState(() => _isBluetoothEnabled = isEnabled);
  }

  Future<void> _enableBluetooth() async {
    await RfidBlePlugin.enableBluetooth();
  }

  Future<void> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetooth,
      Permission.location,
      Permission.locationWhenInUse,
    ].request();

    bool allGranted =
        statuses.values.every((status) => status.isGranted || status.isLimited);

    if (!allGranted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng cấp đầy đủ quyền Bluetooth và Location'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  void _initializeListeners() {
    _scanSubscription = RfidBlePlugin.scanResults.listen(
      (device) {
        if (!mounted) return;
        setState(() {
          bool exists =
              _deviceList.any((d) => d['address'] == device['address']);
          if (!exists) _deviceList.add(device);
        });
      },
    );

    _connectionSubscription =
        RfidBlePlugin.connectionState.listen((isConnected) {
      if (!mounted) return;
      setState(() {
        _isConnected = isConnected;
        if (!isConnected) {
          _connectedDeviceName = '';
          _rfidTags.clear();
          _batteryLevel = 0;
          _showRfidSection = true; // vẫn hiển thị section RFID
        }
      });
    });

    _rfidSubscription = RfidBlePlugin.rfidStream.listen(
      (data) async {
        final epc = (data['epc_ascii']?.toString().trim() ?? '');
        if (epc.isEmpty) return;
        if (!mounted) return;

        setState(() {
          int idx = _rfidTags.indexWhere((t) => t['epc_ascii'] == epc);
          if (idx >= 0) {
            _rfidTags[idx] = data;
          } else {
            _rfidTags.insert(0, data);
          }
        });

        final idLocal =
            await HistoryDatabase.instance.insertScan(epc, status: 'pending');
        _sendToServer(epc, idLocal);
        await _loadLocal();
      },
    );

    _configSubscription = RfidBlePlugin.configStream.listen((cfg) {
      if (cfg['type'] == 'battery' && mounted) {
        setState(() {
          _batteryLevel = cfg['battery'] ?? 0;
        });
      }
    });
  }

  // =================== Scan / Connect ===================
  Future<void> _startScanBluetooth() async {
    if (!_isBluetoothEnabled) {
      await _enableBluetooth();
      return;
    }
    setState(() {
      _isScanning = true;
      _deviceList.clear();
    });
    await RfidBlePlugin.startScan();
    Future.delayed(const Duration(seconds: 10), () {
      if (_isScanning) _stopScan();
    });
  }

  Future<void> _stopScan() async {
    await RfidBlePlugin.stopScan();
    if (!mounted) return;
    setState(() => _isScanning = false);
  }

  Future<void> _connectToDevice(String name, String address) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      String result = await RfidBlePlugin.connectToDevice('', address);
      if (!mounted) return;
      Navigator.pop(context);
      if (result.isNotEmpty) {
        setState(() {
          _connectedDeviceName = name;
          _lastConnectedDeviceName = name;
          _lastConnectedDeviceAddress = address;
          _isConnected = true;
          _showRfidSection = true;
        });
        await _loadLocal();
        await RfidBlePlugin.getBatteryLevel();
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Lỗi kết nối: $e')));
    }
  }

  Future<void> _disconnect() async {
    await RfidBlePlugin.disconnectDevice();
    if (!mounted) return;
    setState(() {
      _isConnected = false;
      _connectedDeviceName = '';
      _rfidTags.clear();
      _batteryLevel = 0;
    });
  }

  // =================== Load dữ liệu ===================
  Future<void> _loadLocal() async {
    final data = await HistoryDatabase.instance.getAllScans();
    if (!mounted) return;
    setState(() => _localData = data);
  }

  Future<void> _sendToServer(String tag, String idLocal) async {
    final url = Uri.parse(serverUrl);
    final body = {
      'barcode': tag,
      'timestamp_device': DateTime.now().toIso8601String(),
      'status_sync': true,
    };

    try {
      final resp = await http.post(url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body));

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        await HistoryDatabase.instance.updateStatusById(idLocal, 'synced');
        _retryCounter.remove(idLocal);
        await _loadLocal();
      } else {
        _handleRetryFail(idLocal);
      }
    } catch (_) {
      _handleRetryFail(idLocal);
    }
  }

  void _handleRetryFail(String idLocal) async {
    _retryCounter[idLocal] = (_retryCounter[idLocal] ?? 0) + 1;
    if (_retryCounter[idLocal]! >= 3) {
      await HistoryDatabase.instance.updateStatusById(idLocal, 'failed');
      _retryCounter.remove(idLocal);
    } else {
      await HistoryDatabase.instance.updateStatusById(idLocal, 'pending');
    }
    await _loadLocal();
  }

  void _startSyncWorker() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_isSyncing) return;
      _isSyncing = true;
      try {
        final pending = await HistoryDatabase.instance.getPendingScans();
        for (final scan in pending) {
          final tag = scan['barcode'] as String;
          final idLocal = scan['id_local'] as String;
          _sendToServer(tag, idLocal);
        }
      } finally {
        _isSyncing = false;
      }
    });
  }

  void _startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await _loadLocal();
    });
  }

  // // =================== UI ===================
  // @override
  // Widget build(BuildContext context) {
  //   return Scaffold(
  //     appBar: AppBar(title: const Text('RFID Bluetooth')),
  //     body: Column(
  //       children: [
  //         _buildConnectionStatus(),
  //         Expanded(
  //           child: _showRfidSection ? _buildRfidSection() : _buildDeviceList(),
  //         ),
  //       ],
  //     ),
  //   );
  // }

  // =================== UI ===================
  @override
  Widget build(BuildContext context) {
    if (_isCheckingConnection) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('RFID Bluetooth - Đồng bộ'),
        ),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Đang kiểm tra kết nối...'),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('RFID Bluetooth - Đồng bộ'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Icon(
                  _isBluetoothEnabled
                      ? Icons.bluetooth
                      : Icons.bluetooth_disabled,
                  size: 20,
                  color: _isBluetoothEnabled ? Colors.blue : Colors.red,
                ),
                if (!_isBluetoothEnabled)
                  TextButton(
                    onPressed: _enableBluetooth,
                    child: const Text('Bật', style: TextStyle(fontSize: 12)),
                  ),
                if (_isConnected)
                  Row(
                    children: [
                      const SizedBox(width: 8),
                      const Icon(Icons.battery_charging_full, size: 20),
                      const SizedBox(width: 4),
                      Text('$_batteryLevel%'),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildConnectionStatus(),
          Expanded(
            child: _showRfidSection ? _buildRfidSection() : _buildDeviceList(),
          ),
        ],
      ),
    );
  }

  // =================== Connection Status ===================
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
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 14),
                  )
                else if (_lastConnectedDeviceName.isNotEmpty)
                  Text(
                    _lastConnectedDeviceName,
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 14),
                  ),
              ],
            ),
          ),
          _buildActionButton(),
        ],
      ),
    );
  }

  // =================== Nút hành động riêng ===================
  Widget _buildActionButton() {
    // Nếu UI quét RFID
    if (_showRfidSection) {
      return ElevatedButton.icon(
        onPressed: _isConnected
            ? _disconnect
            : (_lastConnectedDeviceAddress.isNotEmpty
                ? () => _connectToDevice(
                    _lastConnectedDeviceName, _lastConnectedDeviceAddress)
                : null),
        icon: Icon(_isConnected ? Icons.close : Icons.bluetooth),
        label: Text(_isConnected ? 'Ngắt' : 'Kết nối lại'),
        style: ElevatedButton.styleFrom(
          backgroundColor: _isConnected ? Colors.red : null,
        ),
      );
    }
    // Nếu UI Scan Bluetooth
    return ElevatedButton.icon(
      onPressed: _isScanning ? _stopScan : _startScanBluetooth,
      icon: Icon(_isScanning ? Icons.stop : Icons.search),
      label: Text(_isScanning ? 'Dừng' : 'Scan'),
    );
  }

  // =================== Device List ===================
  Widget _buildDeviceList() {
    if (!_isBluetoothEnabled) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.bluetooth_disabled, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('Bluetooth chưa được bật',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _enableBluetooth,
              icon: const Icon(Icons.bluetooth),
              label: const Text('Bật Bluetooth'),
            ),
          ],
        ),
      );
    }

    if (_deviceList.isEmpty && !_isScanning) {
      return const Center(child: Text('Nhấn "Scan" để tìm thiết bị Bluetooth'));
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
      itemBuilder: (context, i) {
        final device = _deviceList[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: ListTile(
            leading: const Icon(Icons.bluetooth, color: Colors.blue),
            title: Text(device['name'] ?? 'Unknown'),
            subtitle: Text(device['address'] ?? ''),
            trailing: ElevatedButton(
              onPressed: () => _connectToDevice(
                  device['name'] ?? 'Unknown', device['address'] ?? ''),
              child: const Text('Kết nối'),
            ),
          ),
        );
      },
    );
  }

  // =================== RFID Section ===================
  Widget _buildRfidSection() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: (!_isConnected)
                    ? null
                    : (_isReading ? _stopReading : _startReading),
                icon: Icon(_isReading ? Icons.stop : Icons.play_arrow),
                label: Text(_isReading ? 'Dừng quét' : 'Quét liên tục'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isReading ? Colors.red : Colors.green,
                ),
              ),
              ElevatedButton.icon(
                onPressed: (!_isConnected || _isReading) ? null : _singleRead,
                icon: const Icon(Icons.radar),
                label: const Text('Quét 1 lần'),
              ),
              ElevatedButton.icon(
                onPressed: _clearHistory,
                icon: const Icon(Icons.delete_forever),
                label: const Text('Xóa lịch sử'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
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
        Expanded(
          child: Row(
            children: [
              // Scanned data
              Expanded(
                child: Column(
                  children: [
                    Container(
                      height: 60,
                      color: Colors.blue.shade50,
                      padding: const EdgeInsets.all(8),
                      width: double.infinity,
                      child: Text(
                        'Dữ liệu đã quét (${_localData.length})',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, color: Colors.blue),
                      ),
                    ),
                    Expanded(child: _buildScannedList()),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              // Synced data
              Expanded(
                child: Column(
                  children: [
                    Container(
                      height: 60,
                      color: Colors.green.shade50,
                      padding: const EdgeInsets.all(8),
                      width: double.infinity,
                      child: Text(
                        'Dữ liệu đồng bộ (${_localData.where((e) => e['status'] == 'synced').length}/${_localData.length})',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, color: Colors.green),
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
    if (_localData.isEmpty) return const Center(child: Text('Chưa có dữ liệu'));
    return ListView.builder(
      itemCount: _localData.length,
      itemBuilder: (_, i) => Container(
        height: 70,
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.black12))),
        child: ListTile(
            title: Text(_localData[i]['barcode'] ?? '---',
                style: const TextStyle(fontSize: 13))),
      ),
    );
  }

  Widget _buildSyncedList() {
    if (_localData.isEmpty) {
      return const Center(child: Text('Không có dữ liệu đồng bộ'));
    }

    final statusMap = {
      'pending': 'Đang chờ',
      'synced': 'Thành công',
      'failed': 'Thất bại'
    };

    return ListView.builder(
      itemCount: _localData.length,
      itemBuilder: (_, i) {
        final item = _localData[i];
        final status = item['status'] ?? 'pending';

        Color backgroundColor;
        Color textColor;

        switch (status) {
          case 'synced':
            backgroundColor = const Color(0xFFE8F5E9);
            textColor = Colors.green;
            break;
          case 'failed':
            backgroundColor = const Color(0xFFFFEBEE);
            textColor = Colors.red;
            break;
          default:
            backgroundColor = const Color(0xFFFFF8E1);
            textColor = Colors.orange;
        }

        return Container(
          height: 70,
          color: backgroundColor,
          child: ListTile(
            title: Text(
              item['barcode'] ?? '---',
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              'Trạng thái: ${statusMap[status] ?? status}',
              style: TextStyle(fontSize: 12, color: textColor),
            ),
          ),
        );
      },
    );
  }

  Future<void> _singleRead() async {
    if (!_isConnected) return;
    await RfidBlePlugin.singleInventory();
  }

  Future<void> _startReading() async {
    if (!_isConnected) return;
    await RfidBlePlugin.startInventory();
    if (!mounted) return;
    setState(() => _isReading = true);
  }

  Future<void> _stopReading() async {
    if (!_isConnected) return;
    await RfidBlePlugin.stopInventory();
    if (!mounted) return;
    setState(() => _isReading = false);
  }

  Future<void> _clearHistory() async {
    await HistoryDatabase.instance.clearHistory();
    await _loadLocal();
    _rfidTags.clear();
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
    _bluetoothStateSubscription?.cancel();
    _syncTimer?.cancel();
    _autoRefreshTimer?.cancel();
    super.dispose();
  }
}
