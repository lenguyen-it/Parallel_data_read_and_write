// import 'package:flutter/material.dart';
// import 'package:paralled_data/services/rfid_scan_bluetooth_service.dart';

// class RfidScanBluetoothPage extends StatefulWidget {
//   const RfidScanBluetoothPage({super.key});

//   @override
//   State<RfidScanBluetoothPage> createState() => _RfidScanBluetoothPageState();
// }

// class _RfidScanBluetoothPageState extends State<RfidScanBluetoothPage> {
//   late RfidScanBluetoothService _service;

//   @override
//   void initState() {
//     super.initState();
//     _service = RfidScanBluetoothService();
//     _service.init();
//     _service.addListener(_updateUI);
//     _service.messages.listen(_showMessage);
//   }

//   void _updateUI() {
//     if (mounted) setState(() {});
//   }

//   void _showMessage(String message) {
//     Color? color;
//     Duration duration = const Duration(seconds: 2);

//     if (message.startsWith('success:')) {
//       message = message.substring(8);
//       color = Colors.green;
//     } else if (message.startsWith('error:')) {
//       message = message.substring(6);
//       color = Colors.red;
//       duration = const Duration(seconds: 3);
//     } else {
//       duration = const Duration(seconds: 3);
//     }

//     ScaffoldMessenger.of(context).showSnackBar(
//       SnackBar(
//         content: Text(message),
//         backgroundColor: color,
//         duration: duration,
//       ),
//     );
//   }

//   Future<void> _connectToDevice(String name, String address) async {
//     showDialog(
//       context: context,
//       barrierDismissible: false,
//       builder: (_) => const Center(child: CircularProgressIndicator()),
//     );

//     await _service.connectToDevice(name, address);

//     if (mounted) Navigator.pop(context);
//   }

//   @override
//   void dispose() {
//     _service.removeListener(_updateUI);
//     _service.dispose();
//     super.dispose();
//   }

//   @override
//   Widget build(BuildContext context) {
//     if (_service.isCheckingConnection) {
//       return Scaffold(
//         appBar: AppBar(
//           title: const Text('RFID Bluetooth - Đồng bộ'),
//         ),
//         body: const Center(
//           child: Column(
//             mainAxisAlignment: MainAxisAlignment.center,
//             children: [
//               CircularProgressIndicator(),
//               SizedBox(height: 16),
//               Text('Đang kiểm tra kết nối...'),
//             ],
//           ),
//         ),
//       );
//     }

//     return Scaffold(
//       appBar: AppBar(
//         title: const Text('RFID Bluetooth - Đồng bộ'),
//         actions: [
//           Padding(
//             padding: const EdgeInsets.symmetric(horizontal: 8),
//             child: Row(
//               children: [
//                 Icon(
//                   _service.isBluetoothEnabled
//                       ? Icons.bluetooth
//                       : Icons.bluetooth_disabled,
//                   size: 20,
//                   color: _service.isBluetoothEnabled ? Colors.blue : Colors.red,
//                 ),
//                 if (!_service.isBluetoothEnabled)
//                   TextButton(
//                     onPressed: _service.enableBluetooth,
//                     child: const Text('Bật', style: TextStyle(fontSize: 12)),
//                   ),
//                 if (_service.isConnected)
//                   Row(
//                     children: [
//                       const SizedBox(width: 8),
//                       const Icon(Icons.battery_charging_full, size: 20),
//                       const SizedBox(width: 4),
//                       Text('${_service.batteryLevel}%'),
//                     ],
//                   ),
//               ],
//             ),
//           ),
//         ],
//       ),
//       body: Column(
//         children: [
//           _buildConnectionStatus(),
//           Expanded(
//             child: _service.showRfidSection
//                 ? _buildRfidSection()
//                 : _buildDeviceList(),
//           ),
//         ],
//       ),
//     );
//   }

//   // =================== Connection Status ===================
//   Widget _buildConnectionStatus() {
//     return Container(
//       padding: const EdgeInsets.all(16),
//       color:
//           _service.isConnected ? Colors.green.shade100 : Colors.grey.shade200,
//       child: Row(
//         children: [
//           Icon(
//             _service.isConnected
//                 ? Icons.bluetooth_connected
//                 : Icons.bluetooth_disabled,
//             color: _service.isConnected ? Colors.green : Colors.grey,
//           ),
//           const SizedBox(width: 12),
//           Expanded(
//             child: Column(
//               crossAxisAlignment: CrossAxisAlignment.start,
//               children: [
//                 Text(
//                   _service.isConnected ? 'Đã kết nối' : 'Chưa kết nối',
//                   style: const TextStyle(
//                     fontWeight: FontWeight.bold,
//                     fontSize: 16,
//                   ),
//                 ),
//                 if (_service.isConnected)
//                   Text(
//                     _service.connectedDeviceName,
//                     style: TextStyle(color: Colors.grey.shade700, fontSize: 14),
//                   )
//                 else if (_service.lastConnectedDeviceName.isNotEmpty)
//                   Text(
//                     _service.lastConnectedDeviceName,
//                     style: TextStyle(color: Colors.grey.shade700, fontSize: 14),
//                   ),
//               ],
//             ),
//           ),
//           _buildActionButton(),
//         ],
//       ),
//     );
//   }

//   Widget _buildActionButton() {
//     if (_service.showRfidSection) {
//       return ElevatedButton.icon(
//         onPressed: _service.isConnected
//             ? _service.disconnect
//             : (_service.lastConnectedDeviceAddress.isNotEmpty
//                 ? () => _connectToDevice(_service.lastConnectedDeviceName,
//                     _service.lastConnectedDeviceAddress)
//                 : null),
//         icon: Icon(_service.isConnected ? Icons.close : Icons.bluetooth),
//         label: Text(_service.isConnected ? 'Ngắt' : 'Kết nối lại'),
//         style: ElevatedButton.styleFrom(
//           backgroundColor: _service.isConnected ? Colors.red : null,
//         ),
//       );
//     }
//     return ElevatedButton.icon(
//       onPressed:
//           _service.isScanning ? _service.stopScan : _service.startScanBluetooth,
//       icon: Icon(_service.isScanning ? Icons.stop : Icons.search),
//       label: Text(_service.isScanning ? 'Dừng' : 'Scan'),
//     );
//   }

//   // =================== Device List ===================
//   Widget _buildDeviceList() {
//     if (!_service.isBluetoothEnabled) {
//       return Center(
//         child: Column(
//           mainAxisAlignment: MainAxisAlignment.center,
//           children: [
//             const Icon(Icons.bluetooth_disabled, size: 64, color: Colors.grey),
//             const SizedBox(height: 16),
//             const Text('Bluetooth chưa được bật',
//                 style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
//             const SizedBox(height: 24),
//             ElevatedButton.icon(
//               onPressed: _service.enableBluetooth,
//               icon: const Icon(Icons.bluetooth),
//               label: const Text('Bật Bluetooth'),
//             ),
//           ],
//         ),
//       );
//     }

//     if (_service.deviceList.isEmpty && !_service.isScanning) {
//       return const Center(child: Text('Nhấn "Scan" để tìm thiết bị Bluetooth'));
//     }

//     if (_service.isScanning && _service.deviceList.isEmpty) {
//       return const Center(
//         child: Column(
//           mainAxisAlignment: MainAxisAlignment.center,
//           children: [
//             CircularProgressIndicator(),
//             SizedBox(height: 16),
//             Text('Đang tìm kiếm thiết bị...'),
//           ],
//         ),
//       );
//     }

//     return ListView.builder(
//       itemCount: _service.deviceList.length,
//       itemBuilder: (context, i) {
//         final device = _service.deviceList[i];
//         return Card(
//           margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
//           child: ListTile(
//             leading: const Icon(Icons.bluetooth, color: Colors.blue),
//             title: Text(device['name'] ?? 'Unknown'),
//             subtitle: Text(device['address'] ?? ''),
//             trailing: ElevatedButton(
//               onPressed: () => _connectToDevice(
//                   device['name'] ?? 'Unknown', device['address'] ?? ''),
//               child: const Text('Kết nối'),
//             ),
//           ),
//         );
//       },
//     );
//   }

//   // =================== RFID Section ===================
//   Widget _buildRfidSection() {
//     return Column(
//       children: [
//         Padding(
//           padding: const EdgeInsets.all(16),
//           child: Wrap(
//             spacing: 8,
//             runSpacing: 8,
//             alignment: WrapAlignment.center,
//             children: [
//               ElevatedButton.icon(
//                 onPressed: (!_service.isConnected)
//                     ? null
//                     : (_service.isReading
//                         ? _service.stopReading
//                         : _service.startReading),
//                 icon: Icon(_service.isReading ? Icons.stop : Icons.play_arrow),
//                 label: Text(_service.isReading ? 'Dừng quét' : 'Quét liên tục'),
//                 style: ElevatedButton.styleFrom(
//                   backgroundColor:
//                       _service.isReading ? Colors.red : Colors.green,
//                 ),
//               ),
//               ElevatedButton.icon(
//                 onPressed: (!_service.isConnected || _service.isReading)
//                     ? null
//                     : _service.singleRead,
//                 icon: const Icon(Icons.radar),
//                 label: const Text('Quét 1 lần'),
//               ),
//               ElevatedButton.icon(
//                 onPressed: _service.clearHistory,
//                 icon: const Icon(Icons.delete_forever),
//                 label: const Text('Xóa lịch sử'),
//                 style: ElevatedButton.styleFrom(
//                   backgroundColor: Colors.orange,
//                 ),
//               ),
//               ElevatedButton.icon(
//                 onPressed: _service.loadLocal,
//                 icon: const Icon(Icons.refresh),
//                 label: const Text('Tải lại'),
//               ),
//             ],
//           ),
//         ),
//         const Divider(height: 1),
//         Expanded(
//           child: Row(
//             children: [
//               Expanded(
//                 child: Column(
//                   children: [
//                     Container(
//                       height: 90,
//                       color: Colors.blue.shade50,
//                       padding: const EdgeInsets.all(8),
//                       width: double.infinity,
//                       child: Column(
//                         crossAxisAlignment: CrossAxisAlignment.start,
//                         mainAxisAlignment: MainAxisAlignment.center,
//                         children: [
//                           const Text(
//                             'Dữ liệu đã quét',
//                             style: TextStyle(
//                               fontWeight: FontWeight.bold,
//                               color: Colors.blue,
//                             ),
//                           ),
//                           Text(
//                             '(${_service.localData.length})',
//                             style: const TextStyle(
//                               fontSize: 13,
//                               color: Colors.blueGrey,
//                             ),
//                           ),
//                           Text(
//                             'Tốc độ: ${_service.scansInLastSecond} mã/giây',
//                             style: const TextStyle(
//                               fontSize: 12,
//                               fontWeight: FontWeight.bold,
//                               color: Colors.blue,
//                             ),
//                           ),
//                         ],
//                       ),
//                     ),
//                     Expanded(child: _buildScannedList()),
//                   ],
//                 ),
//               ),
//               const VerticalDivider(width: 1),
//               Expanded(
//                 child: Column(
//                   children: [
//                     Container(
//                       height: 90,
//                       color: Colors.green.shade50,
//                       padding: const EdgeInsets.all(8),
//                       width: double.infinity,
//                       child: Column(
//                         crossAxisAlignment: CrossAxisAlignment.start,
//                         mainAxisAlignment: MainAxisAlignment.center,
//                         children: [
//                           const Text(
//                             'Dữ liệu đồng bộ',
//                             style: TextStyle(
//                               fontWeight: FontWeight.bold,
//                               color: Colors.green,
//                             ),
//                           ),
//                           Text(
//                             '(${_service.localData.where((e) => e['status'] == 'synced').length}/${_service.localData.length})',
//                             style: const TextStyle(
//                               fontSize: 13,
//                               color: Colors.green,
//                             ),
//                           ),
//                           Text(
//                             'Tốc độ: ${_service.syncsInLastSecond} mã/giây',
//                             style: const TextStyle(
//                               fontSize: 12,
//                               fontWeight: FontWeight.bold,
//                               color: Colors.green,
//                             ),
//                           ),
//                         ],
//                       ),
//                     ),
//                     Expanded(child: _buildSyncedList()),
//                   ],
//                 ),
//               ),
//             ],
//           ),
//         ),
//       ],
//     );
//   }

//   Widget _buildScannedList() {
//     if (_service.localData.isEmpty) {
//       return const Center(child: Text('Chưa có dữ liệu'));
//     }
//     return ListView.builder(
//       itemCount: _service.localData.length,
//       itemBuilder: (_, i) {
//         final item = _service.localData[i];
//         final scanDuration = item['scan_duration_ms'];
//         return Container(
//           height: 80,
//           decoration: const BoxDecoration(
//               border: Border(bottom: BorderSide(color: Colors.black12))),
//           child: ListTile(
//             title: Text(
//               _service.localData[i]['epc'] ?? '---',
//               style: const TextStyle(fontSize: 13),
//             ),
//             subtitle: Column(
//               crossAxisAlignment: CrossAxisAlignment.start,
//               children: [
//                 Text(
//                   'Trạng thái: ${item['status'] ?? '---'}',
//                   style: const TextStyle(fontSize: 12, color: Colors.grey),
//                 ),
//                 if (scanDuration != null)
//                   Text(
//                     'Tốc độ quét: ${scanDuration.toStringAsFixed(2)}ms/mã',
//                     style: const TextStyle(fontSize: 11, color: Colors.blue),
//                   ),
//               ],
//             ),
//           ),
//         );
//       },
//     );
//   }

//   Widget _buildSyncedList() {
//     if (_service.localData.isEmpty) {
//       return const Center(child: Text('Không có dữ liệu đồng bộ'));
//     }

//     final statusMap = {
//       'pending': 'Đang chờ',
//       'synced': 'Thành công',
//       'failed': 'Thất bại'
//     };

//     return ListView.builder(
//       itemCount: _service.localData.length,
//       itemBuilder: (_, i) {
//         final item = _service.localData[i];
//         final status = item['status'] ?? 'pending';
//         final statusText = statusMap[status] ?? status;
//         final syncDuration = item['sync_duration_ms'];

//         Color backgroundColor;
//         // ignore: unused_local_variable
//         Color textColor;

//         switch (status) {
//           case 'synced':
//             backgroundColor = const Color(0xFFE8F5E9);
//             textColor = Colors.green;
//             break;
//           case 'failed':
//             backgroundColor = const Color(0xFFFFEBEE);
//             textColor = Colors.red;
//             break;
//           default:
//             backgroundColor = const Color(0xFFFFF8E1);
//             textColor = Colors.orange;
//         }

//         return Container(
//           height: 80,
//           color: backgroundColor,
//           child: ListTile(
//             title: Text(
//               item['epc'] ?? '---',
//               style: const TextStyle(fontSize: 13),
//             ),
//             subtitle: Column(
//               crossAxisAlignment: CrossAxisAlignment.start,
//               children: [
//                 Text(
//                   'Trạng thái: $statusText',
//                   style: TextStyle(
//                     fontSize: 13,
//                     color: status == 'synced'
//                         ? Colors.green
//                         : (status == 'failed' ? Colors.red : Colors.orange),
//                   ),
//                 ),
//                 if (syncDuration != null && status == 'synced')
//                   Text(
//                     'Tốc độ đồng bộ: ${syncDuration.toStringAsFixed(2)}ms/mã',
//                     style: const TextStyle(fontSize: 11, color: Colors.green),
//                   ),
//               ],
//             ),
//           ),
//         );
//       },
//     );
//   }
// }

// ignore_for_file: unused_field
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:paralled_data/services/temp_storage_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:paralled_data/services/rfid_scan_bluetooth_service.dart';

class RfidScanBluetoothPage extends StatefulWidget {
  const RfidScanBluetoothPage({super.key});

  @override
  State<RfidScanBluetoothPage> createState() => _RfidScanBluetoothPageState();
}

class _RfidScanBluetoothPageState extends State<RfidScanBluetoothPage> {
  late final RfidScanBluetoothService _service;

  bool _showRfidSection = false;
  bool _isCheckingConnection = true;

  // UI THROTTLING
  Timer? _uiUpdateTimer;
  bool _hasPendingUIUpdate = false;

  @override
  void initState() {
    super.initState();
    _service = RfidScanBluetoothService();
    _service.onStateChanged = _onServiceStateChanged;
    _service.onRfidDataReceived = _scheduleUIUpdate;
    _initService();
  }

  Future<void> _initService() async {
    await _service.initEncryption();
    await _requestPermissions();
    await _service.checkBluetoothStatus();
    final connected = await _service.checkExistingConnection();

    if (mounted) {
      setState(() {
        _showRfidSection = connected;
        _isCheckingConnection = false;
      });

      if (connected) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Đã khôi phục kết nối thiết bị'),
            duration: Duration(seconds: 2),
            backgroundColor: Colors.green,
          ),
        );
      }
    }

    _service.initializeListeners();
    _service.startSyncWorker();
    _service.startAutoRefresh();
  }

  void _onServiceStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _uiUpdateTimer?.cancel();
    _service.dispose();
    super.dispose();
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

  // =================== UI UPDATE với THROTTLE ===================
  void _scheduleUIUpdate(Map<String, dynamic> data) {
    if (_hasPendingUIUpdate) return;

    _hasPendingUIUpdate = true;
    _uiUpdateTimer?.cancel();

    _uiUpdateTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;

      final epc = data['epc_ascii']?.toString().trim() ?? '';

      setState(() {
        int idx = _service.rfidTags.indexWhere((t) => t['epc_ascii'] == epc);
        if (idx >= 0) {
          _service.rfidTags[idx] = data;
        } else {
          _service.rfidTags.insert(0, data);
        }
      });

      _hasPendingUIUpdate = false;
    });
  }

  // =================== Scan / Connect ===================
  Future<void> _startScanBluetooth() async {
    await _service.startScanBluetooth();
  }

  Future<void> _stopScan() async {
    await _service.stopScan();
  }

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
          _showRfidSection = true;
        });
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Lỗi kết nối: $e')));
    }
  }

  Future<void> _disconnect() async {
    await _service.disconnect();
  }

  // =================== Xem file tạm ===================
  Future<void> _showTempFileDialog() async {
    try {
      final tempData = List<Map<String, dynamic>>.from(
        await TempStorageService().readAllTempData(),
      ).reversed.toList();

      final count = tempData.length;
      final filePath = await TempStorageService().getTempFilePath();

      if (!mounted) return;

      showDialog(
        context: context,
        builder: (context) => Dialog(
          child: Container(
            width: MediaQuery.of(context).size.width * 0.9,
            height: MediaQuery.of(context).size.height * 0.8,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Dữ liệu File Tạm',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Row(
                          children: [
                            Icon(
                              _service.encryptionInitialized
                                  ? Icons.lock
                                  : Icons.lock_open,
                              size: 14,
                              color: _service.encryptionInitialized
                                  ? Colors.green
                                  : Colors.orange,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _service.encryptionInitialized
                                  ? 'Đã mã hóa'
                                  : 'Chưa mã hóa',
                              style: TextStyle(
                                fontSize: 11,
                                color: _service.encryptionInitialized
                                    ? Colors.green
                                    : Colors.orange,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Tổng số: $count records',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Đường dẫn: $filePath',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const Divider(height: 20),
                Expanded(
                  child: tempData.isEmpty
                      ? const Center(child: Text('File tạm trống'))
                      : ListView.builder(
                          itemCount: tempData.length,
                          itemBuilder: (context, index) {
                            final item = tempData[index];
                            final jsonStr = const JsonEncoder.withIndent('  ')
                                .convert(item);

                            return Card(
                              margin: const EdgeInsets.only(bottom: 12),
                              child: ExpansionTile(
                                title: Text(
                                  '${index + 1}. ${item['epc'] ?? 'N/A'}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text(
                                  'Status: ${item['sync_status'] ?? 'N/A'}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                children: [
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(12),
                                    color: Colors.grey.shade100,
                                    child: SelectableText(
                                      jsonStr,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () => _showDownloadOptionsDialog(),
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Tải về'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => _showImportOptionsDialog(),
                      icon: const Icon(Icons.upload, size: 18),
                      label: const Text('Import'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Xác nhận'),
                            content: const Text(
                                'Bạn có chắc muốn xóa toàn bộ dữ liệu file tạm?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Hủy'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Xóa'),
                              ),
                            ],
                          ),
                        );

                        if (confirm == true) {
                          await TempStorageService().clearTempFile();
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Đã xóa dữ liệu file tạm')),
                          );
                        }
                      },
                      icon: const Icon(Icons.delete, size: 18),
                      label: const Text('Xóa file tạm'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi: $e')),
      );
    }
  }

  Future<void> _showDownloadOptionsDialog() async {
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Chọn định dạng tải về'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.lock, color: Colors.green),
                title: const Text('File mã hóa (.encrypted)'),
                subtitle: const Text('Bảo mật, cần key để đọc'),
                onTap: () async {
                  Navigator.pop(context);
                  await _downloadEncrypted();
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.description, color: Colors.blue),
                title: const Text('File JSON (đã giải mã)'),
                subtitle: const Text('Dễ đọc, không bảo mật'),
                onTap: () async {
                  Navigator.pop(context);
                  await _downloadJson();
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.table_chart, color: Colors.orange),
                title: const Text('File CSV (đã giải mã)'),
                subtitle: const Text('Excel, không bảo mật'),
                onTap: () async {
                  Navigator.pop(context);
                  await _downloadCsv();
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _downloadEncrypted() async {
    try {
      final path = await TempStorageService().downloadEncryptedFile();
      if (!mounted) return;

      if (path != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Đã lưu file mã hóa: $path'),
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ Lỗi khi lưu file')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Lỗi: $e')),
      );
    }
  }

  Future<void> _downloadJson() async {
    try {
      final path = await TempStorageService().downloadDecryptedJson();
      if (!mounted) return;

      if (path != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Đã lưu file JSON: $path'),
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ Lỗi khi lưu file')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Lỗi: $e')),
      );
    }
  }

  Future<void> _downloadCsv() async {
    try {
      final path = await TempStorageService().downloadDecryptedCSV();
      if (!mounted) return;

      if (path != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Đã lưu file CSV: $path'),
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ Lỗi khi lưu file')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Lỗi: $e')),
      );
    }
  }

  Future<void> _showImportOptionsDialog() async {
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Import file'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.lock, color: Colors.green),
                title: const Text('Import file mã hóa'),
                subtitle: const Text('.encrypted'),
                onTap: () async {
                  Navigator.pop(context);
                  await _importEncrypted();
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.description, color: Colors.blue),
                title: const Text('Import file thường'),
                subtitle: const Text('JSON, CSV'),
                onTap: () async {
                  Navigator.pop(context);
                  await _importPlain();
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _importEncrypted() async {
    if (_service.isLoading) return;
    setState(() => _service.isLoading = true);

    try {
      final result = await TempStorageService().importEncryptedFile();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message']),
          backgroundColor: result['success'] ? Colors.green : Colors.red,
        ),
      );

      if (result['success']) {
        await _service.syncRecordsFromTemp();
        await _service.loadLocal();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Lỗi import: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _service.isLoading = false);
    }
  }

  Future<void> _importPlain() async {
    if (_service.isLoading) return;
    setState(() => _service.isLoading = true);

    try {
      final result = await TempStorageService().importPlainFile();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message']),
          backgroundColor: result['success'] ? Colors.green : Colors.red,
        ),
      );

      if (result['success']) {
        await _service.syncRecordsFromTemp();
        await _service.loadLocal();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Lỗi import: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _service.isLoading = false);
    }
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
    if (_showRfidSection) {
      return ElevatedButton.icon(
        onPressed: _service.isConnected
            ? _disconnect
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
      onPressed: _service.isScanning ? _stopScan : _startScanBluetooth,
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
                onPressed: () async {
                  await _service.clearHistory();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Đã xóa lịch sử')),
                    );
                  }
                },
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
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.limeAccent,
                ),
                onPressed: _showTempFileDialog,
                child: const Text('Xem file tạm'),
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
    if (_service.localData.isEmpty)
      return const Center(child: Text('Chưa có dữ liệu'));
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

        switch (status) {
          case 'synced':
            backgroundColor = const Color(0xFFE8F5E9);
            break;
          case 'failed':
            backgroundColor = const Color(0xFFFFEBEE);
            break;
          default:
            backgroundColor = const Color(0xFFFFF8E1);
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
        title: Row(
          children: [
            Expanded(
              child: Text(
                'RFID Bluetooth - Đồng bộ',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              _service.encryptionInitialized ? Icons.lock : Icons.lock_open,
              size: 18,
              color:
                  _service.encryptionInitialized ? Colors.white : Colors.orange,
            ),
          ],
        ),
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
}
