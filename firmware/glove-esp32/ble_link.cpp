#include "ble_link.h"
#include "config.h"
#include <string>
#include <NimBLEDevice.h>
#include <Preferences.h>
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

static NimBLEServer* pServer = nullptr;
static NimBLEAdvertising* pAdv = nullptr;
static NimBLECharacteristic* pTeleChar = nullptr;
static NimBLECharacteristic* pCmdChar = nullptr;
static NimBLECharacteristic* pStatusChar = nullptr;
static NimBLECharacteristic* pCalInfoChar = nullptr;
static QueueHandle_t cmdQueue = nullptr;
static uint8_t hand = HAND_DEFAULT;
static bool connected = false;

String bleDeviceName() {
  return String(DEVICE_NAME_PREFIX) + (hand ? "-R" : "-L");
}

static void loadHandFromNVS() {
  Preferences p;
  p.begin("talkhimik", true);
  hand = p.getUChar("hand", HAND_DEFAULT) & 0x01;
  p.end();
}

// One central per glove: advertising stops on connect and restarts on
// disconnect, so a walk-away/back re-pairs automatically.
class GloveServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* s, NimBLEConnInfo& info) override {
    connected = true;
    if (pAdv) pAdv->stop();
    Serial.println("[ble] central connected");
  }
  void onDisconnect(NimBLEServer* s, NimBLEConnInfo& info, int reason) override {
    connected = false;
    if (pAdv) pAdv->start();
    Serial.printf("[ble] central disconnected (reason %d) - re-advertising\n", reason);
  }
};

// COMMAND writes arrive in the NimBLE host task; push them to a queue and let
// loop() apply them (keeps all shared state single-threaded).
// (NimBLE 2.x signature: onWrite takes the connection info as a second arg.)
class GloveCmdCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pChr, NimBLEConnInfo& connInfo) override {
    NimBLEAttValue v = pChr->getValue();
    if (v.size() < 1) return;
    BleCommand cmd = {};
    cmd.opcode = (uint8_t)v[0];
    cmd.len = v.size() - 1;
    if (cmd.len > sizeof(cmd.payload)) cmd.len = sizeof(cmd.payload);
    if (cmd.len) memcpy(cmd.payload, v.data() + 1, cmd.len);
    if (cmdQueue) xQueueSend(cmdQueue, &cmd, 0);   // non-blocking
  }
};

void bleBegin() {
  loadHandFromNVS();
  NimBLEDevice::init(bleDeviceName().c_str());
  NimBLEDevice::setMTU(247);      // negotiate the larger MTU up front

  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new GloveServerCallbacks());

  NimBLEService* svc = pServer->createService(SERVICE_UUID);
  pTeleChar = svc->createCharacteristic(TELEMETRY_CHAR_UUID,
                                        NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  pCmdChar = svc->createCharacteristic(COMMAND_CHAR_UUID,
                                       NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  pCmdChar->setCallbacks(new GloveCmdCallbacks());
  pStatusChar = svc->createCharacteristic(STATUS_CHAR_UUID,
                                          NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  pCalInfoChar = svc->createCharacteristic(CAL_INFO_CHAR_UUID,
                                           NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  svc->start();

  pAdv = NimBLEDevice::getAdvertising();
  pAdv->setName(std::string(bleDeviceName().c_str()));
  pAdv->addServiceUUID(SERVICE_UUID);
  pAdv->start();

  cmdQueue = xQueueCreate(8, sizeof(BleCommand));
  Serial.printf("[ble] advertising as %s\n", bleDeviceName().c_str());
}

bool blePopCommand(BleCommand& out) {
  return cmdQueue && xQueueReceive(cmdQueue, &out, 0) == pdTRUE;
}

bool bleConnected() { return connected; }

bool bleNotifyTelemetry(const uint8_t* data, size_t len) {
  return pTeleChar && connected && pTeleChar->notify(data, len);
}

bool bleNotifyStatus(const uint8_t* data, size_t len) {
  return pStatusChar && connected && pStatusChar->notify(data, len);
}

bool bleNotifyCalInfo(const uint8_t* data, size_t len) {
  if (!pCalInfoChar) return false;
  pCalInfoChar->setValue(data, len);   // store for READ even while disconnected
  return connected && pCalInfoChar->notify();
}

uint8_t bleGetHand() { return hand; }

void bleSetHand(uint8_t h) {
  hand = h & 0x01;
  Preferences p;
  p.begin("talkhimik", false);
  p.putUChar("hand", hand);
  p.end();
  Serial.printf("[ble] hand set to %d (advertised name updates on reboot)\n", hand);
}
