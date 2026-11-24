// ble_link.h — NimBLE GATT server: TELEMETRY/STATUS notifications + COMMAND writes.
#pragma once
#include <Arduino.h>
#include <stdint.h>
#include <stddef.h>

struct BleCommand {
  uint8_t opcode;
  uint8_t payload[8];
  uint8_t len;
};

// Init NimBLE, create the service/characteristics, advertise name + service
// UUID, and request MTU 247 (the 29-byte telemetry packet needs the larger
// negotiated MTU).
void bleBegin();

// Drain one queued COMMAND (NimBLE callbacks run in another task; commands are
// pushed to a FreeRTOS queue and applied in loop() context). Returns false
// when the queue is empty.
bool blePopCommand(BleCommand& out);

bool bleConnected();
bool bleNotifyTelemetry(const uint8_t* data, size_t len);
bool bleNotifyStatus(const uint8_t* data, size_t len);
bool bleNotifyCalInfo(const uint8_t* data, size_t len);   // CAL_INFO read+notify

uint8_t bleGetHand();
void bleSetHand(uint8_t h);   // updates NVS + the telemetry hand byte
String bleDeviceName();       // "TALKHIMIK-L" / "TALKHIMIK-R"
