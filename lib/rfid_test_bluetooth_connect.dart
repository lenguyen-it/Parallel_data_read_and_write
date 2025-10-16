// ignore_for_file: unused_field

import 'dart:async';
import 'dart:convert';

// ignore: unnecessary_import
import 'package:flutter/foundation.dart';
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

  // =================== BATCH CONFIG (giống rfid_scan_service) ===================
  static const int batchSize = 25;
  static const Duration batchInterval = Duration(milliseconds: 300);
  final List<Map<String, dynamic>> _pendingBatch = [];
  Timer? _batchTimer;
  bool _isFlushingBatch = false;

  // =================== CONCURRENT REQUEST ===================
  final Set<String> _sendingIds = {};
  final List<_QueuedRequest> _requestQueue = [];
  int _activeRequests = 0;
  static const int maxConcurrentRequests = 3;

  // =================== UI THROTTLING ===================
  Timer? _uiUpdateTimer;
  bool _hasPendingUIUpdate = false;

  final Map<String, int> _retryCounter = {};
  bool _isSyncing = false;

  static const String serverUrl = 'http://192.168.15.194:5000/api/scans';
  static const int maxRetryAttempts = 3;

  //==================================================================
  final List<DateTime> _scanTimestamps = [];

  // Lưu timestamp của các lần đồng bộ trong 1 giây
  final List<DateTime> _syncTimestamps = [];

  int get _scansInLastSecond {
    final now = DateTime.now();
    final oneSecondAgo = now.subtract(const Duration(seconds: 1));
    _scanTimestamps.removeWhere((t) => t.isBefore(oneSecondAgo));
    return _scanTimestamps.length;
  }

  int get _syncsInLastSecond {
    final now = DateTime.now();
    final oneSecondAgo = now.subtract(const Duration(seconds: 1));
    _syncTimestamps.removeWhere((t) => t.isBefore(oneSecondAgo));
    return _syncTimestamps.length;
  }

  //Đếm số
  int totalCount = 0;
  int uniqueCount = 0;
  final Set<String> uniqueEpcs = {};

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
          _showRfidSection = true;
        }
      });
    });

    _rfidSubscription = RfidBlePlugin.rfidStream.listen(
      (data) async {
        final epc = (data['epc_ascii']?.toString().trim() ?? '');
        if (epc.isEmpty || !mounted) return;

        final scanDurationMs = (data['scan_duration_ms'] is int)
            ? (data['scan_duration_ms'] as int).toDouble()
            : (data['scan_duration_ms'] as double?) ?? 0.0;

        totalCount++;
        if (uniqueEpcs.add(epc)) {
          uniqueCount++;
        }

        debugPrint('Tổng: $totalCount | Duy nhất: $uniqueCount');

        _scheduleUIUpdate(data);

        _addToBatch(data, scanDurationMs);
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

  // =================== UI UPDATE với THROTTLE (giống rfid_scan_service) ===================
  void _scheduleUIUpdate(Map<String, dynamic> data) {
    if (_hasPendingUIUpdate) return;

    _hasPendingUIUpdate = true;
    _uiUpdateTimer?.cancel();

    _uiUpdateTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;

      final epc = data['epc_ascii']?.toString().trim() ?? '';

      setState(() {
        int idx = _rfidTags.indexWhere((t) => t['epc_ascii'] == epc);
        if (idx >= 0) {
          _rfidTags[idx] = data;
        } else {
          _rfidTags.insert(0, data);
        }
      });

      _hasPendingUIUpdate = false;
    });
  }

  // =================== BATCH BUFFER (giống rfid_scan_service) ===================
  void _addToBatch(Map<String, dynamic> data, double scanDurationMs) {
    _pendingBatch.add({
      'barcode': data['epc_ascii'] ?? '',
      'scan_duration_ms': scanDurationMs,
      'epc_hex': data['epc_hex'],
      'tid_hex': data['tid_hex'],
      'user_hex': data['user_hex'],
      'rssi': data['rssi'],
      'count': data['count'],
    });

    if (_pendingBatch.length >= batchSize) {
      unawaited(_flushBatch());
      return;
    }

    _batchTimer?.cancel();
    _batchTimer = Timer(batchInterval, () => _flushBatch());
  }

  // =================== GOM BATCH & FLUSH (giống rfid_scan_service) ===================
  Future<void> _flushBatch({bool force = false}) async {
    if (!force && (_isFlushingBatch || _pendingBatch.isEmpty)) {
      return;
    }

    if (_pendingBatch.isEmpty) {
      debugPrint('⚠️ Không có batch để flush.');
      return;
    }

    _isFlushingBatch = true;

    try {
      final batch = List<Map<String, dynamic>>.from(_pendingBatch);
      _pendingBatch.clear();
      _batchTimer?.cancel();
      _batchTimer = null;

      final ids = await HistoryDatabase.instance.batchInsertScans(batch);
      if (ids.isEmpty) {
        debugPrint('⚠️ Không insert được batch.');
        return;
      }

      for (int i = 0; i < batch.length; i++) {
        unawaited(_sendToServer(batch[i], ids[i]));
      }

      // Load local data sau khi insert batch
      await _loadLocal();
    } catch (e, st) {
      debugPrint('❌ Lỗi khi flush batch: $e\n$st');
    } finally {
      _isFlushingBatch = false;
    }
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
      // ignore: use_build_context_synchronously
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

  // =================== GỬI SERVER SONG SONG (giống rfid_scan_service) ===================
  Future<void> _sendToServer(Map<String, dynamic> data, String idLocal) async {
    final epc = data['barcode'] ?? '';

    if (_sendingIds.contains(idLocal) ||
        _requestQueue.any((r) => r.idLocal == idLocal)) {
      return;
    }

    if (_activeRequests >= maxConcurrentRequests) {
      _requestQueue.add(_QueuedRequest(data, idLocal));
      return;
    }

    _sendingIds.add(idLocal);
    _activeRequests++;

    final DateTime startTime = DateTime.now();
    final Stopwatch stopwatch = Stopwatch()..start();

    final body = {
      'barcode': epc,
      'epc_hex': data['epc_hex'],
      'tid_hex': data['tid_hex'],
      'user_hex': data['user_hex'],
      'rssi': data['rssi'],
      'count': data['count'],
      'timestamp_device': startTime.toIso8601String(),
      'status_sync': true,
    };

    try {
      final response = await http
          .post(Uri.parse(serverUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 1));

      stopwatch.stop();
      final double syncDurationMs = stopwatch.elapsedMilliseconds.toDouble();

      if (response.statusCode == 200 || response.statusCode == 201) {
        await HistoryDatabase.instance.updateStatusById(
          idLocal,
          'synced',
          syncDurationMs: syncDurationMs,
        );
        _retryCounter.remove(idLocal);
      } else {
        await _handleRetryFail(
            idLocal, data, 'Server error ${response.statusCode}');
      }
    } catch (e) {
      stopwatch.stop();
      await _handleRetryFail(idLocal, data, e.toString());
    } finally {
      _sendingIds.remove(idLocal);
      _activeRequests--;

      if (_requestQueue.isNotEmpty) {
        final next = _requestQueue.removeAt(0);
        unawaited(_sendToServer(next.data, next.idLocal));
      }
    }
  }

  Future<void> _handleRetryFail(
      String idLocal, Map<String, dynamic> data, String error) async {
    _retryCounter[idLocal] = (_retryCounter[idLocal] ?? 0) + 1;
    final retryCount = _retryCounter[idLocal]!;

    if (retryCount >= maxRetryAttempts) {
      await HistoryDatabase.instance.updateStatusById(idLocal, 'failed');
      _retryCounter.remove(idLocal);
      debugPrint(
          '❌ Mã ${data['barcode']} đã failed sau $maxRetryAttempts lần thử');
    } else {
      await Future.delayed(const Duration(milliseconds: 500));
      unawaited(_sendToServer(data, idLocal));
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
          final idLocal = scan['id_local'] as String;

          final currentRetry = _retryCounter[idLocal] ?? 0;

          if (currentRetry >= maxRetryAttempts) {
            await HistoryDatabase.instance.updateStatusById(idLocal, 'failed');
            _retryCounter.remove(idLocal);
            debugPrint('❌ Sync worker: Mã ${scan['barcode']} đã failed');
            continue;
          }

          // Tạo data map từ scan
          final data = {
            'barcode': scan['barcode'],
            'epc_hex': scan['epc_hex'],
            'tid_hex': scan['tid_hex'],
            'user_hex': scan['user_hex'],
            'rssi': scan['rssi'],
            'count': scan['count'],
          };

          await _sendToServer(data, idLocal);
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

  Widget _buildActionButton() {
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
                            '(${_localData.length})',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.blueGrey,
                            ),
                          ),
                          Text(
                            'Tốc độ: $_scansInLastSecond mã/giây',
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
                            '(${_localData.where((e) => e['status'] == 'synced').length}/${_localData.length})',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.green,
                            ),
                          ),
                          Text(
                            'Tốc độ: $_syncsInLastSecond mã/giây',
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
    if (_localData.isEmpty) return const Center(child: Text('Chưa có dữ liệu'));
    return ListView.builder(
      itemCount: _localData.length,
      itemBuilder: (_, i) {
        final item = _localData[i];
        final scanDuration = item['scan_duration_ms'];
        return Container(
          height: 80,
          decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.black12))),
          child: ListTile(
            title: Text(
              _localData[i]['barcode'] ?? '---',
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
              item['barcode'] ?? '---',
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

    _batchTimer?.cancel();
    _batchTimer = null;
    _uiUpdateTimer?.cancel();
    _uiUpdateTimer = null;

    await _flushBatch(force: true);

    await RfidBlePlugin.stopInventory();
    if (!mounted) return;
    setState(() => _isReading = false);
  }

  Future<void> _clearHistory() async {
    await HistoryDatabase.instance.clearHistory();
    await _loadLocal();
    _rfidTags.clear();
    _retryCounter.clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã xóa lịch sử')),
      );
    }
  }
}

class _QueuedRequest {
  final Map<String, dynamic> data;
  final String idLocal;
  _QueuedRequest(this.data, this.idLocal);
}
