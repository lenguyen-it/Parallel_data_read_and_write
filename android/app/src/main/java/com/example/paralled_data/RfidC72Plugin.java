package com.example.paralled_data;

import java.util.Map;
import java.util.HashMap;

import androidx.annotation.NonNull;
import android.util.Log;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.EventChannel;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import com.rscja.deviceapi.RFIDWithUHFUART;
import com.rscja.deviceapi.entity.UHFTAGInfo;

// Import Barcode API
import com.rscja.barcode.BarcodeDecoder;
import com.rscja.barcode.BarcodeFactory;
import com.rscja.deviceapi.entity.BarcodeEntity;

public class RfidC72Plugin implements FlutterPlugin, ActivityAware {
    private static final String TAG = "RfidC72Plugin";
    
    private MethodChannel methodChannel;
    private EventChannel tagsEventChannel;
    private EventChannel connectedEventChannel;
    private EventChannel barcodeEventChannel;

    private EventChannel.EventSink tagsSink;
    private EventChannel.EventSink connectedSink;
    private EventChannel.EventSink barcodeSink;

    private static final String METHOD_CHANNEL = "rfid_c72_plugin";
    private static final String TAGS_CHANNEL = "TagsStatus";
    private static final String CONNECTED_CHANNEL = "ConnectedStatus";
    private static final String BARCODE_CHANNEL = "BarcodeStatus";

    private Context context;
    private RFIDWithUHFUART uhfReader;
    private boolean isScanning = false;
    private boolean isBarcodeScanning = false;
    private Handler scanHandler;
    private ActivityPluginBinding activityBinding;

    // Barcode
    private BarcodeDecoder barcodeDecoder;
    private Thread barcodeScanThread;
    private final Object barcodeLock = new Object();
    
    // Static reference để cleanup khi hot restart
    private static RfidC72Plugin activeInstance;

    //Hashmap data
    // private Map<String, Object> tagDataList = new HashMap<>();

    // Hàm chuyển từ HEX sang ASCII
    private String hexToAscii(String hex) {
        if (hex == null) return "";
        StringBuilder output = new StringBuilder();
        // Nếu độ dài lẻ, bỏ ký tự cuối (phòng dữ liệu lỗi)
        int len = hex.length();
        if (len % 2 != 0) {
            Log.w(TAG, "hexToAscii: hex length is odd (" + len + "), trimming last nibble.");
            len = len - 1;
        }
        for (int i = 0; i < len; i += 2) {
            try {
                String part = hex.substring(i, i + 2);
                int val = Integer.parseInt(part, 16);
                output.append((char) val);
            } catch (Exception e) {
                Log.w(TAG, "Lỗi chuyển hexToAscii tại vị trí " + i + ": " + e.getMessage());
            }
        }
        return output.toString();
    }

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        Log.d(TAG, "🔌 onAttachedToEngine called");
        Log.d(TAG, "🧩 activeInstance hiện tại: " + activeInstance);
        Log.d(TAG, "🧩 this instance: " + this);
        
        if (activeInstance != null && activeInstance != this) {
            Log.w(TAG, "⚠️ Detected old instance, forcing cleanup...");
            activeInstance.forceCleanup();
        }
        
        context = binding.getApplicationContext();
        
        // forceCleanup();

        Log.d(TAG, "🧹 Running double cleanup with delay...");
        forceCleanup();

        new Handler(Looper.getMainLooper()).postDelayed(() -> {
            Log.d(TAG, "🧹 Second cleanup after delay...");
            forceCleanup();
        }, 1500); // 1.5 giây


        if (scanHandler == null) {
            scanHandler = new Handler(Looper.getMainLooper());
        }

        setupMethodChannel(binding);
        setupEventChannels(binding);
        
        activeInstance = this;
        
        Log.d(TAG, "✅ Plugin attached and ready");
    }

    private void forceCleanup() {
        Log.d(TAG, "🧹 Force cleanup all resources...");
        
        isScanning = false;
        isBarcodeScanning = false;
        
        synchronized (barcodeLock) {
            if (barcodeDecoder != null) {
                try {
                    Log.d(TAG, "Stopping barcode scan...");
                    barcodeDecoder.stopScan();
                    
                    Log.d(TAG, "Clearing barcode callback...");
                    barcodeDecoder.setDecodeCallback(null);
                    
                    Log.d(TAG, "Closing barcode decoder...");
                    barcodeDecoder.close();
                    
                } catch (Exception e) {
                    Log.w(TAG, "Error in force cleanup barcode: " + e.getMessage());
                } finally {
                    barcodeDecoder = null;
                }
            }
        }
        
        // Cleanup RFID
        if (uhfReader != null) {
            try {
                Log.d(TAG, "Stopping RFID inventory...");
                uhfReader.stopInventory();
                Thread.sleep(50);
                
                Log.d(TAG, "Freeing RFID reader...");
                uhfReader.free();
                
            } catch (Exception e) {
                Log.w(TAG, "Error in force cleanup RFID: " + e.getMessage());
            } finally {
                uhfReader = null;
            }
        }
        
        // Clear handler callbacks
        if (scanHandler != null) {
            scanHandler.removeCallbacksAndMessages(null);
        }

        try {
            Log.d(TAG, "🧯 Forcing BarcodeFactory releaseAll() to unlock UART...");
            Class<?> factoryClass = Class.forName("com.rscja.barcode.BarcodeFactory");
            java.lang.reflect.Method releaseAll = factoryClass.getDeclaredMethod("releaseAll");
            releaseAll.setAccessible(true);
            releaseAll.invoke(null);
            Log.d(TAG, "✅ BarcodeFactory.releaseAll() executed successfully");
        } catch (Exception e) {
            Log.w(TAG, "⚠️ BarcodeFactory.releaseAll() not found or failed: " + e.getMessage());
        }

        
        Log.d(TAG, "✅ Force cleanup completed");
    }


    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        Log.d(TAG, "🔌 onDetachedFromEngine called");
        try {

            forceCleanup();
            activeInstance = null;

            if (methodChannel != null) {
                methodChannel.setMethodCallHandler(null);
                methodChannel = null;
            }
            if (tagsEventChannel != null) {
                tagsEventChannel.setStreamHandler(null);
                tagsEventChannel = null;
            }
            if (connectedEventChannel != null) {
                connectedEventChannel.setStreamHandler(null);
                connectedEventChannel = null;
            }
            if (barcodeEventChannel != null) {
                barcodeEventChannel.setStreamHandler(null);
                barcodeEventChannel = null;
            }

            if (scanHandler != null) {
                scanHandler.removeCallbacksAndMessages(null);
                scanHandler = null;
            }
            
            // // Clear active instance
            // if (activeInstance == this) {
            //     activeInstance = null;
            // }

            Log.d(TAG, "✅ Detached from engine successfully");
        } catch (Exception e) {
            Log.e(TAG, "Error in onDetachedFromEngine: " + e.getMessage());
        }
    }

    private void setupMethodChannel(FlutterPluginBinding binding) {
        methodChannel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL);
        methodChannel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "getPlatformVersion":
                    result.success("Android " + android.os.Build.VERSION.RELEASE);
                    break;

                // ================= RFID =================
                case "connect":
                    connectRFID(result);
                    break;
                case "isConnected":
                    result.success(uhfReader != null);
                    break;
                case "startSingle":
                    startSingleScan(result);
                    break;
                case "startContinuous":
                    startContinuousScan(result);
                    break;
                case "stopScan":
                    stopScan(result);
                    break;
                case "close":
                    closeConnection(result);
                    break;

                // ================= BARCODE =================
                case "connectBarcode":
                    connectBarcode(result);
                    break;
                case "scanBarcodeContinuous":
                    scanBarcodeContinuous(result);
                    break;
                case "scanBarcodeSingle":
                    scanBarcodeSingle(result);
                    break;
                case "stopScanBarcode":
                    stopScanBarcode(result);
                    break;
                case "closeScan":
                    closeBarcode(result);
                    break;

                default:
                    result.notImplemented();
            }
        });
    }

    private void setupEventChannels(FlutterPluginBinding binding) {
        tagsEventChannel = new EventChannel(binding.getBinaryMessenger(), TAGS_CHANNEL);
        tagsEventChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                tagsSink = events;
            }
            @Override
            public void onCancel(Object arguments) {
                tagsSink = null;
            }
        });

        connectedEventChannel = new EventChannel(binding.getBinaryMessenger(), CONNECTED_CHANNEL);
        connectedEventChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                connectedSink = events;
            }
            @Override
            public void onCancel(Object arguments) {
                connectedSink = null;
            }
        });

        barcodeEventChannel = new EventChannel(binding.getBinaryMessenger(), BARCODE_CHANNEL);
        barcodeEventChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                barcodeSink = events;
            }
            @Override
            public void onCancel(Object arguments) {
                barcodeSink = null;
            }
        });
    }

    // ================= RFID =================
    private void connectRFID(MethodChannel.Result result) {
        try {
            if (uhfReader == null) {
                uhfReader = RFIDWithUHFUART.getInstance();
            }
            boolean connected = uhfReader.init(context);
            if (connected) {
                if (connectedSink != null) connectedSink.success(true);
                result.success(true);
            } else {
                result.error("CONNECT_ERROR", "Không thể kết nối với RFID", null);
            }
        } catch (Exception e) {
            Log.e(TAG, "Lỗi kết nối RFID: " + e.getMessage());
            result.error("EXCEPTION", "Lỗi kết nối RFID: " + e.getMessage(), null);
        }
    }

    private void startSingleScan(MethodChannel.Result result) {
        if (uhfReader == null) {
            result.error("NOT_CONNECTED", "Chưa kết nối RFID", null);
            return;
        }
        try {
            UHFTAGInfo tagInfo = uhfReader.inventorySingleTag();
            if (tagInfo != null) {
                String epcHex = tagInfo.getEPC();
                String epcAscii = hexToAscii(epcHex);
                String rssi = tagInfo.getRssi();

                if (tagsSink != null) tagsSink.success(epcAscii);

                //if (tagsSink != null) tagsSink.success("EPC: " + epcAscii + ", RSSI: " + rssi);

                // Nếu cần debug thêm, bạn có thể gửi cả HEX và ASCII:
                // if (tagsSink != null) tagsSink.success("EPC_HEX: " + epcHex + ", EPC_ASCII: " + epcAscii + ", RSSI: " + rssi);

                result.success(true);
            } else {
                result.success(false);
            }

        } catch (Exception e) {
            Log.e(TAG, "Lỗi quét RFID: " + e.getMessage());
            result.error("SCAN_ERROR", "Lỗi quét RFID: " + e.getMessage(), null);
        }
    }

    // private void startContinuousScan(MethodChannel.Result result) {
    //     if (uhfReader == null) {
    //         result.error("NOT_CONNECTED", "Chưa kết nối RFID", null);
    //         return;
    //     }
    //     try {
    //         if (isScanning) {
    //             result.success(true);
    //             return;
    //         }
    //         isScanning = true;
    //         new Thread(() -> {
    //             while (isScanning) {
    //                 try {
    //                     UHFTAGInfo tagInfo = uhfReader.inventorySingleTag();
    //                     if (tagInfo != null) {
    //                         String epcHex = tagInfo.getEPC();
    //                         String epcAscii = hexToAscii(epcHex);
    //                         String rssi = tagInfo.getRssi();
    //                         scanHandler.post(() -> {
    //                             if (tagsSink != null) {
    //                                 tagsSink.success(epcAscii);

    //                                 // tagsSink.success("EPC: " + epcAscii + ", RSSI: " + rssi);
    //                                 // Debug option:
    //                                 // tagsSink.success("EPC_HEX: " + epcHex + ", EPC_ASCII: " + epcAscii + ", RSSI: " + rssi);
    //                             }
    //                         });
    //                     }
    //                     Thread.sleep(100);
    //                 } catch (InterruptedException ie) {
    //                     Log.w(TAG, "Continuous scan interrupted: " + ie.getMessage());
    //                     break;
    //                 } catch (Exception e) {
    //                     Log.e(TAG, "Error in continuous scan loop: " + e.getMessage());
    //                 }
    //             }
    //         }).start();
    //         result.success(true);
    //     } catch (Exception e) {
    //         isScanning = false;
    //         Log.e(TAG, "Lỗi quét liên tục RFID: " + e.getMessage());
    //         result.error("SCAN_ERROR", "Lỗi quét liên tục RFID: " + e.getMessage(), null);
    //     }
    // }

    private void startContinuousScan(MethodChannel.Result result) {
    if (uhfReader == null) {
        result.error("NOT_CONNECTED", "Chưa kết nối RFID", null);
        return;
    }
    try {
        if (isScanning) {
            result.success(true);
            return;
        }

        isScanning = true;

        new Thread(() -> {
            while (isScanning) {
                try {
                    // Bắt đầu đo thời gian (tùy chọn)
                    long startTime = System.currentTimeMillis();

                    // Gọi đọc 1 tag
                    UHFTAGInfo tagInfo = uhfReader.inventorySingleTag();

                    if (tagInfo != null) {
                        String epcHex = tagInfo.getEPC();
                        String epcAscii = hexToAscii(epcHex);

                        scanHandler.post(() -> {
                            if (tagsSink != null) {
                                tagsSink.success(epcAscii);
                            }
                        });
                    }

                    // Không sleep — đọc liên tục
                    long endTime = System.currentTimeMillis();
                    long duration = endTime - startTime;

                    // Optional: nếu cần giãn nhịp theo thời gian đọc thực tế (tự nhiên)
                    if (duration < 5) {
                        // rất ngắn, thêm delay nhẹ tránh loop CPU 100%
                        Thread.yield();
                    }

                } catch (Exception e) {
                    Log.e(TAG, "Error in continuous scan loop: " + e.getMessage());
                }
            }
        }).start();

        result.success(true);
    } catch (Exception e) {
        isScanning = false;
        Log.e(TAG, "Lỗi quét liên tục RFID: " + e.getMessage());
        result.error("SCAN_ERROR", "Lỗi quét liên tục RFID: " + e.getMessage(), null);
    }
}


    private void stopScan(MethodChannel.Result result) {
        try {
            isScanning = false;
            if (uhfReader != null) uhfReader.stopInventory();
            result.success(true);
        } catch (Exception e) {
            Log.e(TAG, "Lỗi dừng quét: " + e.getMessage());
            result.error("STOP_ERROR", "Lỗi dừng quét: " + e.getMessage(), null);
        }
    }

    private void closeConnection(MethodChannel.Result result) {
        try {
            forceCleanup();
            if (connectedSink != null) connectedSink.success(false);
            result.success(true);
        } catch (Exception e) {
            Log.e(TAG, "Lỗi đóng kết nối: " + e.getMessage());
            result.error("CLOSE_ERROR", "Lỗi đóng kết nối: " + e.getMessage(), null);
        }
    }

    // ================= BARCODE =================
    private void connectBarcode(MethodChannel.Result result) {
        new Thread(() -> {
            int maxRetries = 3;
            int retryCount = 0;
            boolean opened = false;

            while (retryCount < maxRetries && !opened) {
                try {
                    // Force đóng decoder cũ nếu đang mở
                    synchronized (barcodeLock) {
                        if (barcodeDecoder != null) {
                            try {
                                Log.d(TAG, "Force closing old decoder...");
                                barcodeDecoder.stopScan();
                                barcodeDecoder.setDecodeCallback(null);
                                barcodeDecoder.close();
                            } catch (Exception e) {
                                Log.w(TAG, "Error closing old decoder: " + e.getMessage());
                            }
                            barcodeDecoder = null;
                        }
                    }

                    Thread.sleep(500 * (retryCount + 1));

                    // Tạo mới decoder
                    Log.d(TAG, "Creating new barcode decoder...");
                    synchronized (barcodeLock) {
                        barcodeDecoder = BarcodeFactory.getInstance().getBarcodeDecoder();
                        Log.d(TAG, "BarcodeFactory instance: " + BarcodeFactory.getInstance());
                        Log.d(TAG, "BarcodeDecoder instance before open: " + barcodeDecoder);
                        Log.d(TAG, "Barcode open context: " + context.hashCode());
                    }

                    if (barcodeDecoder == null) {
                        retryCount++;
                        Log.w(TAG, "BarcodeFactory trả về null, retrying... (" + retryCount + "/" + maxRetries + ")");
                        continue;
                    }

                    // Mở decoder
                    synchronized (barcodeLock) {
                        opened = barcodeDecoder.open(context);
                    }
                    Log.d(TAG, "Barcode decoder open result: " + opened);

                    if (!opened) {
                        retryCount++;
                        synchronized (barcodeLock) {
                            barcodeDecoder = null;
                        }
                        Log.w(TAG, "Không thể mở barcode decoder, retrying... (" + retryCount + "/" + maxRetries + ")");
                        continue;
                    }

                    // Thiết lập callback cho quét
                    synchronized (barcodeLock) {
                        barcodeDecoder.setDecodeCallback(new BarcodeDecoder.DecodeCallback() {
                            @Override
                            public void onDecodeComplete(BarcodeEntity barcodeEntity) {
                                int resultCode = barcodeEntity.getResultCode();
                                Log.d(TAG, "🔥 BarcodeDecoder callback - resultCode: " + resultCode);

                                if (resultCode == BarcodeDecoder.DECODE_SUCCESS) {
                                    String scannedBarcode = barcodeEntity.getBarcodeData();
                                    Log.d(TAG, "✅ Barcode scanned: " + scannedBarcode);

                                    // Gửi dữ liệu về Flutter
                                    scanHandler.post(() -> {
                                        if (barcodeSink != null) {
                                            barcodeSink.success(scannedBarcode);
                                            Log.d(TAG, "📤 Sent to Flutter: " + scannedBarcode);
                                        } else {
                                            Log.e(TAG, "❌ barcodeSink is null!");
                                        }
                                    });

                                    // Luôn dừng scan sau success để tắt laser
                                    synchronized (barcodeLock) {
                                        if (barcodeDecoder != null) {
                                            try {
                                                barcodeDecoder.stopScan();
                                                Log.d(TAG, "Stopped scan after success");
                                            } catch (Exception e) {
                                                Log.e(TAG, "Error stopping scan after success: " + e.getMessage());
                                            }
                                        }
                                    }

                                    // Nếu là chế độ liên tục, khởi động lại sau delay
                                    if (isBarcodeScanning) {
                                        scanHandler.postDelayed(() -> {
                                            synchronized (barcodeLock) {
                                                if (barcodeDecoder != null && isBarcodeScanning) {
                                                    Log.d(TAG, "🔄 Auto restart scan...");
                                                    try {
                                                        barcodeDecoder.startScan();
                                                    } catch (Exception e) {
                                                        Log.e(TAG, "Error restarting scan: " + e.getMessage());
                                                        isBarcodeScanning = false;
                                                        scanHandler.post(() -> {
                                                            if (barcodeSink != null) {
                                                                barcodeSink.success("STOPPED");
                                                            }
                                                        });
                                                    }
                                                }
                                            }
                                        }, 300);
                                    }
                                } else {
                                    Log.e(TAG, "❌ Decode FAIL - resultCode: " + resultCode);
                                    if (isBarcodeScanning) {
                                        scanHandler.postDelayed(() -> {
                                            synchronized (barcodeLock) {
                                                if (barcodeDecoder != null && isBarcodeScanning) {
                                                    Log.d(TAG, "🔄 Retry scan after failure...");
                                                    try {
                                                        barcodeDecoder.startScan();
                                                    } catch (Exception e) {
                                                        Log.e(TAG, "Error retrying scan: " + e.getMessage());
                                                    }
                                                }
                                            }
                                        }, 100);
                                    }
                                }
                            }
                        });
                    }

                    Log.d(TAG, "✅ Barcode decoder connected successfully");
                    scanHandler.post(() -> {
                        result.success(true);
                    });
                    return;

                } catch (Exception e) {
                    retryCount++;
                    Log.e(TAG, "Lỗi kết nối barcode (attempt " + retryCount + "/" + maxRetries + "): " + e.getMessage());
                    e.printStackTrace();
                    synchronized (barcodeLock) {
                        barcodeDecoder = null;
                    }
                }
            }

            // Nếu thất bại sau maxRetries
            if (!opened) {
                scanHandler.post(() -> {
                    result.error("OPEN_ERROR", "Không thể kết nối barcode sau " + maxRetries + " lần thử", null);
                });
            }
        }).start();
    }

    private void scanBarcodeContinuous(MethodChannel.Result result) {
        try {
            synchronized (barcodeLock) {
                if (barcodeDecoder == null) {
                    Log.w(TAG, "⚠️ BarcodeDecoder null, force reconnecting...");
                    connectBarcode(new MethodChannel.Result() {
                        @Override
                        public void success(Object o) {
                            Log.d(TAG, "✅ Reconnect success, starting continuous scan...");
                            scanHandler.postDelayed(() -> {
                                startBarcodeScanInternal(true, result);
                            }, 800);
                        }
                        @Override
                        public void error(String s, String s1, Object o) {
                            Log.e(TAG, "❌ Reconnect failed: " + s1);
                            result.error(s, s1, o);
                        }
                        @Override
                        public void notImplemented() {
                            result.notImplemented();
                        }
                    });
                    return;
                }
            }
            
            startBarcodeScanInternal(true, result);
        } catch (Exception e) {
            isBarcodeScanning = false;
            Log.e(TAG, "❌ Lỗi quét barcode: " + e.getMessage());
            e.printStackTrace();
            result.error("SCAN_ERROR", "Lỗi quét barcode: " + e.getMessage(), null);
        }
    }

    private void scanBarcodeSingle(MethodChannel.Result result) {
        try {
            synchronized (barcodeLock) {
                if (barcodeDecoder == null) {
                    Log.w(TAG, "⚠️ BarcodeDecoder null, force reconnecting...");
                    connectBarcode(new MethodChannel.Result() {
                        @Override
                        public void success(Object o) {
                            Log.d(TAG, "✅ Reconnect success, starting single scan...");
                            scanHandler.postDelayed(() -> {
                                startBarcodeScanInternal(false, result);
                            }, 800);
                        }
                        @Override
                        public void error(String s, String s1, Object o) {
                            Log.e(TAG, "❌ Reconnect failed: " + s1);
                            result.error(s, s1, o);
                        }
                        @Override
                        public void notImplemented() {
                            result.notImplemented();
                        }
                    });
                    return;
                }
            }
            
            startBarcodeScanInternal(false, result);
        } catch (Exception e) {
            Log.e(TAG, "❌ Lỗi quét single barcode: " + e.getMessage());
            e.printStackTrace();
            result.error("SCAN_ERROR", "Lỗi quét single barcode: " + e.getMessage(), null);
        }
    }

    private void startBarcodeScanInternal(boolean continuous, MethodChannel.Result result) {
        synchronized (barcodeLock) {
            if (barcodeDecoder == null) {
                Log.e(TAG, "BarcodeDecoder is null, cannot start scan");
                result.error("NOT_INITIALIZED", "Barcode decoder chưa được khởi tạo", null);
                return;
            }

            if (isBarcodeScanning && continuous) {
                Log.w(TAG, "Barcode scan đang chạy rồi");
                result.success(true);
                return;
            }

            try {
                isBarcodeScanning = continuous;

                Log.i(TAG, "Calling startScan()...");
                barcodeDecoder.startScan();
                Log.i(TAG, "startScan() called successfully");

                scanHandler.post(() -> {
                    if (barcodeSink != null) {
                        barcodeSink.success("SCANNING");
                    }
                });

                result.success(true);
            } catch (Exception e) {
                isBarcodeScanning = false;
                Log.e(TAG, "Lỗi startScan: " + e.getMessage());
                e.printStackTrace();
                result.error("START_SCAN_ERROR", "Lỗi khởi động laser: " + e.getMessage(), null);
            }
        }
    }

    private void stopScanBarcode(MethodChannel.Result result) {
        synchronized (barcodeLock) {
            if (barcodeDecoder == null) {
                result.error("NOT_CONNECTED", "Chưa kết nối barcode", null);
                return;
            }
            
            try {
                isBarcodeScanning = false;
                barcodeDecoder.stopScan();
                
                Log.i(TAG, "Đã TẮT laser - Dừng quét barcode");
                
                scanHandler.post(() -> {
                    if (barcodeSink != null) {
                        barcodeSink.success("STOPPED");
                    }
                });
                
                result.success(true);
            } catch (Exception e) {
                isBarcodeScanning = false;
                Log.e(TAG, "Lỗi dừng quét barcode: " + e.getMessage());
                result.error("STOP_ERROR", "Lỗi dừng quét barcode: " + e.getMessage(), null);
            }
        }
    }

    private void closeBarcode(MethodChannel.Result result) {
        try {
            isBarcodeScanning = false;
            
            synchronized (barcodeLock) {
                if (barcodeDecoder != null) {
                    barcodeDecoder.stopScan();
                    barcodeDecoder.close();
                    barcodeDecoder = null;
                }
            }
            
            Log.i(TAG, "🔒 Barcode decoder đã đóng");
            result.success(true);
        } catch (Exception e) {
            Log.e(TAG, "❌ Lỗi đóng barcode: " + e.getMessage());
            result.error("CLOSE_ERROR", "Lỗi đóng barcode: " + e.getMessage(), null);
        }
    }
    
    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) { 
        this.activityBinding = binding; 
    }
    
    @Override
    public void onDetachedFromActivityForConfigChanges() { 
        Log.d(TAG, "🔌 onDetachedFromActivityForConfigChanges called");
        this.activityBinding = null; 
    }
    
    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) { 
        Log.d(TAG, "🔌 onReattachedToActivityForConfigChanges called");
        forceCleanup();
        this.activityBinding = binding; 
    }
    
    @Override
    public void onDetachedFromActivity() { 
        Log.d(TAG, "🔌 onDetachedFromActivity called");
        forceCleanup();
        this.activityBinding = null; 
    }
}