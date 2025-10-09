package com.example.paralled_data.connect_bluetooth;

import android.content.Context;
import android.util.Log;

import androidx.annotation.NonNull;

import com.rscja.deviceapi.RFIDWithUHFBLE;
import com.rscja.deviceapi.interfaces.ConnectionStatusCallback;
import com.rscja.deviceapi.interfaces.ConnectionStatus;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public class ConnectionBluetoothPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private static final String TAG = "R5BluetoothPlugin";

    private MethodChannel methodChannel;
    private EventChannel eventChannel;
    private EventChannel.EventSink eventSink;
    private Context context;

    private RFIDWithUHFBLE uhfble;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();

        methodChannel = new MethodChannel(binding.getBinaryMessenger(), "bluetooth/methods");
        methodChannel.setMethodCallHandler(this);

        eventChannel = new EventChannel(binding.getBinaryMessenger(), "bluetooth/stream");
        eventChannel.setStreamHandler(this);

        // Khởi tạo R5 wearable RFID
        uhfble = RFIDWithUHFBLE.getInstance();
        uhfble.init(context);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        methodChannel.setMethodCallHandler(null);
        eventChannel.setStreamHandler(null);
        disconnect(null);
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        String method = call.method;
        switch (method) {
            case "connect":
                String address = call.argument("address");
                connect(address, result);
                break;
            case "disconnect":
                disconnect(result);
                break;
            case "isConnected":
                boolean connected = uhfble.getConnectStatus() == ConnectionStatus.CONNECTED;
                result.success(connected);
                break;
            default:
                result.notImplemented();
        }
    }

    private void connect(String address, MethodChannel.Result result) {
        if (address == null || address.isEmpty()) {
            if (result != null) result.error("no_address", "Address required", null);
            return;
        }

        uhfble.connect(address, new ConnectionStatusCallback() {
            @Override
            public void getStatus(ConnectionStatus status, Object data) {
                Map<String, Object> event = new HashMap<>();
                switch (status) {
                    case CONNECTED:
                        event.put("type", "connected");
                        if (result != null) result.success(null);
                        break;
                    case DISCONNECTED:
                        event.put("type", "disconnected");
                        if (result != null) result.success(null);
                        break;
                    default:
                        event.put("type", "connect_failed");
                        break;
                }
                if (eventSink != null) eventSink.success(event);
            }
        });
    }

    private void disconnect(MethodChannel.Result result) {
        if (uhfble != null && uhfble.getConnectStatus() == ConnectionStatus.CONNECTED) {
            uhfble.disconnect();
        }
        if (eventSink != null) eventSink.success(createEvent("disconnected"));
        if (result != null) result.success(null);
    }

    @Override
    public void onListen(Object arguments, EventChannel.EventSink events) {
        this.eventSink = events;
    }

    @Override
    public void onCancel(Object arguments) {
        this.eventSink = null;
    }

    private Map<String, Object> createEvent(String type) {
        Map<String, Object> event = new HashMap<>();
        event.put("type", type);
        return event;
    }
}
