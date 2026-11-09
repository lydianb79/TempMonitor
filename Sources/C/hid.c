// hid.c — Apple Silicon temperature sensors exposed through the IOHID event system.
// These functions are exported by IOKit.framework but not declared in the public SDK headers.
#include "sensors.h"

#include <CoreFoundation/CoreFoundation.h>
#include <string.h>

extern CFTypeRef   IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int         IOHIDEventSystemClientSetMatching(CFTypeRef client, CFDictionaryRef match);
extern CFArrayRef  IOHIDEventSystemClientCopyServices(CFTypeRef client);
extern CFTypeRef   IOHIDServiceClientCopyEvent(CFTypeRef service, int64_t type, int32_t options, int64_t timestamp);
extern CFStringRef IOHIDServiceClientCopyProperty(CFTypeRef service, CFStringRef key);
extern double      IOHIDEventGetFloatValue(CFTypeRef event, int32_t field);

#define kHIDPage_AppleVendor              0xff00
#define kHIDUsage_AppleVendor_TempSensor  0x0005
#define kIOHIDEventTypeTemperature        15
#define IOHIDEventFieldBase(type)         ((type) << 16)

static CFTypeRef  g_client   = NULL;
static CFArrayRef g_services = NULL;

static void setup(void) {
    if (g_client) return;
    g_client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!g_client) return;

    int page = kHIDPage_AppleVendor, usage = kHIDUsage_AppleVendor_TempSensor;
    CFNumberRef nPage  = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef nUsage = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[] = { nPage, nUsage };
    CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 2,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(g_client, match);
    CFRelease(match); CFRelease(nPage); CFRelease(nUsage);
    g_services = IOHIDEventSystemClientCopyServices(g_client);
}

int tm_hid_read(TMHIDSensor *buffer, int capacity) {
    setup();
    if (!g_services) return 0;
    int written = 0;
    CFIndex count = CFArrayGetCount(g_services);
    for (CFIndex i = 0; i < count && written < capacity; i++) {
        CFTypeRef svc = CFArrayGetValueAtIndex(g_services, i);
        if (!svc) continue;
        CFTypeRef event = IOHIDServiceClientCopyEvent(svc, kIOHIDEventTypeTemperature, 0, 0);
        if (!event) continue;
        double value = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
        CFRelease(event);

        TMHIDSensor *s = &buffer[written];
        memset(s->name, 0, sizeof s->name);
        CFStringRef name = IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
        if (name) {
            CFStringGetCString(name, s->name, sizeof s->name, kCFStringEncodingUTF8);
            CFRelease(name);
        } else {
            strncpy(s->name, "Sensor", sizeof s->name - 1);
        }
        s->value = value;
        written++;
    }
    return written;
}
