import 'package:flutter/material.dart';
import 'package:paralled_data/services/rfid_scan_bluetooth_service.dart';

class RfidScanBluetoothPage extends StatefulWidget {
  const RfidScanBluetoothPage({super.key});

  @override
  State<RfidScanBluetoothPage> createState() => _RfidScanBluetoothPageState();
}

class _RfidScanBluetoothPageState extends State<RfidScanBluetoothPage> {
  final RfidScanBluetoothService _service = RfidScanBluetoothService();
  final bool _showRfidSection = false;

  @override
  void initState() {
    super.initState();
    _service.initializeListeners(() {
      if (mounted) setState(() {});
    });
    _service.requestPermissions().catchError((e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    });
    _service.checkBluetoothStatus().then((_) {
      if (mounted) setState(() {});
    });
    _service.startSyncWorker();
    _service.startAutoRefresh();
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
            child: _showRfidSection ? _buildRfidSection() : _buildDeviceList(),
          ),
        ],
      ),
    );
  }

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
    if (_showRfidSection) {
      return ElevatedButton.icon(
        onPressed: _service.isConnected
            ? _service.disconnect
            : (_service.lastConnectedDeviceAddress.isNotEmpty
                ? () => _service.connectToDevice(
                      _service.connectedDeviceName,
                      _service.lastConnectedDeviceAddress,
                      () => setState(() {}),
                      (err) => ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(err))),
                    )
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
              onPressed: () => _service.connectToDevice(
                  device['name'] ?? 'Unknown',
                  device['address'] ?? '',
                  () => setState(() {}),
                  (err) => ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(err)))),
              child: const Text('Kết nối'),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRfidSection() {
    final data = _service.localData;
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
                      height: 60,
                      color: Colors.blue.shade50,
                      padding: const EdgeInsets.all(8),
                      width: double.infinity,
                      child: Text(
                        'Dữ liệu đã quét (${data.length})',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, color: Colors.blue),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: data.length,
                        itemBuilder: (_, i) => Container(
                          height: 70,
                          decoration: const BoxDecoration(
                              border: Border(
                                  bottom: BorderSide(color: Colors.black12))),
                          child: ListTile(
                              title: Text(data[i]['barcode'] ?? '---',
                                  style: const TextStyle(fontSize: 13))),
                        ),
                      ),
                    ),
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
                        'Dữ liệu đồng bộ (${data.where((e) => e['status'] == 'synced').length}/${data.length})',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, color: Colors.green),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: data.length,
                        itemBuilder: (_, i) {
                          final item = data[i];
                          final status = item['status'] ?? 'pending';
                          final statusMap = {
                            'pending': 'Đang chờ',
                            'synced': 'Thành công',
                            'failed': 'Thất bại'
                          };

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
                                style:
                                    TextStyle(fontSize: 12, color: textColor),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
