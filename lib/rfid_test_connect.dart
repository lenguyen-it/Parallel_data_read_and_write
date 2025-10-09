import 'package:flutter/material.dart';
import 'plugin/rfid_c72_plugin.dart';
import 'package:flutter_barcode_scanner_plus/flutter_barcode_scanner_plus.dart';

class RfidTestConnect extends StatefulWidget {
  const RfidTestConnect({super.key});

  @override
  State<RfidTestConnect> createState() => _RfidTestConnectState();
}

class _RfidTestConnectState extends State<RfidTestConnect> {
  String _rfidTag = "Chưa có dữ liệu";
  String _barcode = "Chưa có dữ liệu";
  bool _isConnected = false;

  bool _isBarcodeScanning = false;
  bool _isRfidScanning = false;
  bool _isContinuousModeBarcode = false;
  bool _isContinuousModeRfid = false;

  @override
  void initState() {
    super.initState();
    _listenRFIDStream();
    _listenBarcodeStream();
    _connect();
  }

  @override
  void dispose() {
    // Đảm bảo stop scan trước khi dispose
    RfidC72Plugin.stopScanBarcode;
    RfidC72Plugin.stopScan;

    // Delay nhỏ trước khi close
    Future.delayed(Duration(milliseconds: 200), () {
      RfidC72Plugin.close;
      RfidC72Plugin.closeScan;
    });

    super.dispose();
  }

  void _listenBarcodeStream() {
    RfidC72Plugin.barcodeStatusStream.receiveBroadcastStream().listen(
      (event) {
        debugPrint("📦 Nhận dữ liệu Barcode: $event");
        setState(() {
          if (_isContinuousModeBarcode) {
            if (event == "SCANNING") {
              _isBarcodeScanning = true;
              _barcode = "🔴 Đang quét liên tục...";
            } else if (event == "STOPPED") {
              _isBarcodeScanning = false;
              _barcode = "Đã dừng quét liên tục";
            } else {
              _barcode = event.toString();
            }
          } else {
            _barcode = event.toString();
          }
        });
      },
      onError: (error) {
        debugPrint("❌ Stream Barcode lỗi: $error");
        setState(() {
          _barcode = "Lỗi: $error";
          _isBarcodeScanning = false;
          _isContinuousModeBarcode = false;
        });
      },
    );
  }

  void _listenRFIDStream() {
    RfidC72Plugin.tagsStatusStream.receiveBroadcastStream().listen(
      (event) {
        debugPrint("📡 Nhận dữ liệu RFID: $event");
        setState(() {
          _rfidTag = event.toString();
        });
      },
      onError: (error) {
        debugPrint("❌ Stream RFID lỗi: $error");
      },
    );
  }

  Future<void> _connect() async {
    try {
      setState(() {
        _barcode = "Đang kết nối...";
      });

      final rfidResult = await RfidC72Plugin.connect;
      final barcodeResult = await RfidC72Plugin.connectBarcode;

      debugPrint("✅ Kết nối RFID: $rfidResult");
      debugPrint("✅ Kết nối Barcode: $barcodeResult");

      setState(() {
        _isConnected = rfidResult == true && barcodeResult == true;
        _barcode = _isConnected ? "Đã kết nối Barcode" : "Lỗi kết nối";
      });
    } catch (e) {
      debugPrint("❌ Lỗi kết nối: $e");
      setState(() {
        _isConnected = false;
        _barcode = "Lỗi kết nối: $e";
      });
    }
  }

  Future<void> _scanRfid() async {
    if (!_isConnected) {
      setState(() => _rfidTag = "Chưa kết nối thiết bị");
      return;
    }
    try {
      final result = await RfidC72Plugin.startSingle;
      debugPrint("📡 Start single scan RFID: $result");
    } catch (e) {
      setState(() => _rfidTag = "Lỗi: $e");
    }
  }

  Future<void> _scanRfidContinuous() async {
    if (!_isConnected) {
      setState(() => _rfidTag = "Chưa kết nối thiết bị");
      return;
    }
    try {
      setState(() {
        _isContinuousModeRfid = true;
        _isRfidScanning = true;
        _rfidTag = "Bắt đầu quyets rfid liên tục";
      });
      final result = await RfidC72Plugin.startContinuous;
      debugPrint("Start Rfid continuous scan: $result");
    } catch (e) {
      setState(() {
        _rfidTag = "Lỗi $e";
        _isContinuousModeRfid = false;
        _isRfidScanning = false;
      });
    }
  }

  Future<void> _stopRfidScan() async {
    try {
      debugPrint("🛑 Stopping RFID scan...");

      // Set state TRƯỚC khi gọi native để UI responsive ngay
      setState(() {
        _isRfidScanning = false;
        _isContinuousModeRfid = false;
        _rfidTag = "Đang dừng RFID...";
      });

      final result = await RfidC72Plugin.stopScan;
      debugPrint("✅ Stop RFID result: $result");

      setState(() {
        _rfidTag = "Đã dừng RFID";
      });
    } catch (e) {
      debugPrint("❌ Error stopping RFID: $e");
      setState(() {
        _rfidTag = "Lỗi dừng: $e";
        _isContinuousModeRfid = false;
        _isRfidScanning = false;
      });
    }
  }

  Future<void> _scanBarcodeC72Single() async {
    if (!_isConnected) {
      setState(() => _barcode = "Chưa kết nối thiết bị");
      return;
    }
    try {
      setState(() => _barcode = "🔴 Đang quét barcode (Single)...");
      final result = await RfidC72Plugin.scanBarcodeSingle;
      debugPrint("🔴 Start barcode single scan: $result");
      if (result != true) {
        setState(() => _barcode = "Lỗi khởi động laser (Single)");
      }
    } catch (e) {
      setState(() => _barcode = "Lỗi: $e");
    }
  }

  Future<void> _scanBarcodeC72Continuous() async {
    if (!_isConnected) return;
    try {
      setState(() {
        _isContinuousModeBarcode = true;
        _isBarcodeScanning = true;
        _barcode = "🔴 Bắt đầu quét liên tục...";
      });
      final result = await RfidC72Plugin.scanBarcodeContinuous;
      debugPrint("🔴 Start barcode continuous scan: $result");
    } catch (e) {
      setState(() {
        _barcode = "Lỗi: $e";
        _isContinuousModeBarcode = false;
        _isBarcodeScanning = false;
      });
    }
  }

  Future<void> _stopBarcodeScan() async {
    try {
      final result = await RfidC72Plugin.stopScanBarcode;
      debugPrint("⏹️ Stop barcode scan: $result");
      setState(() {
        _isContinuousModeBarcode = false;
        _isBarcodeScanning = false;
      });
    } catch (e) {
      setState(() {
        _barcode = "Lỗi dừng quét: $e";
        _isContinuousModeBarcode = false;
        _isBarcodeScanning = false;
      });
    }
  }

  Future<void> _scanBarcodeCamera() async {
    try {
      String barcodeScan = await FlutterBarcodeScanner.scanBarcode(
        '#ff6666',
        'Cancel',
        true,
        ScanMode.BARCODE,
      );
      if (barcodeScan != '-1') {
        setState(() => _barcode = barcodeScan);
      }
    } catch (e) {
      setState(() => _barcode = "Lỗi: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("C72 RFID + Barcode"),
        backgroundColor: _isConnected ? Colors.green : Colors.red,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        const Text("📡 RFID",
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Text(_rfidTag),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  color: _isBarcodeScanning ? Colors.red.shade50 : null,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text("📦 Barcode",
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.bold)),
                            if (_isBarcodeScanning)
                              Container(
                                margin: const EdgeInsets.only(left: 8),
                                width: 12,
                                height: 12,
                                decoration: const BoxDecoration(
                                  color: Colors.red,
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _barcode,
                          style: TextStyle(
                            color: _isBarcodeScanning ? Colors.red : null,
                            fontWeight: _isBarcodeScanning
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _connect,
                  icon: Icon(_isConnected ? Icons.check_circle : Icons.link),
                  label: Text(_isConnected ? "Đã kết nối" : "Kết nối C72"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isConnected ? Colors.green : null,
                    minimumSize: const Size(double.infinity, 50),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _isConnected ? _scanRfid : null,
                  icon: const Icon(Icons.nfc),
                  label: const Text("Quét RFID Single"),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _isConnected && !_isRfidScanning
                      ? _scanRfidContinuous
                      : null,
                  icon: const Icon(Icons.nfc),
                  label: const Text("Quét RFID Liên Tục"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.lightBlueAccent,
                    minimumSize: const Size(double.infinity, 50),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _isContinuousModeRfid ? _stopRfidScan : null,
                  icon: const Icon(Icons.nfc),
                  label: const Text("Dừng Quét RFID"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    minimumSize: const Size(double.infinity, 50),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _isConnected ? _scanBarcodeC72Single : null,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text("📍 Quét Barcode C72 Single"),
                  style: ElevatedButton.styleFrom(
                    // backgroundColor: Colors.blue,
                    minimumSize: const Size(double.infinity, 50),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _isConnected && !_isBarcodeScanning
                      ? _scanBarcodeC72Continuous
                      : null,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text("🔴 Quét Barcode C72 Liên tục"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.lightBlueAccent,
                    minimumSize: const Size(double.infinity, 50),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _isContinuousModeBarcode ? _stopBarcodeScan : null,
                  icon: const Icon(Icons.stop),
                  label: const Text("⏹️ Dừng Quét Liên tục"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    minimumSize: const Size(double.infinity, 50),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _scanBarcodeCamera,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text("📷 Quét Barcode Camera"),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
