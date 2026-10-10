#include "NativeTemperature.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Private HID event APIs. Apple defines IOHIDFloat as double on LP64, not float:
// https://github.com/apple-oss-distributions/IOHIDFamily/blob/IOHIDFamily-701.60.2/IOHIDFamily/IOHIDEventTypes.h
// The CopyEvent scalar ABI is also used by Chromium's m1_sensors_mac.mm.
// Only temperature type 15 and zero matching/options arguments are used here.
typedef IOHIDEventSystemClientRef (*HIDCreate)(CFAllocatorRef);
typedef int (*HIDSetMatching)(IOHIDEventSystemClientRef, CFDictionaryRef);
typedef CFTypeRef (*HIDCopyEvent)(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
typedef double (*HIDGetFloatValue)(CFTypeRef, uint32_t);
typedef uint32_t (*HIDGetEventType)(CFTypeRef);

// AppleSMC's native user-client structure (selector 2; commands 9 and 5 only).
// Read-only ABI reference: https://github.com/exelban/stats/blob/master/SMC/smc.swift
// Use C layout, not Swift nested-struct layout or a packed structure.
typedef struct {
    uint32_t key;
    struct { uint8_t major, minor, build, reserved; uint16_t release; } version;
    struct { uint16_t version, length; uint32_t cpu, gpu, memory; } limits;
    struct { uint32_t size, type; uint8_t attributes; } info;
    uint8_t result, status, command;
    uint32_t index;
    uint8_t bytes[32];
} SMCData;

_Static_assert(sizeof(SMCData) == 80, "AppleSMC structure size");
_Static_assert(offsetof(SMCData, info) == 28, "AppleSMC key-info offset");
_Static_assert(offsetof(SMCData, result) == 40, "AppleSMC result offset");
_Static_assert(offsetof(SMCData, command) == 42, "AppleSMC command offset");
_Static_assert(offsetof(SMCData, index) == 44, "AppleSMC index offset");
_Static_assert(offsetof(SMCData, bytes) == 48, "AppleSMC data offset");

// Physical die-temperature keys, observed on this M5 and corroborated by
// Stats' temperature sensor mappings. Missing keys are simply not exposed.
// Raw key labels deliberately do not guess CPU/GPU/core identity. In particular,
// do not enumerate every T* key: virtual TV*, calibration and dummy Tz* keys exist.
static const char *const dieKeys[] = {
    "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R",
    "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p",
    "Tp0u", "Tp0y", "Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y",
    "Tg1c", "Tg1g"
};

typedef struct {
    char name[128];
    char identifier[40];
    size_t hidIndex;
    uint32_t smcKey, smcSize, smcType;
    bool physical;
} TemperatureSensor;

struct UMTemperatureClient {
    void *library;
    IOHIDEventSystemClientRef hid;
    CFArrayRef services;
    HIDCopyEvent copyEvent;
    HIDGetFloatValue getFloatValue;
    HIDGetEventType getEventType;
    io_connect_t smc;
    TemperatureSensor *sensors;
    size_t count, capacity;
};

static uint32_t fourCC(const char *key) {
    return (uint32_t)(uint8_t)key[0] << 24 | (uint32_t)(uint8_t)key[1] << 16 |
           (uint32_t)(uint8_t)key[2] << 8 | (uint32_t)(uint8_t)key[3];
}

bool UMTemperatureDecodeSMC(uint32_t dataType, const uint8_t *bytes, size_t count, double *celsius) {
    double value;
    if (dataType == fourCC("flt ") && count == 4) {
        // Apple Silicon SMC flt payloads are native little-endian IEEE754.
        // memcpy handles potentially unaligned byte buffers without aliasing UB.
        float nativeValue;
        memcpy(&nativeValue, bytes, sizeof(nativeValue));
        value = nativeValue;
    } else if (dataType == fourCC("sp78") && count == 2) {
        uint16_t bits = (uint16_t)bytes[0] << 8 | bytes[1];
        int32_t signedValue = bits >= 0x8000 ? (int32_t)bits - 0x10000 : bits;
        value = (double)signedValue / 256.0;
    } else {
        return false;
    }
    if (!isfinite(value)) return false;
    *celsius = value;
    return true;
}

static bool callSMC(io_connect_t connection, const SMCData *input, SMCData *output) {
    size_t size = sizeof(*output);
    kern_return_t result = IOConnectCallStructMethod(connection, 2, input, sizeof(*input), output, &size);
    return result == KERN_SUCCESS && size == sizeof(*output) && output->result == 0;
}

static bool readSMC(UMTemperatureClient *client, const TemperatureSensor *sensor, double *celsius) {
    SMCData input = {0}, output = {0};
    input.key = sensor->smcKey;
    input.info.size = sensor->smcSize;
    input.command = 5;
    if (!callSMC(client->smc, &input, &output)) return false;
    return UMTemperatureDecodeSMC(sensor->smcType, output.bytes, sensor->smcSize, celsius);
}

static void openHID(UMTemperatureClient *client) {
    client->library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    if (!client->library) return;
    HIDCreate create = (HIDCreate)dlsym(client->library, "IOHIDEventSystemClientCreate");
    HIDSetMatching setMatching = (HIDSetMatching)dlsym(client->library, "IOHIDEventSystemClientSetMatching");
    client->copyEvent = (HIDCopyEvent)dlsym(client->library, "IOHIDServiceClientCopyEvent");
    client->getFloatValue = (HIDGetFloatValue)dlsym(client->library, "IOHIDEventGetFloatValue");
    client->getEventType = (HIDGetEventType)dlsym(client->library, "IOHIDEventGetType");
    if (!create || !setMatching || !client->copyEvent || !client->getFloatValue || !client->getEventType) return;
    client->hid = create(kCFAllocatorDefault);
    if (!client->hid) return;
    int pageValue = 0xff00, usageValue = 5;
    CFNumberRef page = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pageValue);
    CFNumberRef usage = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usageValue);
    if (page && usage) {
        const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
        const void *values[] = {page, usage};
        CFDictionaryRef matching = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                                      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (matching) {
            setMatching(client->hid, matching);
            CFRelease(matching);
            client->services = IOHIDEventSystemClientCopyServices(client->hid);
        }
    }
    if (page) CFRelease(page);
    if (usage) CFRelease(usage);
}

static void openSMC(UMTemperatureClient *client) {
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSMC");
    if (!matching) return;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching); // Consumes matching.
    if (!service) return;
    io_connect_t connection = 0;
    if (IOServiceOpen(service, mach_task_self(), 0, &connection) == KERN_SUCCESS) client->smc = connection;
    IOObjectRelease(service);
}

static void addHIDSensors(UMTemperatureClient *client, size_t count) {
    for (size_t index = 0; index < count; ++index) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(client->services, (CFIndex)index);
        CFTypeRef builtIn = IOHIDServiceClientCopyProperty(service, CFSTR("Built-In"));
        bool isInternal = builtIn && CFGetTypeID(builtIn) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)builtIn);
        if (builtIn) CFRelease(builtIn);
        if (!isInternal) continue;
        CFTypeRef product = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        TemperatureSensor *sensor = &client->sensors[client->count];
        bool hasName = product && CFGetTypeID(product) == CFStringGetTypeID() &&
                       CFStringGetCString((CFStringRef)product, sensor->name, sizeof(sensor->name), kCFStringEncodingUTF8) &&
                       sensor->name[0] != '\0';
        if (product) CFRelease(product);
        if (!hasName) snprintf(sensor->name, sizeof(sensor->name), "Unnamed HID temperature service");
        // GetRegistryID is borrowed, unlike CopyProperty and CopyEvent.
        CFTypeRef identifier = IOHIDServiceClientGetRegistryID(service);
        int64_t registryID = 0;
        if (!identifier || CFGetTypeID(identifier) != CFNumberGetTypeID() ||
            !CFNumberGetValue((CFNumberRef)identifier, kCFNumberSInt64Type, &registryID) || registryID <= 0) continue;
        snprintf(sensor->identifier, sizeof(sensor->identifier), "hid:%llu", (unsigned long long)registryID);
        sensor->hidIndex = index;
        sensor->physical = true;
        ++client->count;
    }
}

static bool addSMCSensors(UMTemperatureClient *client) {
    if (!client->smc) return true;
    SMCData input = {0}, output = {0};
    input.key = fourCC("#KEY");
    input.command = 9;
    if (!callSMC(client->smc, &input, &output) || output.info.size != 4 || output.info.type != fourCC("ui32")) return true;
    input.info.size = 4;
    input.command = 5;
    memset(&output, 0, sizeof(output));
    if (!callSMC(client->smc, &input, &output)) return true;
    uint32_t keyCount = (uint32_t)output.bytes[0] << 24 | (uint32_t)output.bytes[1] << 16 |
                        (uint32_t)output.bytes[2] << 8 | output.bytes[3];
    if (keyCount > 65536) return true;
    for (uint32_t index = 0; index < keyCount; ++index) {
        memset(&input, 0, sizeof(input));
        memset(&output, 0, sizeof(output));
        input.command = 8; // Read key at index; never writes a setting.
        input.index = index;
        if (!callSMC(client->smc, &input, &output) || (output.key >> 24) != 'T') continue;
        uint32_t key = output.key;
        if (client->count == client->capacity) {
            size_t capacity = client->capacity * 2;
            TemperatureSensor *sensors = realloc(client->sensors, capacity * sizeof(*sensors));
            if (!sensors) return false;
            client->sensors = sensors;
            client->capacity = capacity;
        }
        TemperatureSensor *sensor = &client->sensors[client->count];
        memset(sensor, 0, sizeof(*sensor));
        char keyName[] = {(char)(key >> 24), (char)(key >> 16), (char)(key >> 8), (char)key, '\0'};
        sensor->smcKey = key;
        snprintf(sensor->name, sizeof(sensor->name), "SMC %s", keyName);
        snprintf(sensor->identifier, sizeof(sensor->identifier), "smc:%s", keyName);
        for (size_t candidate = 0; candidate < sizeof(dieKeys) / sizeof(dieKeys[0]); ++candidate) {
            if (key == fourCC(dieKeys[candidate])) {
                sensor->physical = true;
                break;
            }
        }
        memset(&input, 0, sizeof(input));
        memset(&output, 0, sizeof(output));
        input.key = key;
        input.command = 9;
        if (callSMC(client->smc, &input, &output)) {
            sensor->smcSize = output.info.size;
            sensor->smcType = output.info.type;
        }
        ++client->count; // Even a blocked/unknown channel retains an honest status.
    }
    return true;
}

UMTemperatureClient *UMTemperatureClientCreate(int32_t *status) {
    *status = UMTemperatureAllocationFailed;
    UMTemperatureClient *client = calloc(1, sizeof(*client));
    if (!client) return NULL;
    openHID(client);
    openSMC(client);
    if (!client->hid && !client->smc) {
        *status = UMTemperatureInterfacesUnavailable;
        UMTemperatureClientDestroy(client);
        return NULL;
    }
    size_t hidCount = client->services ? (size_t)CFArrayGetCount(client->services) : 0;
    client->capacity = hidCount + sizeof(dieKeys) / sizeof(dieKeys[0]);
    client->sensors = calloc(client->capacity, sizeof(*client->sensors));
    if (!client->sensors) {
        UMTemperatureClientDestroy(client);
        return NULL;
    }
    addHIDSensors(client, hidCount);
    if (!addSMCSensors(client)) {
        UMTemperatureClientDestroy(client);
        return NULL;
    }
    if (!client->count) {
        *status = UMTemperatureSensorsUnavailable;
        UMTemperatureClientDestroy(client);
        return NULL;
    }
    *status = UMTemperatureSuccess;
    return client;
}

void UMTemperatureClientDestroy(UMTemperatureClient *client) {
    if (client->services) CFRelease(client->services);
    if (client->hid) CFRelease(client->hid);
    if (client->smc) IOServiceClose(client->smc);
    if (client->library) dlclose(client->library);
    free(client->sensors);
    free(client);
}

size_t UMTemperatureClientGetSensorCount(const UMTemperatureClient *client) {
    return client->count;
}

const char *UMTemperatureClientGetSensorName(const UMTemperatureClient *client, size_t index) {
    return index < client->count ? client->sensors[index].name : NULL;
}

const char *UMTemperatureClientGetSensorID(const UMTemperatureClient *client, size_t index) {
    return index < client->count ? client->sensors[index].identifier : NULL;
}

bool UMTemperatureClientIsPhysicalSensor(const UMTemperatureClient *client, size_t index) {
    return index < client->count && client->sensors[index].physical;
}

bool UMTemperatureClientReadSensor(UMTemperatureClient *client, size_t index, double *celsius) {
    if (index >= client->count) return false;
    const TemperatureSensor *sensor = &client->sensors[index];
    if (sensor->smcKey) return readSMC(client, sensor, celsius);
    IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(client->services, (CFIndex)sensor->hidIndex);
    CFTypeRef event = client->copyEvent(service, 15, 0, 0);
    if (!event) return false;
    bool isTemperature = client->getEventType(event) == 15;
    double value = isTemperature ? client->getFloatValue(event, 15u << 16) : NAN;
    CFRelease(event);
    if (!isfinite(value)) return false;
    *celsius = value;
    return true;
}

struct UMSMCClient { io_connect_t connection; };

static int32_t transferSMC(io_connect_t connection, const SMCData *input, SMCData *output) {
    size_t size = sizeof(*output);
    kern_return_t result = IOConnectCallStructMethod(connection, 2, input, sizeof(*input), output, &size);
    if (result != KERN_SUCCESS) return result;
    if (size != sizeof(*output)) return kIOReturnUnderrun;
    return output->result == 0 ? KERN_SUCCESS : kIOReturnError;
}

UMSMCClient *UMSMCClientCreate(int32_t *status) {
    *status = kIOReturnNotFound;
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSMC");
    if (!matching) return NULL;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service) return NULL;
    io_connect_t connection = 0;
    *status = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (*status != KERN_SUCCESS) return NULL;
    UMSMCClient *client = calloc(1, sizeof(*client));
    if (!client) {
        IOServiceClose(connection);
        *status = kIOReturnNoMemory;
        return NULL;
    }
    client->connection = connection;
    return client;
}

void UMSMCClientDestroy(UMSMCClient *client) {
    IOServiceClose(client->connection);
    free(client);
}

int32_t UMSMCClientGetKeyInfo(UMSMCClient *client, uint32_t key, UMSMCValue *value) {
    SMCData input = {0}, output = {0};
    memset(value, 0, sizeof(*value));
    value->key = key;
    input.key = key;
    input.command = 9;
    int32_t result = transferSMC(client->connection, &input, &output);
    value->firmwareResult = output.result;
    if (result != KERN_SUCCESS) return result;
    value->dataType = output.info.type;
    value->dataSize = output.info.size;
    return value->dataSize <= sizeof(value->bytes) ? KERN_SUCCESS : kIOReturnUnsupported;
}

int32_t UMSMCClientReadValue(UMSMCClient *client, UMSMCValue *value) {
    memset(value->bytes, 0, sizeof(value->bytes));
    if (value->dataSize == 0 || value->dataSize > sizeof(value->bytes)) return kIOReturnBadArgument;
    SMCData input = {0}, output = {0};
    input.key = value->key;
    input.info.size = value->dataSize;
    input.command = 5;
    int32_t result = transferSMC(client->connection, &input, &output);
    value->firmwareResult = output.result;
    if (result == KERN_SUCCESS) memcpy(value->bytes, output.bytes, value->dataSize);
    return result;
}

int32_t UMSMCClientGetKeyAtIndex(UMSMCClient *client, uint32_t index, uint32_t *key) {
    SMCData input = {0}, output = {0};
    input.command = 8;
    input.index = index;
    int32_t result = transferSMC(client->connection, &input, &output);
    if (result == KERN_SUCCESS) *key = output.key;
    return result;
}

int32_t UMSMCClientGetKeyCount(UMSMCClient *client, uint32_t *count) {
    UMSMCValue value;
    int32_t result = UMSMCClientGetKeyInfo(client, fourCC("#KEY"), &value);
    if (result != KERN_SUCCESS) return result;
    if (value.dataType != fourCC("ui32") || value.dataSize != 4) return kIOReturnBadArgument;
    result = UMSMCClientReadValue(client, &value);
    if (result != KERN_SUCCESS) return result;
    *count = (uint32_t)value.bytes[0] << 24 | (uint32_t)value.bytes[1] << 16 |
             (uint32_t)value.bytes[2] << 8 | value.bytes[3];
    return *count <= 65536 ? KERN_SUCCESS : kIOReturnBadArgument;
}

static int hexDigit(uint8_t c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

bool UMSMCDecodeNumber(uint32_t dataType, const uint8_t *bytes, size_t count, double *value) {
    if (UMTemperatureDecodeSMC(dataType, bytes, count, value)) return true;
    if (count == 1 && (dataType == fourCC("ui8 ") || dataType == fourCC("flag"))) {
        *value = bytes[0];
        return true;
    }
    if (count == 1 && dataType == fourCC("si8 ")) {
        *value = bytes[0] >= 128 ? (int)bytes[0] - 256 : bytes[0];
        return true;
    }
    bool unsignedInteger = (count == 2 && dataType == fourCC("ui16")) || (count == 4 && dataType == fourCC("ui32"));
    bool signedInteger = (count == 2 && dataType == fourCC("si16")) || (count == 4 && dataType == fourCC("si32"));
    bool fixed = count == 2 && (dataType >> 16 == fourCC("fp  ") >> 16 || dataType >> 16 == fourCC("sp  ") >> 16);
    if (!unsignedInteger && !signedInteger && !fixed) return false;
    uint32_t bits = 0;
    for (size_t i = 0; i < count; ++i) bits = (bits << 8) | bytes[i];
    int64_t signedValue = bits;
    if (signedInteger && (bits & (1u << (count * 8 - 1)))) signedValue -= (int64_t)1 << (count * 8);
    if (fixed) {
        bool isSigned = (dataType >> 16) == (fourCC("sp  ") >> 16);
        int integral = hexDigit((uint8_t)(dataType >> 8)), fractional = hexDigit((uint8_t)dataType);
        if (integral < 0 || fractional < 0 || integral + fractional != (isSigned ? 15 : 16)) return false;
        if (isSigned && bits >= 0x8000) signedValue -= 65536;
        *value = (double)signedValue / (double)(1u << fractional);
    } else *value = (double)signedValue;
    return isfinite(*value);
}
