package com.example.paralled_data.connect_bluetooth;

import android.content.pm.PackageManager;
import android.content.Intent;
import android.Manifest;
import android.bluetooth.BluetoothAdapter;
import android.os.Build;
import android.util.Log;

import androidx.core.app.ActivityCompat;
import android.app.Activity;
import androidx.core.app.ActivityCompat;
import android.location.LocationManager;
import android.content.Context;


public class Connections {

    public static void requestBluetoothPermissions(Activity activity, int requestCode) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) { 
            ActivityCompat.requestPermissions(activity, new String[]{
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_CONNECT,
                    Manifest.permission.ACCESS_FINE_LOCATION
            }, requestCode);
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) { 
            ActivityCompat.requestPermissions(activity, new String[]{
                    Manifest.permission.BLUETOOTH,
                    Manifest.permission.BLUETOOTH_ADMIN,
                    Manifest.permission.ACCESS_FINE_LOCATION
            }, requestCode);
        }
    }

    // The result handling method requires Bluetooth permission
    public static void handleBluetoothPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {

        Log.d("Connections", "Request Code: " + requestCode);
        for (int i = 0; i < permissions.length; i++) {
            if (grantResults[i] == PackageManager.PERMISSION_GRANTED) {
                Log.d("Connections", permissions[i] + " granted.");
            } else {
                Log.d("Connections", permissions[i] + " denied.");
            }
        }
    }

    // Method to check Bluetooth status and request Bluetooth to be turned on if necessary
    public static void checkAndEnableBluetooth(Activity activity, int requestCode) {
        BluetoothAdapter bluetoothAdapter = BluetoothAdapter.getDefaultAdapter();
        if (bluetoothAdapter == null) {
            Log.d("Connections", "Bluetooth is not supported on this device.");
            return;
        }
        if (!bluetoothAdapter.isEnabled()) {
            Intent enableBtIntent = new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE);
            activity.startActivityForResult(enableBtIntent, requestCode);
        }
    }

    // Method that requests Location permission
    public static void requestLocationPermissions(Activity activity, int requestCode) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) { //Android 10 or higher
            ActivityCompat.requestPermissions(activity, new String[]{
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_BACKGROUND_LOCATION
            }, requestCode);
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) { // Android 6.0 or higher
            ActivityCompat.requestPermissions(activity, new String[]{
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION
            }, requestCode);
        }
    }

    // The result handling method requires Location permission
    public static void handleLocationPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        Log.d("Connections", "Request Code: " + requestCode);
        for (int i = 0; i < permissions.length; i++) {
            if (grantResults[i] == PackageManager.PERMISSION_GRANTED) {
                Log.d("Connections", permissions[i] + " granted.");
            } else {
                Log.d("Connections", permissions[i] + " denied.");
            }
        }
    }

    // Method to check and request to enable Location service
    public static void checkAndEnableLocation(Activity activity, int requestCode) {
        LocationManager locationManager = (LocationManager) activity.getSystemService(Context.LOCATION_SERVICE);
        if (!locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
            Intent enableLocationIntent = new Intent(android.provider.Settings.ACTION_LOCATION_SOURCE_SETTINGS);
            activity.startActivityForResult(enableLocationIntent, requestCode);
        }
    }
}

