package com.example.paralled_data.connect_bluetooth;

import android.app.Activity;
import android.bluetooth.BluetoothDevice;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;

import com.rscja.deviceapi.RFIDWithUHFBLE;
import com.rscja.deviceapi.entity.UHFTAGInfo;
import com.rscja.deviceapi.interfaces.ConnectionStatus;
import com.rscja.deviceapi.interfaces.ConnectionStatusCallback;
import com.rscja.deviceapi.interfaces.IUHFInventoryCallback;
import com.rscja.deviceapi.interfaces.KeyEventCallback;
import com.rscja.deviceapi.interfaces.ScanBTCallback;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

public class RfidBlePlugin implements FlutterPlugin, MethodCallHandler, ActivityAware {
    private static final String TAG = "RfidBlePlugin";
    private static final String METHOD_CHANNEL = "rfid_ble_channel";
    private static final String SCAN_EVENT_CHANNEL = "ble_rfid_scan_result";
    private static final String RFID_DATA_CHANNEL = "rfid_ble_data";
    private static final String CONFIG_CHANNEL = "ble_rfid_config";
    private static final String CONNECTION_CHANNEL = "ble_rfid_connection"; // New channel for connection status

    private MethodChannel methodChannel;
    private EventChannel scanEventChannel;
    private EventChannel rfidDataChannel;
    private EventChannel configEventChannel;
    private EventChannel connectionEventChannel; // New EventChannel

    private EventChannel.EventSink scanEventSink;
    private EventChannel.EventSink rfidDataSink;
    private EventChannel.EventSink configEventSink;
    private EventChannel.EventSink connectionEventSink; // New EventSink

    private Activity activity;
    private Context context;
    private RFIDWithUHFBLE uhfble;
    private Handler mainHandler = new Handler(Looper.getMainLooper());

    private boolean isInventoryRunning = false;
    private boolean isScanning = false;
    private Handler scanHandler = new Handler(Looper.getMainLooper());
    private static final long SCAN_PERIOD = 10000; // 10 seconds


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
        context = binding.getApplicationContext();
        
        // Setup MethodChannel
        methodChannel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL);
        methodChannel.setMethodCallHandler(this);

        // Setup EventChannels
        scanEventChannel = new EventChannel(binding.getBinaryMessenger(), SCAN_EVENT_CHANNEL);
        scanEventChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                scanEventSink = events;
                Log.d(TAG, "Scan EventSink connected");
            }

            @Override
            public void onCancel(Object arguments) {
                scanEventSink = null;
                Log.d(TAG, "Scan EventSink disconnected");
            }
        });

        rfidDataChannel = new EventChannel(binding.getBinaryMessenger(), RFID_DATA_CHANNEL);
        rfidDataChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                rfidDataSink = events;
                Log.d(TAG, "RFID EventSink connected");
            }

            @Override
            public void onCancel(Object arguments) {
                rfidDataSink = null;
                Log.d(TAG, "RFID EventSink disconnected");
            }
        });

        configEventChannel = new EventChannel(binding.getBinaryMessenger(), CONFIG_CHANNEL);
        configEventChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                configEventSink = events;
                Log.d(TAG, "Config EventSink connected");
            }

            @Override
            public void onCancel(Object arguments) {
                configEventSink = null;
                Log.d(TAG, "Config EventSink disconnected");
            }
        });

        connectionEventChannel = new EventChannel(binding.getBinaryMessenger(), CONNECTION_CHANNEL);
        connectionEventChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                connectionEventSink = events;
                Log.d(TAG, "Connection EventSink connected");
            }

            @Override
            public void onCancel(Object arguments) {
                connectionEventSink = null;
                Log.d(TAG, "Connection EventSink disconnected");
            }
        });
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
        switch (call.method) {
            case "getPlatformVersion":
                result.success("Android " + android.os.Build.VERSION.RELEASE);
                break;

            case "startScan":
                startScan(result);
                break;

            case "stopScan":
                stopScan(result);
                break;

            case "connectDevice":
                String mac = call.argument("mac");
                connectToDevice(mac, result);
                break;

            case "disconnect":
                disconnectDevice(result);
                break;

            case "singleInventory":
                singleInventory(result);
                break;

            case "startInventory":
                startInventory(result);
                break;

            case "stopInventory":
                stopInventory(result);
                break;

            case "getBatteryLevel":
                getBatteryLevel(result);
                break;

            default:
                result.notImplemented();
                break;
        }
    }

    private void startScan(Result result) {
        if (activity == null) {
            result.error("NO_ACTIVITY", "Activity not available", null);
            return;
        }

        if (uhfble == null) {
            initializeUHFBLE();
        }

        if (isScanning) {
            result.success("Already scanning");
            return;
        }

        Log.d(TAG, "Starting BLE scan...");
        isScanning = true;

        // Auto stop after SCAN_PERIOD
        scanHandler.postDelayed(() -> {
            if (isScanning) {
                stopScan(new Result() {
                    @Override
                    public void success(Object o) {
                        Log.d(TAG, "Auto-stopped scan after timeout");
                    }
                    @Override
                    public void error(String s, String s1, Object o) {}
                    @Override
                    public void notImplemented() {}
                });
            }
        }, SCAN_PERIOD);

        uhfble.startScanBTDevices(new ScanBTCallback() {
            @Override
            public void getDevices(BluetoothDevice bluetoothDevice, int rssi, byte[] bytes) {
                if (bluetoothDevice == null) return;
                
                String name = bluetoothDevice.getName();
                String address = bluetoothDevice.getAddress();
                
                // Filter out devices without name
                if (name == null || name.isEmpty()) {
                    return;
                }

                Log.d(TAG, "Found device: " + name + " (" + address + ") RSSI: " + rssi);

                Map<String, String> deviceMap = new HashMap<>();
                deviceMap.put("name", name);
                deviceMap.put("address", address);
                
                if (scanEventSink != null) {
                    mainHandler.post(() -> scanEventSink.success(deviceMap));
                } else {
                    Log.w(TAG, "scanEventSink is null, cannot send device data");
                }
            }
        });

        result.success(null);
    }

    private void stopScan(Result result) {
        if (uhfble != null && isScanning) {
            uhfble.stopScanBTDevices();
            isScanning = false;
            scanHandler.removeCallbacksAndMessages(null);
            Log.d(TAG, "Stopped BLE scan");
        }
        result.success(null);
    }

    private void connectToDevice(String macAddress, Result result) {
    if (uhfble == null) {
        initializeUHFBLE();
    }

    if (macAddress == null || macAddress.isEmpty()) {
        result.error("INVALID_MAC", "MAC address is required", null);
        return;
    }

    Log.d(TAG, "Connecting to: " + macAddress);

    // Flag để đảm bảo result chỉ được gọi 1 lần
    final boolean[] resultSubmitted = {false};

    uhfble.connect(macAddress, new ConnectionStatusCallback<Object>() {
        @Override
        public void getStatus(ConnectionStatus connectionStatus, Object device) {
            BluetoothDevice btDevice = (BluetoothDevice) device;
            
            mainHandler.post(() -> {
                if (connectionStatus == ConnectionStatus.CONNECTED) {
                    Log.d(TAG, "Connected to: " + btDevice.getName());
                    
                    // Send connection status to Flutter
                    Map<String, Object> statusMap = new HashMap<>();
                    statusMap.put("connection", true);
                    if (connectionEventSink != null) {
                        connectionEventSink.success(statusMap);
                    }
                    
                    // Initialize RFID
                    initRFID();
                    
                    // Chỉ gọi result.success() 1 lần duy nhất
                    if (!resultSubmitted[0]) {
                        resultSubmitted[0] = true;
                        result.success("Connected to " + btDevice.getName());
                    }
                    
                } else if (connectionStatus == ConnectionStatus.DISCONNECTED) {
                    Log.d(TAG, "Disconnected from: " + btDevice.getName());
                    
                    // Send connection status to Flutter
                    Map<String, Object> statusMap = new HashMap<>();
                    statusMap.put("connection", false);
                    if (connectionEventSink != null) {
                        connectionEventSink.success(statusMap);
                    }
                    
                    // QUAN TRỌNG: Chỉ gọi result.error() nếu chưa submit result
                    // Nếu disconnect xảy ra SAU khi đã connected, thì KHÔNG gọi result.error()
                    if (!resultSubmitted[0]) {
                        resultSubmitted[0] = true;
                        result.error("DISCONNECTED", "Failed to connect", null);
                    }
                    // Nếu disconnect xảy ra SAU khi đã connected thành công,
                    // chỉ cần gửi qua connectionEventSink là đủ
                    
                } else if (connectionStatus == ConnectionStatus.CONNECTING) {
                    Log.d(TAG, "Connecting to: " + btDevice.getName());
                }
            });
        }
    });
}

    private void disconnectDevice(Result result) {
        if (uhfble != null) {
            uhfble.disconnect();
            
            Map<String, Object> statusMap = new HashMap<>();
            statusMap.put("connection", false);
            if (connectionEventSink != null) {
                mainHandler.post(() -> connectionEventSink.success(statusMap));
            }
        }
        result.success(null);
    }

    private void singleInventory(Result result) {
        if (uhfble == null || uhfble.getConnectStatus() != ConnectionStatus.CONNECTED) {
            result.error("NOT_CONNECTED", "Device not connected", null);
            return;
        }

        UHFTAGInfo tagInfo = uhfble.inventorySingleTag();
        if (tagInfo != null) {
            sendRfidData(tagInfo);
            result.success(null);
        } else {
            result.error("NO_TAG", "No tag found", null);
        }
    }

    private void startInventory(Result result) {
        if (uhfble == null || uhfble.getConnectStatus() != ConnectionStatus.CONNECTED) {
            result.error("NOT_CONNECTED", "Device not connected", null);
            return;
        }

        if (isInventoryRunning) {
            result.success(null);
            return;
        }

        // Register callback to receive RFID data
        uhfble.setInventoryCallback(new IUHFInventoryCallback() {
            @Override
            public void callback(UHFTAGInfo uhftagInfo) {
                if (uhftagInfo != null) {
                    sendRfidData(uhftagInfo);
                }
            }
        });
        
        // Start scanning
        isInventoryRunning = true;
        boolean started = uhfble.startInventoryTag();
        
        if (started) {
            result.success(null);
        } else {
            isInventoryRunning = false;
            result.error("START_FAILED", "Failed to start inventory", null);
        }
    }

    private void stopInventory(Result result) {
        if (uhfble != null && uhfble.getConnectStatus() == ConnectionStatus.CONNECTED) {
            uhfble.stopInventory();
            isInventoryRunning = false;
        }
        result.success(null);
    }

    private void getBatteryLevel(Result result) {
        if (uhfble == null || uhfble.getConnectStatus() != ConnectionStatus.CONNECTED) {
            result.error("NOT_CONNECTED", "Device not connected", null);
            return;
        }

        int battery = uhfble.getBattery();
        
        Map<String, Object> configMap = new HashMap<>();
        configMap.put("battery", battery);
        configMap.put("type", "battery");
        
        if (configEventSink != null) {
            mainHandler.post(() -> configEventSink.success(configMap));
        }
        
        result.success(null);
    }

    private void sendRfidData(UHFTAGInfo tagInfo) {
        if (rfidDataSink != null && tagInfo != null) {
            Map<String, Object> dataMap = new HashMap<>();

            // Dữ liệu gốc dạng HEX
            String epcHex = tagInfo.getEPC() != null ? tagInfo.getEPC() : "";
            String tidHex = tagInfo.getTid() != null ? tagInfo.getTid() : "";
            String userHex = tagInfo.getUser() != null ? tagInfo.getUser() : "";

            // Chuyển sang ASCII (nếu hợp lệ)
            String epcAscii = hexToAscii(epcHex);
            String tidAscii = hexToAscii(tidHex);
            String userAscii = hexToAscii(userHex);

            // Gộp vào map để gửi về Flutter
            dataMap.put("epc_hex", epcHex);
            dataMap.put("epc_ascii", epcAscii);
            dataMap.put("tid_hex", tidHex);
            dataMap.put("tid_ascii", tidAscii);
            dataMap.put("user_hex", userHex);
            dataMap.put("user_ascii", userAscii);
            dataMap.put("rssi", tagInfo.getRssi() != null ? tagInfo.getRssi() : "");
            dataMap.put("count", tagInfo.getCount());

            // Gửi qua EventChannel
            mainHandler.post(() -> rfidDataSink.success(dataMap));

            Log.d(TAG, "RFID Data Sent: EPC=" + epcAscii + " (HEX: " + epcHex + ")");
        }
    }


    private void initializeUHFBLE() {
        try {
            if (context == null) {
                Log.e(TAG, "Context is null, cannot initialize UHFBLE");
                return;
            }
            
            uhfble = RFIDWithUHFBLE.getInstance();
            
            // CRITICAL: Initialize with context
            if (uhfble != null) {
                uhfble.init(context);
                Log.d(TAG, "UHFBLE initialized and context set");
            } else {
                Log.e(TAG, "UHFBLE getInstance returned null");
            }
        } catch (Exception e) {
            Log.e(TAG, "Error initializing UHFBLE: " + e.getMessage(), e);
        }
    }

    private void initRFID() {
        if (uhfble != null && uhfble.getConnectStatus() == ConnectionStatus.CONNECTED) {
            // Initialize RFID with Context
            uhfble.init(context);
            
            // Register hardware key events on device
            uhfble.setKeyEventCallback(new KeyEventCallback() {
                @Override
                public void onKeyDown(int keycode) {
                    Log.d(TAG, "Key Down: " + keycode);
                    
                    if (keycode == 1) {
                        if (!isInventoryRunning) {
                            startInventory(new Result() {
                                @Override
                                public void success(Object result) {
                                    Log.d(TAG, "Inventory started by hardware button");
                                }
                                
                                @Override
                                public void error(String errorCode, String errorMessage, Object errorDetails) {
                                    Log.e(TAG, "Failed to start inventory: " + errorMessage);
                                }
                                
                                @Override
                                public void notImplemented() {}
                            });
                        }
                    }
                }

                @Override
                public void onKeyUp(int keycode) {
                    Log.d(TAG, "Key Up: " + keycode);
                    
                    if (keycode == 4 || keycode == 1) {
                        if (isInventoryRunning) {
                            stopInventory(new Result() {
                                @Override
                                public void success(Object result) {
                                    Log.d(TAG, "Inventory stopped by hardware button");
                                }
                                
                                @Override
                                public void error(String errorCode, String errorMessage, Object errorDetails) {
                                    Log.e(TAG, "Failed to stop inventory: " + errorMessage);
                                }
                                
                                @Override
                                public void notImplemented() {}
                            });
                        }
                    }
                }
            });
        }
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (methodChannel != null) {
            methodChannel.setMethodCallHandler(null);
        }
        if (scanEventChannel != null) {
            scanEventChannel.setStreamHandler(null);
        }
        if (rfidDataChannel != null) {
            rfidDataChannel.setStreamHandler(null);
        }
        if (configEventChannel != null) {
            configEventChannel.setStreamHandler(null);
        }
        if (connectionEventChannel != null) {
            connectionEventChannel.setStreamHandler(null);
        }
        
        if (uhfble != null) {
            if (isInventoryRunning) {
                uhfble.stopInventory();
            }
            if (isScanning) {
                uhfble.stopScanBTDevices();
            }
            uhfble.disconnect();
            uhfble.free();
        }
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        this.activity = binding.getActivity();
        
        // Request Bluetooth and Location permissions
        Connections.requestBluetoothPermissions(activity, 1);
        Connections.requestLocationPermissions(activity, 2);
        
        Log.d(TAG, "Activity attached");
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        this.activity = null;
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        this.activity = binding.getActivity();
    }

    @Override
    public void onDetachedFromActivity() {
        this.activity = null;
    }
}