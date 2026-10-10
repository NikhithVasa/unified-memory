#include "NativeHardware.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// Apple documents RateControlled=3 and process-owned report/batch intervals:
// https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/HID/Headers/HIDEventSystemClient.h
// Subscription plumbing is demonstrated by Apple's HID/HIDEventSystemClient.m.
// No IORegistry reporting-state/power-state writes or global preferences.
typedef IOHIDEventSystemClientRef (*CreateTyped)(CFAllocatorRef, int, CFDictionaryRef);
typedef void (*MatchingMultiple)(IOHIDEventSystemClientRef, CFArrayRef);
typedef void (*EventCallback)(void *, void *, void *, CFTypeRef);
typedef void (*RegisterEvent)(IOHIDEventSystemClientRef, EventCallback, void *, void *);
typedef void (*Schedule)(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
typedef double (*EventFloat)(CFTypeRef, uint32_t);
typedef uint32_t (*EventType)(CFTypeRef);

typedef struct {
    IOHIDServiceClientRef service;
    char id[48];
    uint32_t type;
    int32_t status;
    double values[3], monotonicTime, unixTime;
} MotionSample;

struct UMHIDMotionStream {
    pthread_t thread;
    pthread_mutex_t lock;
    pthread_cond_t ready;
    bool started, initialized, stop;
    int32_t status;
    MotionSample *samples;
    size_t count;
    void *library;
    IOHIDEventSystemClientRef client;
    CFArrayRef services;
    EventFloat getFloat;
    EventType getType;
};

static double seconds(clockid_t clock) {
    struct timespec t;
    clock_gettime(clock, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static int64_t serviceNumber(IOHIDServiceClientRef s, CFStringRef key) {
    CFTypeRef p = IOHIDServiceClientCopyProperty(s, key);
    int64_t v = 0;
    if (p && CFGetTypeID(p) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)p, kCFNumberSInt64Type, &v);
    if (p) CFRelease(p);
    return v;
}

static void eventCallback(void *target, void *context, void *sender, CFTypeRef event) {
    (void)context;
    UMHIDMotionStream *stream = target;
    uint32_t type = stream->getType(event);
    if (type != 13 && type != 20) return;
    double values[3];
    for (size_t i = 0; i < 3; ++i) {
        values[i] = stream->getFloat(event, (type << 16) + (uint32_t)i);
        if (!isfinite(values[i])) return;
    }
    // Native callback sender identifies the matched service. No raw report bytes.
    pthread_mutex_lock(&stream->lock);
    for (size_t i = 0; i < stream->count; ++i) {
        MotionSample *sample = &stream->samples[i];
        if (sample->service != sender || sample->type != type) continue;
        memcpy(sample->values, values, sizeof(values));
        sample->monotonicTime = seconds(CLOCK_MONOTONIC);
        sample->unixTime = seconds(CLOCK_REALTIME);
        sample->status = kIOReturnSuccess;
        break;
    }
    pthread_mutex_unlock(&stream->lock);
}

static CFDictionaryRef sensorMatch(int32_t usage) {
    int32_t page = 0xff00;
    CFNumberRef p = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &page);
    CFNumberRef u = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usage);
    CFDictionaryRef d = NULL;
    if (p && u) {
        const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage"), CFSTR("Built-In")};
        const void *values[] = {p, u, kCFBooleanTrue};
        d = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    if (p) CFRelease(p);
    if (u) CFRelease(u);
    return d;
}

static void *worker(void *argument) {
    UMHIDMotionStream *stream = argument;
    stream->library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    RegisterEvent unregisterEvent = NULL;
    Schedule unschedule = NULL;
    bool scheduled = false;
    CFRunLoopRef loop = CFRunLoopGetCurrent();
    int32_t status = kIOReturnUnsupported;
    if (!stream->library) goto cleanup;
    CreateTyped create = (CreateTyped)dlsym(stream->library, "IOHIDEventSystemClientCreateWithType");
    MatchingMultiple matching = (MatchingMultiple)dlsym(stream->library, "IOHIDEventSystemClientSetMatchingMultiple");
    RegisterEvent registerEvent = (RegisterEvent)dlsym(stream->library, "IOHIDEventSystemClientRegisterEventCallback");
    unregisterEvent = (RegisterEvent)dlsym(stream->library, "IOHIDEventSystemClientUnregisterEventCallback");
    Schedule schedule = (Schedule)dlsym(stream->library, "IOHIDEventSystemClientScheduleWithRunLoop");
    unschedule = (Schedule)dlsym(stream->library, "IOHIDEventSystemClientUnscheduleWithRunLoop");
    stream->getFloat = (EventFloat)dlsym(stream->library, "IOHIDEventGetFloatValue");
    stream->getType = (EventType)dlsym(stream->library, "IOHIDEventGetType");
    if (!create || !matching || !registerEvent || !unregisterEvent || !schedule || !unschedule || !stream->getFloat || !stream->getType) goto cleanup;
    stream->client = create(kCFAllocatorDefault, 3, NULL);
    if (!stream->client) { status = kIOReturnNotPermitted; goto cleanup; }
    CFDictionaryRef accel = sensorMatch(3), gyro = sensorMatch(9);
    if (!accel || !gyro) {
        if (accel) CFRelease(accel);
        if (gyro) CFRelease(gyro);
        status = kIOReturnNoMemory; goto cleanup;
    }
    const void *dicts[] = {accel, gyro};
    CFArrayRef match = CFArrayCreate(kCFAllocatorDefault, dicts, 2, &kCFTypeArrayCallBacks);
    CFRelease(accel); CFRelease(gyro);
    if (!match) { status = kIOReturnNoMemory; goto cleanup; }
    matching(stream->client, match); CFRelease(match);
    stream->services = IOHIDEventSystemClientCopyServices(stream->client);
    if (!stream->services) { status = kIOReturnNotPermitted; goto cleanup; }
    CFIndex count = CFArrayGetCount(stream->services);
    stream->samples = calloc((size_t)count, sizeof(*stream->samples));
    if (count && !stream->samples) { status = kIOReturnNoMemory; goto cleanup; }
    int32_t interval = 200000;
    CFNumberRef requestedInterval = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &interval);
    if (!requestedInterval) { status = kIOReturnNoMemory; goto cleanup; }
    for (CFIndex i = 0; i < count; ++i) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(stream->services, i);
        int64_t page = serviceNumber(service, CFSTR("PrimaryUsagePage"));
        int64_t usage = serviceNumber(service, CFSTR("PrimaryUsage"));
        if (page != 0xff00 || (usage != 3 && usage != 9)) continue;
        CFTypeRef identifier = IOHIDServiceClientGetRegistryID(service);
        int64_t registryID = 0;
        if (!identifier || CFGetTypeID(identifier) != CFNumberGetTypeID() ||
            !CFNumberGetValue((CFNumberRef)identifier, kCFNumberSInt64Type, &registryID) || registryID <= 0) continue;
        MotionSample *sample = &stream->samples[stream->count++];
        sample->service = service; sample->type = usage == 3 ? 13 : 20;
        snprintf(sample->id, sizeof(sample->id), "hid:%llu", (unsigned long long)registryID);
        bool allowed = IOHIDServiceClientSetProperty(service, CFSTR("ReportInterval"), requestedInterval);
        sample->status = allowed ? kIOReturnNotReady : kIOReturnNotPermitted;
    }
    CFRelease(requestedInterval);
    registerEvent(stream->client, eventCallback, stream, NULL);
    schedule(stream->client, loop, kCFRunLoopDefaultMode);
    scheduled = true;
    status = stream->count ? kIOReturnSuccess : kIOReturnNoDevice;
    pthread_mutex_lock(&stream->lock);
    stream->status = status; stream->initialized = true;
    pthread_cond_signal(&stream->ready);
    pthread_mutex_unlock(&stream->lock);
    for (;;) {
        pthread_mutex_lock(&stream->lock);
        bool stop = stream->stop;
        pthread_mutex_unlock(&stream->lock);
        if (stop) break;
        // A bounded run-loop slice permits teardown without races or cross-thread
        // callback APIs. Sampling itself stays on this one native thread.
        SInt32 runResult = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
        if (runResult == kCFRunLoopRunFinished) {
            // A denied/removed subscription may install no source; avoid spinning.
            const struct timespec pause = {.tv_sec = 0, .tv_nsec = 100000000};
            nanosleep(&pause, NULL);
        }
    }
cleanup:
    if (scheduled) {
        unschedule(stream->client, loop, kCFRunLoopDefaultMode);
        unregisterEvent(stream->client, eventCallback, stream, NULL);
    }
    if (stream->services) { CFRelease(stream->services); stream->services = NULL; }
    if (stream->client) { CFRelease(stream->client); stream->client = NULL; }
    if (stream->library) { dlclose(stream->library); stream->library = NULL; }
    pthread_mutex_lock(&stream->lock);
    if (!stream->initialized) { stream->status = status; stream->initialized = true; pthread_cond_signal(&stream->ready); }
    pthread_mutex_unlock(&stream->lock);
    return NULL;
}

UMHIDMotionStream *UMHIDMotionStreamCreate(int32_t *status) {
    if (status) *status = kIOReturnNoMemory;
    UMHIDMotionStream *stream = calloc(1, sizeof(*stream));
    if (!stream) return NULL;
    if (pthread_mutex_init(&stream->lock, NULL) != 0) { free(stream); return NULL; }
    if (pthread_cond_init(&stream->ready, NULL) != 0) { pthread_mutex_destroy(&stream->lock); free(stream); return NULL; }
    if (pthread_create(&stream->thread, NULL, worker, stream) != 0) {
        pthread_cond_destroy(&stream->ready); pthread_mutex_destroy(&stream->lock); free(stream); return NULL;
    }
    stream->started = true;
    pthread_mutex_lock(&stream->lock);
    while (!stream->initialized) pthread_cond_wait(&stream->ready, &stream->lock);
    int32_t result = stream->status;
    pthread_mutex_unlock(&stream->lock);
    if (status) *status = result;
    if (result != kIOReturnSuccess) { UMHIDMotionStreamDestroy(stream); return NULL; }
    return stream;
}

void UMHIDMotionStreamDestroy(UMHIDMotionStream *stream) {
    if (!stream) return;
    pthread_mutex_lock(&stream->lock); stream->stop = true; pthread_mutex_unlock(&stream->lock);
    if (stream->started) pthread_join(stream->thread, NULL);
    free(stream->samples);
    pthread_cond_destroy(&stream->ready); pthread_mutex_destroy(&stream->lock);
    free(stream);
}

int32_t UMHIDMotionStreamRead(UMHIDMotionStream *stream, const char *sensorID,
                            double values[3], double *unixTimestamp, double *ageSeconds) {
    if (!stream || !sensorID || !values || !unixTimestamp || !ageSeconds) return kIOReturnBadArgument;
    int32_t status = kIOReturnNoDevice;
    pthread_mutex_lock(&stream->lock);
    for (size_t i = 0; i < stream->count; ++i) {
        MotionSample *sample = &stream->samples[i];
        if (strcmp(sample->id, sensorID) != 0) continue;
        status = sample->status;
        if (status == kIOReturnSuccess) {
            double age = seconds(CLOCK_MONOTONIC) - sample->monotonicTime;
            *ageSeconds = age; *unixTimestamp = sample->unixTime;
            // Five expected 200ms periods; never publish indefinitely stale axes.
            if (age < 0 || age > 1) status = kIOReturnTimeout;
            else memcpy(values, sample->values, sizeof(sample->values));
        }
        break;
    }
    pthread_mutex_unlock(&stream->lock);
    return status;
}
