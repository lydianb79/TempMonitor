// smc.c — read-only access to the AppleSMC user client.
#include "sensors.h"

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <string.h>

#define KERNEL_INDEX_SMC       2
#define SMC_CMD_READ_BYTES     5
#define SMC_CMD_READ_INDEX     8
#define SMC_CMD_READ_KEYINFO   9

typedef struct {
    char     major;
    char     minor;
    char     build;
    char     reserved[1];
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char     dataAttributes;
} SMCKeyInfo;

typedef struct {
    uint32_t      key;
    SMCVersion    vers;
    SMCPLimitData pLimitData;
    SMCKeyInfo    keyInfo;
    char          result;
    char          status;
    char          data8;
    uint32_t      data32;
    unsigned char bytes[32];
} SMCKeyData;

static io_connect_t g_conn = 0;

// Small cache of key -> (size,type) so each poll needs one call per key.
#define CACHE_SIZE 512
static struct { uint32_t key; SMCKeyInfo info; } g_cache[CACHE_SIZE];
static int g_cache_count = 0;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(unsigned char)s[0] << 24) | ((uint32_t)(unsigned char)s[1] << 16) |
           ((uint32_t)(unsigned char)s[2] << 8)  |  (uint32_t)(unsigned char)s[3];
}

static void fourcc_str(uint32_t k, char *out) {
    out[0] = (char)(k >> 24); out[1] = (char)(k >> 16);
    out[2] = (char)(k >> 8);  out[3] = (char)k; out[4] = 0;
}

static int smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    kern_return_t kr = IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC,
                                                 in, sizeof(SMCKeyData), out, &outSize);
    return kr == KERN_SUCCESS && out->result == 0;
}

int tm_smc_open(void) {
    if (g_conn) return 1;
    io_service_t svc = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("AppleSMC"));
    if (!svc) return 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) { g_conn = 0; return 0; }
    return 1;
}

void tm_smc_close(void) {
    if (g_conn) { IOServiceClose(g_conn); g_conn = 0; }
}

static int key_info(uint32_t key, SMCKeyInfo *info) {
    for (int i = 0; i < g_cache_count; i++)
        if (g_cache[i].key == key) { *info = g_cache[i].info; return 1; }
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (!smc_call(&in, &out)) return 0;
    *info = out.keyInfo;
    if (g_cache_count < CACHE_SIZE) {
        g_cache[g_cache_count].key = key;
        g_cache[g_cache_count].info = out.keyInfo;
        g_cache_count++;
    }
    return 1;
}

static int read_raw(const char *k, SMCKeyInfo *info, unsigned char *bytes) {
    if (!g_conn || !k || strlen(k) != 4) return 0;
    uint32_t key = fourcc(k);
    if (!key_info(key, info)) return 0;
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key;
    in.keyInfo.dataSize = info->dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    if (!smc_call(&in, &out)) return 0;
    memcpy(bytes, out.bytes, 32);
    return 1;
}

int tm_smc_read(const char *k, double *value) {
    SMCKeyInfo info;
    unsigned char b[32];
    if (!read_raw(k, &info, b)) return 0;
    char type[5]; fourcc_str(info.dataType, type);
    uint32_t n = info.dataSize;

    if (!strcmp(type, "flt ") && n == 4) {         // Apple Silicon: little-endian float
        float f; memcpy(&f, b, 4); *value = f; return 1;
    }
    if (!strcmp(type, "sp78") && n == 2) {         // signed 8.8 fixed point (Intel temps)
        int16_t v = (int16_t)((b[0] << 8) | b[1]); *value = v / 256.0; return 1;
    }
    if (!strcmp(type, "sp87") && n == 2) {
        int16_t v = (int16_t)((b[0] << 8) | b[1]); *value = v / 128.0; return 1;
    }
    if (!strcmp(type, "fpe2") && n == 2) {
        *value = ((b[0] << 8) | b[1]) / 4.0; return 1;
    }
    if (!strcmp(type, "ui8 ") && n >= 1) { *value = b[0]; return 1; }
    if (!strcmp(type, "ui16") && n >= 2) { *value = (b[0] << 8) | b[1]; return 1; }
    if (!strcmp(type, "ui32") && n >= 4) {
        *value = (double)(((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3]);
        return 1;
    }
    return 0;
}

int tm_smc_key_count(void) {
    double v = 0;
    if (!tm_smc_read("#KEY", &v)) return 0;
    return (int)v;
}

int tm_smc_key_at(int index, char *out5) {
    if (!g_conn) return 0;
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = (uint32_t)index;
    if (!smc_call(&in, &out)) return 0;
    fourcc_str(out.key, out5);
    return 1;
}
