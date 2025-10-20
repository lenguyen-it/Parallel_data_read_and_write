class HistoryModel {
  final String idLocal;
  final String epc;
  final int timestampDevice;
  final String status;
  final String? lastError;
  final double? scanDurationMs;
  final double? syncDurationMs;

  HistoryModel({
    required this.idLocal,
    required this.epc,
    required this.timestampDevice,
    required this.status,
    this.lastError,
    this.scanDurationMs,
    this.syncDurationMs,
  });

  Map<String, dynamic> toMap() {
    return {
      'id_local': idLocal,
      'epc': epc,
      'timestamp_device': timestampDevice,
      'status': status,
      'last_error': lastError,
      'scan_duration_ms': scanDurationMs,
      'sync_duration_ms': syncDurationMs,
    };
  }

  factory HistoryModel.fromMap(Map<String, dynamic> map) {
    return HistoryModel(
      idLocal: map['id_local'],
      epc: map['epc'],
      timestampDevice: map['timestamp_device'],
      status: map['status'],
      lastError: map['last_error'],
      scanDurationMs: map['scan_duration_ms']?.toDouble(),
      syncDurationMs: map['sync_duration_ms']?.toDouble(),
    );
  }
}
