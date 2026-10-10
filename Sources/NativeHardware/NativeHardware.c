#include "NativeHardware.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/graphics/IOGraphicsLib.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <IOKit/hid/IOHIDElement.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// IOHIDFloat is double on LP64; CopyEvent uses these scalar argument widths.
// https://github.com/apple-oss-distributions/IOHIDFamily/blob/IOHIDFamily-701.60.2/IOHIDFamily/IOHIDEventTypes.h
// https://chromium.googlesource.com/chromium/src/+/refs/tags/120.0.6099.321/components/power_metrics/m1_sensors_mac.mm
typedef IOHIDEventSystemClientRef (*HIDCreate)(CFAllocatorRef);
typedef CFTypeRef (*HIDCopyEvent)(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
typedef double (*HIDFloat)(CFTypeRef, uint32_t);
typedef int64_t (*HIDInteger)(CFTypeRef, uint32_t);
typedef uint32_t (*HIDType)(CFTypeRef);

typedef struct {
    IOHIDServiceClientRef service; // Borrowed from the retained services array.
    char name[160], identifier[48];
    uint32_t page, usage;
    bool motionRestricted;
} HIDSensor;

struct UMHIDSensorClient {
    void *library;
    IOHIDEventSystemClientRef system;
    CFArrayRef services;
    HIDSensor *sensors;
    size_t count;
    HIDCopyEvent copyEvent;
    HIDFloat getFloat;
    HIDInteger getInteger;
    HIDType getType;
};

static bool number(CFTypeRef property, int64_t *value) {
    return property && CFGetTypeID(property) == CFNumberGetTypeID() &&
           CFNumberGetValue((CFNumberRef)property, kCFNumberSInt64Type, value);
}

static int64_t hidNumber(IOHIDServiceClientRef service, CFStringRef key) {
    CFTypeRef p = IOHIDServiceClientCopyProperty(service, key);
    int64_t value = 0;
    number(p, &value);
    if (p) CFRelease(p);
    return value;
}

static bool sensorUsage(uint32_t page, uint32_t usage) {
    return page == 0x20 || (page == 0xff00 && (usage == 3 || usage == 4 || usage == 5 || usage == 9)) ||
           (page == 0xff08 && (usage == 2 || usage == 3));
}

UMHIDSensorClient *UMHIDSensorClientCreate(int32_t *status) {
    if (status) *status = kIOReturnUnsupported;
    UMHIDSensorClient *c = calloc(1, sizeof(*c));
    if (!c) { if (status) *status = kIOReturnNoMemory; return NULL; }
    c->library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    if (!c->library) goto fail;
    HIDCreate create = (HIDCreate)dlsym(c->library, "IOHIDEventSystemClientCreate");
    c->copyEvent = (HIDCopyEvent)dlsym(c->library, "IOHIDServiceClientCopyEvent");
    c->getFloat = (HIDFloat)dlsym(c->library, "IOHIDEventGetFloatValue");
    c->getInteger = (HIDInteger)dlsym(c->library, "IOHIDEventGetIntegerValue");
    c->getType = (HIDType)dlsym(c->library, "IOHIDEventGetType");
    if (!create || !c->copyEvent || !c->getFloat || !c->getInteger || !c->getType) goto fail;
    c->system = create(kCFAllocatorDefault);
    if (!c->system) goto fail;
    // Enumerate metadata only, then whitelist sensor services. No input-event subscription.
    c->services = IOHIDEventSystemClientCopyServices(c->system);
    if (!c->services) { if (status) *status = kIOReturnNotPermitted; goto fail; }
    CFIndex count = CFArrayGetCount(c->services);
    c->sensors = calloc((size_t)count, sizeof(*c->sensors));
    if (count && !c->sensors) { if (status) *status = kIOReturnNoMemory; goto fail; }
    for (CFIndex i = 0; i < count; ++i) {
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(c->services, i);
        uint32_t page = (uint32_t)hidNumber(s, CFSTR("PrimaryUsagePage"));
        uint32_t usage = (uint32_t)hidNumber(s, CFSTR("PrimaryUsage"));
        if (!sensorUsage(page, usage)) continue;
        CFTypeRef builtIn = IOHIDServiceClientCopyProperty(s, CFSTR("Built-In"));
        bool internal = builtIn && CFGetTypeID(builtIn) == CFBooleanGetTypeID() &&
                        CFBooleanGetValue((CFBooleanRef)builtIn);
        if (builtIn) CFRelease(builtIn);
        if (!internal) continue;
        int64_t registryID = 0;
        if (!number(IOHIDServiceClientGetRegistryID(s), &registryID) || registryID <= 0) continue;
        HIDSensor *sensor = &c->sensors[c->count++];
        sensor->service = s; sensor->page = page; sensor->usage = usage;
        CFTypeRef restricted = IOHIDServiceClientCopyProperty(s, CFSTR("motionRestrictedService"));
        sensor->motionRestricted = restricted && CFGetTypeID(restricted) == CFBooleanGetTypeID() &&
                                   CFBooleanGetValue((CFBooleanRef)restricted);
        if (restricted) CFRelease(restricted);
        snprintf(sensor->identifier, sizeof(sensor->identifier), "hid:%llu", (unsigned long long)registryID);
        CFTypeRef product = IOHIDServiceClientCopyProperty(s, CFSTR("Product"));
        bool named = product && CFGetTypeID(product) == CFStringGetTypeID() &&
                     CFStringGetCString((CFStringRef)product, sensor->name, sizeof(sensor->name), kCFStringEncodingUTF8) &&
                     sensor->name[0];
        if (product) CFRelease(product);
        if (!named) snprintf(sensor->name, sizeof(sensor->name), "Built-in HID sensor %04X:%04X", page, usage);
    }
    if (status) *status = kIOReturnSuccess;
    return c;
fail:
    UMHIDSensorClientDestroy(c);
    return NULL;
}

void UMHIDSensorClientDestroy(UMHIDSensorClient *c) {
    if (!c) return;
    free(c->sensors);
    if (c->services) CFRelease(c->services);
    if (c->system) CFRelease(c->system);
    if (c->library) dlclose(c->library);
    free(c);
}

size_t UMHIDSensorClientGetSensorCount(UMHIDSensorClient *c) { return c ? c->count : 0; }
const char *UMHIDSensorClientGetSensorName(UMHIDSensorClient *c, size_t i) { return c && i < c->count ? c->sensors[i].name : NULL; }
const char *UMHIDSensorClientGetSensorID(UMHIDSensorClient *c, size_t i) { return c && i < c->count ? c->sensors[i].identifier : NULL; }
uint32_t UMHIDSensorClientGetUsagePage(UMHIDSensorClient *c, size_t i) { return c && i < c->count ? c->sensors[i].page : 0; }
uint32_t UMHIDSensorClientGetUsage(UMHIDSensorClient *c, size_t i) { return c && i < c->count ? c->sensors[i].usage : 0; }
bool UMHIDSensorClientIsMotionRestricted(UMHIDSensorClient *c, size_t i) { return c && i < c->count && c->sensors[i].motionRestricted; }

// Explicit fields prevent unknown/private getters from returning a misleading zero.
// Numeric accessor type follows Apple's IOHIDEvent.h/EventTypes.h declarations.
static bool validField(uint32_t type, uint32_t field, bool floating) {
    if ((field >> 16) != type) return false;
    uint32_t offset = field & 0xffff;
    switch (type) {
        case 12: return floating ? offset >= 7 && offset <= 9 : offset <= 6;
        case 13: case 20: case 21: return floating ? offset <= 2 : offset >= 3 && offset <= 5;
        case 15: case 31: return floating && offset == 0;
        case 25: return floating ? offset == 0 : offset == 1 || offset == 2;
        default: return false; // Never keyboard, vendor payload, biometric or pointer events.
    }
}

static CFTypeRef copySensorEvent(UMHIDSensorClient *c, size_t i, uint32_t type,
                                 const uint32_t *fields, size_t count, bool floating) {
    if (!c || i >= c->count || !fields || !count) return NULL;
    for (size_t j = 0; j < count; ++j) if (!validField(type, fields[j], floating)) return NULL;
    CFTypeRef event = c->copyEvent(c->sensors[i].service, (int64_t)type, 0, 0);
    if (event && c->getType(event) != type) { CFRelease(event); return NULL; }
    return event;
}

bool UMHIDSensorClientReadFloats(UMHIDSensorClient *c, size_t i, uint32_t type,
                                const uint32_t *fields, size_t count, double *values) {
    if (!values) return false;
    CFTypeRef event = copySensorEvent(c, i, type, fields, count, true);
    if (!event) return false;
    bool valid = true;
    for (size_t j = 0; j < count; ++j) {
        values[j] = c->getFloat(event, fields[j]);
        if (!isfinite(values[j])) valid = false;
    }
    CFRelease(event);
    return valid;
}

bool UMHIDSensorClientReadIntegers(UMHIDSensorClient *c, size_t i, uint32_t type,
                                  const uint32_t *fields, size_t count, int64_t *values) {
    if (!values) return false;
    CFTypeRef event = copySensorEvent(c, i, type, fields, count, false);
    if (!event) return false;
    for (size_t j = 0; j < count; ++j) values[j] = c->getInteger(event, fields[j]);
    CFRelease(event);
    return true;
}

// KeyboardBrightnessClient is an Objective-C API. Resolve runtime symbols rather
// than introducing an Objective-C source/target or capturing keyboard HID reports.
typedef void *(*ObjCClass)(const char *);
typedef void *(*ObjCSelector)(const char *);
typedef void *(*ObjCMethod)(void *, void *);
typedef const char *(*ObjCEncoding)(void *);
typedef void *(*ObjCMessage)(void *, void *);
typedef void *(*PoolPush)(void);
typedef void (*PoolPop)(void *);
typedef float (*KeyboardRead)(void *, void *, uint64_t);
typedef bool (*KeyboardBuiltIn)(void *, void *, uint64_t);
typedef int32_t (*DisplayRead)(uint32_t, float *);

typedef struct {
    uint32_t kind;
    char name[160], identifier[64];
    io_service_t service;
    IOHIDDeviceRef device;
    int32_t openStatus;
    uint64_t nativeID;
} MotionLightChannel;

struct UMMotionLightClient {
    MotionLightChannel *channels;
    size_t count, capacity;
    void *displayLibrary, *brightnessLibrary, *objcLibrary;
    DisplayRead displayRead;
    void *keyboard, *brightnessSelector, *releaseSelector;
    ObjCMessage message;
    KeyboardRead keyboardRead;
    PoolPush poolPush;
    PoolPop poolPop;
};

static MotionLightChannel *addChannel(UMMotionLightClient *c, uint32_t kind, const char *name, const char *id) {
    if (c->count == c->capacity) {
        size_t capacity = c->capacity ? c->capacity * 2 : 16;
        MotionLightChannel *channels = realloc(c->channels, capacity * sizeof(*channels));
        if (!channels) return NULL;
        c->channels = channels; c->capacity = capacity;
    }
    MotionLightChannel *channel = &c->channels[c->count++];
    memset(channel, 0, sizeof(*channel)); channel->kind = kind;
    snprintf(channel->name, sizeof(channel->name), "%s", name);
    snprintf(channel->identifier, sizeof(channel->identifier), "%s", id);
    return channel;
}

static int64_t registryNumber(io_service_t s, CFStringRef key) {
    CFTypeRef p = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    int64_t value = 0; number(p, &value); if (p) CFRelease(p); return value;
}

static bool lidDescriptor(IOHIDDeviceRef device) {
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device, NULL, 0);
    if (!elements) return false;
    bool verified = false;
    for (CFIndex i = 0; i < CFArrayGetCount(elements); ++i) {
        IOHIDElementRef e = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        // Host descriptor: sensor-page Tilt X, report1,9bits,0...360; no
        // explicit angular unit on report1. Usage semantics + range establish degrees.
        if (IOHIDElementGetType(e) == kIOHIDElementTypeInput_Misc &&
            IOHIDElementGetUsagePage(e) == 0x20 && IOHIDElementGetUsage(e) == 0x47f &&
            IOHIDElementGetReportID(e) == 1 && IOHIDElementGetReportSize(e) == 9 &&
            IOHIDElementGetLogicalMin(e) == 0 && IOHIDElementGetLogicalMax(e) == 360 &&
            IOHIDElementGetPhysicalMin(e) == 0 && IOHIDElementGetPhysicalMax(e) == 360) verified = true;
    }
    CFRelease(elements); return verified;
}

bool UMMotionLightDecodeLidReport(const uint8_t *bytes, size_t count, double *degrees) {
    if (!bytes || !degrees || count != 3 || bytes[0] != 1) return false;
    unsigned value = ((unsigned)bytes[1] | (unsigned)bytes[2] << 8) & 0x1ff;
    if (value > 360) return false;
    *degrees = (double)value; return true;
}

static void enumerateRegistry(UMMotionLightClient *c, const char *className, bool ambient) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) != KERN_SUCCESS) return;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        uint32_t page = (uint32_t)registryNumber(service, CFSTR("PrimaryUsagePage"));
        uint32_t usage = (uint32_t)registryNumber(service, CFSTR("PrimaryUsage"));
        uint32_t kind = ambient ? UMMotionLightAmbientLux : 0;
        const char *name = ambient ? "Ambient illuminance" : NULL;
        if (!ambient && page == 0x20 && usage == 0x8a) { kind = UMMotionLightLidAngle; name = "Lid angle / hinge tilt X"; }
        if (!ambient && ((page == 0xff00 && usage == 255) || page == 0xff0c)) {
            kind = UMMotionLightOpaqueService; name = "Opaque SPU service";
        }
        if (kind) {
            uint64_t registryID = 0; IORegistryEntryGetRegistryEntryID(service, &registryID);
            char id[64], label[160];
            snprintf(id, sizeof(id), "registry:%llu", (unsigned long long)registryID);
            if (kind == UMMotionLightOpaqueService) snprintf(label, sizeof(label), "%s %04X:%04X (metadata only)", name, page, usage);
            else snprintf(label, sizeof(label), "%s", name);
            MotionLightChannel *channel = addChannel(c, kind, label, id);
            if (channel) {
                channel->service = service; channel->nativeID = registryID;
                if (kind == UMMotionLightLidAngle) {
                    channel->device = IOHIDDeviceCreate(kCFAllocatorDefault, service);
                    channel->openStatus = channel->device ? IOHIDDeviceOpen(channel->device, kIOHIDOptionsTypeNone) : kIOReturnNoDevice;
                    if (channel->openStatus == kIOReturnSuccess && !lidDescriptor(channel->device)) channel->openStatus = kIOReturnUnsupported;
                }
                continue; // Retain iterator's service reference for property reads.
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
}

static void enumerateKeyboards(UMMotionLightClient *c) {
    c->brightnessLibrary = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY | RTLD_LOCAL);
    c->objcLibrary = dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!c->brightnessLibrary || !c->objcLibrary) return;
    ObjCClass getClass = (ObjCClass)dlsym(c->objcLibrary, "objc_getClass");
    ObjCSelector selector = (ObjCSelector)dlsym(c->objcLibrary, "sel_registerName");
    ObjCMethod getMethod = (ObjCMethod)dlsym(c->objcLibrary, "class_getInstanceMethod");
    ObjCEncoding encoding = (ObjCEncoding)dlsym(c->objcLibrary, "method_getTypeEncoding");
    c->message = (ObjCMessage)dlsym(c->objcLibrary, "objc_msgSend");
    c->poolPush = (PoolPush)dlsym(c->objcLibrary, "objc_autoreleasePoolPush");
    c->poolPop = (PoolPop)dlsym(c->objcLibrary, "objc_autoreleasePoolPop");
    if (!getClass || !selector || !getMethod || !encoding || !c->message || !c->poolPush || !c->poolPop) return;
    void *cls = getClass("KeyboardBrightnessClient");
    if (!cls) return;
    c->brightnessSelector = selector("brightnessForKeyboard:"); c->releaseSelector = selector("release");
    void *readMethod = getMethod(cls, c->brightnessSelector);
    // Live runtime evidence: f24@0:8Q16 (float, object, selector, uint64 keyboard ID).
    if (!readMethod || strcmp(encoding(readMethod), "f24@0:8Q16") != 0 ||
        !getMethod(cls, selector("copyKeyboardBacklightIDs")) || !getMethod(cls, selector("isKeyboardBuiltIn:"))) return;
    c->keyboardRead = (KeyboardRead)dlsym(c->objcLibrary, "objc_msgSend");
    KeyboardBuiltIn isBuiltIn = (KeyboardBuiltIn)dlsym(c->objcLibrary, "objc_msgSend");
    void *pool = c->poolPush();
    c->keyboard = c->message(c->message(cls, selector("alloc")), selector("init"));
    if (c->keyboard) {
        CFTypeRef ids = c->message(c->keyboard, selector("copyKeyboardBacklightIDs"));
        if (ids && CFGetTypeID(ids) == CFArrayGetTypeID()) {
            for (CFIndex i = 0; i < CFArrayGetCount((CFArrayRef)ids); ++i) {
                int64_t keyboardID = 0;
                if (!number(CFArrayGetValueAtIndex((CFArrayRef)ids, i), &keyboardID) || keyboardID <= 0 ||
                    !isBuiltIn(c->keyboard, selector("isKeyboardBuiltIn:"), (uint64_t)keyboardID)) continue;
                char id[64]; snprintf(id, sizeof(id), "keyboard-backlight:%llu", (unsigned long long)keyboardID);
                MotionLightChannel *channel = addChannel(c, UMMotionLightKeyboardBrightness, "Keyboard backlight brightness", id);
                if (channel) channel->nativeID = (uint64_t)keyboardID;
            }
        }
        if (ids) CFRelease(ids);
    }
    c->poolPop(pool);
}

UMMotionLightClient *UMMotionLightClientCreate(int32_t *status) {
    if (status) *status = kIOReturnNoMemory;
    UMMotionLightClient *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    enumerateRegistry(c, "AppleSPUHIDDevice", false);
    enumerateRegistry(c, "AppleSPUVD6286", true);
    c->displayLibrary = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL);
    if (c->displayLibrary) c->displayRead = (DisplayRead)dlsym(c->displayLibrary, "DisplayServicesGetBrightness");
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(0, NULL, &count) == kCGErrorSuccess && count) {
        CGDirectDisplayID *displays = calloc(count, sizeof(*displays));
        if (displays && CGGetOnlineDisplayList(count, displays, &count) == kCGErrorSuccess) {
            for (uint32_t i = 0; i < count; ++i) {
                char id[64], name[160]; snprintf(id, sizeof(id), "display:%u:brightness", displays[i]);
                snprintf(name, sizeof(name), "%s display brightness (%u)", CGDisplayIsBuiltin(displays[i]) ? "Built-in" : "External", displays[i]);
                MotionLightChannel *channel = addChannel(c, UMMotionLightDisplayBrightness, name, id);
                if (channel) channel->nativeID = displays[i];
            }
        }
        free(displays);
    }
    enumerateKeyboards(c);
    if (status) *status = kIOReturnSuccess;
    return c;
}

void UMMotionLightClientDestroy(UMMotionLightClient *c) {
    if (!c) return;
    for (size_t i = 0; i < c->count; ++i) {
        if (c->channels[i].device) { IOHIDDeviceClose(c->channels[i].device, kIOHIDOptionsTypeNone); CFRelease(c->channels[i].device); }
        if (c->channels[i].service) IOObjectRelease(c->channels[i].service);
    }
    if (c->keyboard) { void *pool = c->poolPush(); c->message(c->keyboard, c->releaseSelector); c->poolPop(pool); }
    if (c->displayLibrary) dlclose(c->displayLibrary);
    if (c->brightnessLibrary) dlclose(c->brightnessLibrary);
    if (c->objcLibrary) dlclose(c->objcLibrary);
    free(c->channels); free(c);
}

size_t UMMotionLightClientGetCount(UMMotionLightClient *c) { return c ? c->count : 0; }
const char *UMMotionLightClientGetName(UMMotionLightClient *c, size_t i) { return c && i < c->count ? c->channels[i].name : NULL; }
const char *UMMotionLightClientGetID(UMMotionLightClient *c, size_t i) { return c && i < c->count ? c->channels[i].identifier : NULL; }
uint32_t UMMotionLightClientGetKind(UMMotionLightClient *c, size_t i) { return c && i < c->count ? c->channels[i].kind : 0; }

int32_t UMMotionLightClientRead(UMMotionLightClient *c, size_t i, double *value) {
    if (!c || i >= c->count || !value) return kIOReturnBadArgument;
    MotionLightChannel *channel = &c->channels[i];
    switch (channel->kind) {
        case UMMotionLightLidAngle: {
            if (channel->openStatus != kIOReturnSuccess) return channel->openStatus;
            uint8_t bytes[8]; CFIndex length = sizeof(bytes);
            IOReturn result = IOHIDDeviceGetReport(channel->device, kIOHIDReportTypeInput, 1, bytes, &length);
            if (result != kIOReturnSuccess) return result;
            return UMMotionLightDecodeLidReport(bytes, (size_t)length, value) ? kIOReturnSuccess : kIOReturnBadMessageID;
        }
        case UMMotionLightAmbientLux: {
            CFTypeRef p = IORegistryEntryCreateCFProperty(channel->service, CFSTR("CurrentLux"), kCFAllocatorDefault, 0);
            double lux = 0;
            bool valid = p && CFGetTypeID(p) == CFNumberGetTypeID() &&
                         CFNumberGetValue((CFNumberRef)p, kCFNumberDoubleType, &lux) && isfinite(lux) && lux >= 0;
            if (p) CFRelease(p);
            if (!valid) return kIOReturnNotReadable;
            *value = lux; return kIOReturnSuccess;
        }
        case UMMotionLightDisplayBrightness: {
            float brightness = NAN;
            IOReturn result = c->displayRead ? c->displayRead((uint32_t)channel->nativeID, &brightness) : kIOReturnUnsupported;
            if (result != kIOReturnSuccess) {
                // Older Intel/macOS public alternative; never a setting write.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                io_service_t display = CGDisplayIOServicePort((uint32_t)channel->nativeID);
#pragma clang diagnostic pop
                if (display) result = IODisplayGetFloatParameter(display, 0, CFSTR(kIODisplayBrightnessKey), &brightness);
            }
            if (result != kIOReturnSuccess) return result;
            if (!isfinite(brightness) || brightness < 0 || brightness > 1) return kIOReturnNotReadable;
            *value = (double)brightness * 100; return kIOReturnSuccess;
        }
        case UMMotionLightKeyboardBrightness: {
            if (!c->keyboard || !c->keyboardRead) return kIOReturnUnsupported;
            void *pool = c->poolPush();
            float brightness = c->keyboardRead(c->keyboard, c->brightnessSelector, channel->nativeID);
            c->poolPop(pool);
            if (!isfinite(brightness) || brightness < 0 || brightness > 1) return kIOReturnNotReadable;
            *value = (double)brightness * 100; return kIOReturnSuccess;
        }
        default: return kIOReturnUnsupported;
    }
}
