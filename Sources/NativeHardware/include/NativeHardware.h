#ifndef NATIVE_HARDWARE_H
#define NATIVE_HARDWARE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Read-only built-in sensor services, never keyboard or biometric events.
// Own one client per serialized caller. No run-loop or thread-affine callbacks.
typedef struct UMHIDSensorClient UMHIDSensorClient;
UMHIDSensorClient *UMHIDSensorClientCreate(int32_t *status);
void UMHIDSensorClientDestroy(UMHIDSensorClient *client);
size_t UMHIDSensorClientGetSensorCount(UMHIDSensorClient *client);
const char *UMHIDSensorClientGetSensorName(UMHIDSensorClient *client, size_t index);
const char *UMHIDSensorClientGetSensorID(UMHIDSensorClient *client, size_t index);
uint32_t UMHIDSensorClientGetUsagePage(UMHIDSensorClient *client, size_t index);
uint32_t UMHIDSensorClientGetUsage(UMHIDSensorClient *client, size_t index);
bool UMHIDSensorClientIsMotionRestricted(UMHIDSensorClient *client, size_t index);
bool UMHIDSensorClientReadFloats(UMHIDSensorClient *client, size_t index, uint32_t eventType,
                               const uint32_t *fields, size_t fieldCount, double *values);
bool UMHIDSensorClientReadIntegers(UMHIDSensorClient *client, size_t index, uint32_t eventType,
                                 const uint32_t *fields, size_t fieldCount, int64_t *values);

// Separate opt-in, process-owned rate-controlled motion subscription (5 Hz).
// The native worker owns its run loop and callbacks; destruction joins it and
// releases the client's interval requests. Generic CopyEvent reads are unchanged.
typedef struct UMHIDMotionStream UMHIDMotionStream;
UMHIDMotionStream *UMHIDMotionStreamCreate(int32_t *status);
void UMHIDMotionStreamDestroy(UMHIDMotionStream *stream);
int32_t UMHIDMotionStreamRead(UMHIDMotionStream *stream, const char *sensorID,
                            double values[3], double *unixTimestamp, double *ageSeconds);

// Synchronous read-only lid reports, display brightness, keyboard brightness,
// ambient lux properties and property-only opaque SPU inventory.
typedef struct UMMotionLightClient UMMotionLightClient;
enum {
    UMMotionLightLidAngle = 1,
    UMMotionLightDisplayBrightness = 2,
    UMMotionLightKeyboardBrightness = 3,
    UMMotionLightAmbientLux = 4,
    UMMotionLightOpaqueService = 5
};
UMMotionLightClient *UMMotionLightClientCreate(int32_t *status);
void UMMotionLightClientDestroy(UMMotionLightClient *client);
size_t UMMotionLightClientGetCount(UMMotionLightClient *client);
const char *UMMotionLightClientGetName(UMMotionLightClient *client, size_t index);
const char *UMMotionLightClientGetID(UMMotionLightClient *client, size_t index);
uint32_t UMMotionLightClientGetKind(UMMotionLightClient *client, size_t index);
int32_t UMMotionLightClientRead(UMMotionLightClient *client, size_t index, double *value);
// Report ID 1, nine-bit orientation Tilt X, logical/physical range 0...360.
bool UMMotionLightDecodeLidReport(const uint8_t *bytes, size_t count, double *degrees);

#ifdef __cplusplus
}
#endif
#endif
