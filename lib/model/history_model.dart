class HistoryModel {
  final String idLocal;
  final String barcode;
  final int timestampDevice;
  final String status;
  final String? lastError;

  HistoryModel({
    required this.idLocal,
    required this.barcode,
    required this.timestampDevice,
    required this.status,
    this.lastError,
  });

  Map<String, dynamic> toMap() {
    return {
      'id_local': idLocal,
      'barcode': barcode,
      'timestamp_device': timestampDevice,
      'status': status,
      'last_error': lastError,
    };
  }

  factory HistoryModel.fromMap(Map<String, dynamic> map) {
    return HistoryModel(
      idLocal: map['id_local'],
      barcode: map['barcode'],
      timestampDevice: map['timestamp_device'],
      status: map['status'],
      lastError: map['last_error'],
    );
  }
}
