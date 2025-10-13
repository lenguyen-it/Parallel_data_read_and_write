import 'dart:async';

import 'package:flutter/material.dart';
import 'package:paralled_data/services/rfid_scan_bluetooth_service.dart';
import 'package:permission_handler/permission_handler.dart';

class RfidScanBluetoothPage extends StatefulWidget {
  const RfidScanBluetoothPage({super.key});

  @override
  State<RfidScanBluetoothPage> createState() => _RfidScanBluetoothPageState();
}

class _RfidScanBluetoothPageState extends State<RfidScanBluetoothPage> {
  final RfidScanBluetoothService _service = RfidScanBluetoothService();

  // =================== Các biến trạng thái cho kết nối và Bluetooth ===================
  bool _isConnected = false;
  bool _showRfidSection = false;
  bool _isBluetoothEnabled = false;
  bool _isScanning = false;
  bool _isReading = false;
  bool _isCheckingConnection = true;

  // =================== Thông tin thiết bị đã kết nối ===================
  String _connectedDeviceName = '';
  String _lastConnectedDeviceName = '';
  String _lastConnectedDeviceAddress = '';
  int _batteryLevel = 0;

  // =================== Danh sách thiết bị Bluetooth và dữ liệu RFID ===================
  final List<Map<String, String>> _deviceList = [];
  final List<Map<String, dynamic>> _rfidTags = [];
  List<Map<String, dynamic>> _localData = [];

  // =================== Timer tự động dừng scan sau 10 giây ===================
  Timer? _scanTimer;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    await _requestPermissions();
    await _checkBluetoothStatus();
    await _checkExistingConnection();
    _setupServiceCallbacks();
    _service.initializeListeners();
    _service.startSyncWorker();
    _service.startAutoRefresh();
  }

  // =================== Xin quyền Bluetooth và Location từ người dùng ===================
  Future<void> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetooth,
      Permission.location,
      Permission.locationWhenInUse,
    ].request();

    bool allGranted = statuses.values.every(
      (status) => status.isGranted || status.isLimited,
    );

    if (!allGranted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng cấp đầy đủ quyền Bluetooth và Location'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  // =================== Kiểm tra kết nối Bluetooth cũ khi khởi động app ===================
  Future<void> _checkExistingConnection() async {
    try {
      final isConnected = await _service.checkExistingConnection();

      if (mounted) {
        setState(() {
          _isConnected = isConnected;
          _showRfidSection = isConnected;
          _isCheckingConnection = false;
        });

        if (isConnected) {
          await _loadLocal();

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

  // =================== Kiểm tra trạng thái bật/tắt của Bluetooth ===================
  Future<void> _checkBluetoothStatus() async {
    final isEnabled = await _service.checkBluetoothStatus();
    if (mounted) setState(() => _isBluetoothEnabled = isEnabled);
  }

  // =================== Yêu cầu bật Bluetooth nếu đang tắt ===================
  Future<void> _enableBluetooth() async {
    await _service.enableBluetooth();
    await _checkBluetoothStatus();
  }

  // =================== Thiết lập các callback từ service để cập nhật UI ===================
  void _setupServiceCallbacks() {
    _service.onDeviceFound = (device) {
      if (!mounted) return;
      setState(() {
        bool exists = _deviceList.any((d) => d['address'] == device['address']);
        if (!exists) _deviceList.add(device);
      });
    };

    _service.onConnectionStateChanged = (isConnected) {
      if (!mounted) return;
      setState(() {
        _isConnected = isConnected;
        if (!isConnected) {
          _connectedDeviceName = '';
          _rfidTags.clear();
          _batteryLevel = 0;
          _showRfidSection = true;
        }
      });
    };

    _service.onRfidTagScanned = (data) {
      final epc = (data['epc_ascii']?.toString().trim() ?? '');
      if (epc.isEmpty || !mounted) return;

      setState(() {
        int idx = _rfidTags.indexWhere((t) => t['epc_ascii'] == epc);
        if (idx >= 0) {
          _rfidTags[idx] = data;
        } else {
          _rfidTags.insert(0, data);
        }
      });
    };

    _service.onBatteryLevelChanged = (level) {
      if (!mounted) return;
      setState(() => _batteryLevel = level);
    };

    _service.onDataUpdated = () {
      _loadLocal();
    };
  }

  // =================== Bắt đầu quét thiết bị Bluetooth ===================
  Future<void> _startScanBluetooth() async {
    if (!_isBluetoothEnabled) {
      await _enableBluetooth();
      return;
    }

    setState(() {
      _isScanning = true;
      _deviceList.clear();
    });

    await _service.startScanBluetooth();

    _scanTimer?.cancel();
    _scanTimer = Timer(const Duration(seconds: 10), () {
      if (_isScanning) _stopScan();
    });
  }

  // =================== Dừng quét thiết bị Bluetooth ===================
  Future<void> _stopScan() async {
    await _service.stopScan();
    _scanTimer?.cancel();
    if (!mounted) return;
    setState(() => _isScanning = false);
  }

  // =================== Kết nối đến thiết bị Bluetooth đã chọn ===================
  Future<void> _connectToDevice(String name, String address) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      String result = await _service.connectToDevice(name, address);
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

  // =================== Ngắt kết nối thiết bị Bluetooth ===================
  Future<void> _disconnect() async {
    await _service.disconnect();
    if (!mounted) return;
    setState(() {
      _isConnected = false;
      _connectedDeviceName = '';
      _rfidTags.clear();
      _batteryLevel = 0;
    });
  }

  // =================== Tải dữ liệu đã quét từ database local ===================
  Future<void> _loadLocal() async {
    final data = await _service.loadLocalData();
    if (!mounted) return;
    setState(() => _localData = data);
  }

  // =================== Quét RFID một lần duy nhất ===================
  Future<void> _singleRead() async {
    if (!_isConnected) return;
    await _service.singleRead();
  }

  // =================== Bắt đầu quét RFID liên tục ===================
  Future<void> _startReading() async {
    if (!_isConnected) return;
    await _service.startReading();
    if (!mounted) return;
    setState(() => _isReading = true);
  }

  // =================== Dừng quét RFID liên tục ===================
  Future<void> _stopReading() async {
    if (!_isConnected) return;
    await _service.stopReading();
    if (!mounted) return;
    setState(() => _isReading = false);
  }

  // =================== Xóa toàn bộ lịch sử quét RFID ===================
  Future<void> _clearHistory() async {
    await _service.clearHistory();
    await _loadLocal();
    setState(() => _rfidTags.clear());

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã xóa lịch sử')),
      );
    }
  }

  // =================== Xây dựng giao diện chính ===================
  @override
  Widget build(BuildContext context) {
    // Hiển thị màn hình loading khi đang kiểm tra kết nối
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

  // =================== Widget hiển thị trạng thái kết nối ===================
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

  // =================== Widget nút hành động chính (Scan/Kết nối/Ngắt) ===================
  Widget _buildActionButton() {
    // Nếu đang hiển thị phần quét RFID
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

    return ElevatedButton.icon(
      onPressed: _isScanning ? _stopScan : _startScanBluetooth,
      icon: Icon(_isScanning ? Icons.stop : Icons.search),
      label: Text(_isScanning ? 'Dừng' : 'Scan'),
    );
  }

  // =================== Widget danh sách thiết bị Bluetooth ===================
  Widget _buildDeviceList() {
    // Bluetooth chưa được bật
    if (!_isBluetoothEnabled) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.bluetooth_disabled, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Bluetooth chưa được bật',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
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

  // =================== Widget phần quét RFID và hiển thị dữ liệu ===================
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

  // =================== Widget danh sách dữ liệu đã quét ===================
  Widget _buildScannedList() {
    if (_localData.isEmpty) {
      return const Center(child: Text('Chưa có dữ liệu'));
    }

    return ListView.builder(
      itemCount: _localData.length,
      itemBuilder: (_, i) => Container(
        height: 70,
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.black12)),
        ),
        child: ListTile(
          title: Text(
            _localData[i]['barcode'] ?? '---',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
  }

  // =================== Widget danh sách dữ liệu đã đồng bộ với màu trạng thái ===================
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

  // =================== Dọn dẹp tài nguyên khi dispose widget ===================
  @override
  void dispose() {
    _scanTimer?.cancel();
    _service.dispose();
    super.dispose();
  }
}
