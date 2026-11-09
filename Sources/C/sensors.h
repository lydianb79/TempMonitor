// sensors.h — tiny C layer for reading Mac temperature sensors.
// Used as the Swift bridging header (swiftc -import-objc-header).
#ifndef TEMPMONITOR_SENSORS_H
#define TEMPMONITOR_SENSORS_H

#include <stdint.h>

// ---- SMC (System Management Controller) — Intel and Apple Silicon ----
int  tm_smc_open(void);                         // 1 on success
void tm_smc_close(void);
int  tm_smc_key_count(void);                    // number of SMC keys (0 on failure)
int  tm_smc_key_at(int index, char *out5);      // writes 4-char key + NUL, 1 on success
int  tm_smc_read(const char *key, double *out); // decodes flt / sp78 / fpe2 / ui*; 1 on success

// ---- IOHID temperature services — Apple Silicon ----
typedef struct {
    char   name[64];
    double value;
} TMHIDSensor;

int tm_hid_read(TMHIDSensor *buffer, int capacity); // returns number of sensors written

#endif
