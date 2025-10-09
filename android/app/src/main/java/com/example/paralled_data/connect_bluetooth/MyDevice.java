package com.example.paralled_data.connect_bluetooth;

public class MyDevice {
    private String address;
    private String name;
    private int bondState;

    public MyDevice() {

    }

    public MyDevice(String address, String name) {
        this.address = address;
        this.name = name;
    }

    public String getAddress() {
        return address;
    }

    public void setAddress(String address) {
        this.address = address;
    }

    public String getName() {
        return name;
    }

    public void setName(String name) {
        this.name = name;
    }

    public int getBondState() {
        return bondState;
    }

    public void setBondState(int bondState) {
        this.bondState = bondState;
    }
}