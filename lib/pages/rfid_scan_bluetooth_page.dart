import 'package:flutter/material.dart';
import 'package:paralled_data/services/rfid_scan_bluetooth_service.dart';

class RfidScanBluetoothPage extends StatefulWidget {
  const RfidScanBluetoothPage({super.key});

  @override
  State<RfidScanBluetoothPage> createState() => _RfidScanBluetoothPageState();
}

class _RfidScanBluetoothPageState extends State<RfidScanBluetoothPage> {
  late RfidScanBluetoothService _service;

  @override
  void initState() {
    super.initState();
    _service = RfidScanBluetoothService();
    _service.init();
    _service.addListener(_updateUI);
    _service.messages.listen(_showMessage);
  }

  void _updateUI() {
    if (mounted) setState(() {});
  }

  void _showMessage(String message) {
    Color? color;
    Duration duration = const Duration(seconds: 2);

    if (message.startsWith('success:')) {
      message = message.substring(8);
      color = Colors.green;
    } else if (message.startsWith('error:')) {
      message = message.substring(6);
      color = Colors.red;
      duration = const Duration(seconds: 3);
    } else {
      duration = const Duration(seconds: 3);
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        duration: duration,
      ),
    );
  }

  Future<void> _connectToDevice(String name, String address) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    await _service.connectToDevice(name, address);

    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _service.removeListener(_updateUI);
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_service.isCheckingConnection) {
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
                  _service.isBluetoothEnabled
                      ? Icons.bluetooth
                      : Icons.bluetooth_disabled,
                  size: 20,
                  color: _service.isBluetoothEnabled ? Colors.blue : Colors.red,
                ),
                if (!_service.isBluetoothEnabled)
                  TextButton(
                    onPressed: _service.enableBluetooth,
                    child: const Text('Bật', style: TextStyle(fontSize: 12)),
                  ),
                if (_service.isConnected)
                  Row(
                    children: [
                      const SizedBox(width: 8),
                      const Icon(Icons.battery_charging_full, size: 20),
                      const SizedBox(width: 4),
                      Text('${_service.batteryLevel}%'),
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
            child: _service.showRfidSection
                ? _buildRfidSection()
                : _buildDeviceList(),
          ),
        ],
      ),
    );
  }

  // =================== Connection Status ===================
  Widget _buildConnectionStatus() {
    return Container(
      padding: const EdgeInsets.all(16),
      color:
          _service.isConnected ? Colors.green.shade100 : Colors.grey.shade200,
      child: Row(
        children: [
          Icon(
            _service.isConnected
                ? Icons.bluetooth_connected
                : Icons.bluetooth_disabled,
            color: _service.isConnected ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _service.isConnected ? 'Đã kết nối' : 'Chưa kết nối',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                if (_service.isConnected)
                  Text(
                    _service.connectedDeviceName,
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 14),
                  )
                else if (_service.lastConnectedDeviceName.isNotEmpty)
                  Text(
                    _service.lastConnectedDeviceName,
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

  Widget _buildActionButton() {
    if (_service.showRfidSection) {
      return ElevatedButton.icon(
        onPressed: _service.isConnected
            ? _service.disconnect
            : (_service.lastConnectedDeviceAddress.isNotEmpty
                ? () => _connectToDevice(_service.lastConnectedDeviceName,
                    _service.lastConnectedDeviceAddress)
                : null),
        icon: Icon(_service.isConnected ? Icons.close : Icons.bluetooth),
        label: Text(_service.isConnected ? 'Ngắt' : 'Kết nối lại'),
        style: ElevatedButton.styleFrom(
          backgroundColor: _service.isConnected ? Colors.red : null,
        ),
      );
    }
    return ElevatedButton.icon(
      onPressed:
          _service.isScanning ? _service.stopScan : _service.startScanBluetooth,
      icon: Icon(_service.isScanning ? Icons.stop : Icons.search),
      label: Text(_service.isScanning ? 'Dừng' : 'Scan'),
    );
  }

  // =================== Device List ===================
  Widget _buildDeviceList() {
    if (!_service.isBluetoothEnabled) {
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
              onPressed: _service.enableBluetooth,
              icon: const Icon(Icons.bluetooth),
              label: const Text('Bật Bluetooth'),
            ),
          ],
        ),
      );
    }

    if (_service.deviceList.isEmpty && !_service.isScanning) {
      return const Center(child: Text('Nhấn "Scan" để tìm thiết bị Bluetooth'));
    }

    if (_service.isScanning && _service.deviceList.isEmpty) {
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
      itemCount: _service.deviceList.length,
      itemBuilder: (context, i) {
        final device = _service.deviceList[i];
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
                onPressed: (!_service.isConnected)
                    ? null
                    : (_service.isReading
                        ? _service.stopReading
                        : _service.startReading),
                icon: Icon(_service.isReading ? Icons.stop : Icons.play_arrow),
                label: Text(_service.isReading ? 'Dừng quét' : 'Quét liên tục'),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _service.isReading ? Colors.red : Colors.green,
                ),
              ),
              ElevatedButton.icon(
                onPressed: (!_service.isConnected || _service.isReading)
                    ? null
                    : _service.singleRead,
                icon: const Icon(Icons.radar),
                label: const Text('Quét 1 lần'),
              ),
              ElevatedButton.icon(
                onPressed: _service.clearHistory,
                icon: const Icon(Icons.delete_forever),
                label: const Text('Xóa lịch sử'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                ),
              ),
              ElevatedButton.icon(
                onPressed: _service.loadLocal,
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
                      height: 90,
                      color: Colors.blue.shade50,
                      padding: const EdgeInsets.all(8),
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
                            '(${_service.localData.length})',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.blueGrey,
                            ),
                          ),
                          Text(
                            'Tốc độ: ${_service.scansInLastSecond} mã/giây',
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
                      height: 90,
                      color: Colors.green.shade50,
                      padding: const EdgeInsets.all(8),
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
                            '(${_service.localData.where((e) => e['status'] == 'synced').length}/${_service.localData.length})',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.green,
                            ),
                          ),
                          Text(
                            'Tốc độ: ${_service.syncsInLastSecond} mã/giây',
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
        ),
      ],
    );
  }

  Widget _buildScannedList() {
    if (_service.localData.isEmpty) {
      return const Center(child: Text('Chưa có dữ liệu'));
    }
    return ListView.builder(
      itemCount: _service.localData.length,
      itemBuilder: (_, i) {
        final item = _service.localData[i];
        final scanDuration = item['scan_duration_ms'];
        return Container(
          height: 80,
          decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.black12))),
          child: ListTile(
            title: Text(
              _service.localData[i]['epc'] ?? '---',
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Trạng thái: ${item['status'] ?? '---'}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
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
    if (_service.localData.isEmpty) {
      return const Center(child: Text('Không có dữ liệu đồng bộ'));
    }

    final statusMap = {
      'pending': 'Đang chờ',
      'synced': 'Thành công',
      'failed': 'Thất bại'
    };

    return ListView.builder(
      itemCount: _service.localData.length,
      itemBuilder: (_, i) {
        final item = _service.localData[i];
        final status = item['status'] ?? 'pending';
        final statusText = statusMap[status] ?? status;
        final syncDuration = item['sync_duration_ms'];

        Color backgroundColor;
        // ignore: unused_local_variable
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
          height: 80,
          color: backgroundColor,
          child: ListTile(
            title: Text(
              item['epc'] ?? '---',
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
}
