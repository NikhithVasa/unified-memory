#ifndef UNIFIED_MEMORY_NATIVE_TEMPERATURE_H
#define UNIFIED_MEMORY_NATIVE_TEMPERATURE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct UMTemperatureClient UMTemperatureClient;

// These codes describe native discovery, never a substitute temperature.
enum {
    UMTemperatureSuccess = 0,
    UMTemperatureInterfacesUnavailable = 1,
    UMTemperatureSensorsUnavailable = 2,
    UMTemperatureAllocationFailed = 3
};

UMTemperatureClient * _Nullable UMTemperatureClientCreate(int32_t * _Nonnull status);
void UMTemperatureClientDestroy(UMTemperatureClient * _Nonnull client);
size_t UMTemperatureClientGetSensorCount(const UMTemperatureClient * _Nonnull client);
const char * _Nullable UMTemperatureClientGetSensorName(const UMTemperatureClient * _Nonnull client, size_t index);
const char * _Nullable UMTemperatureClientGetSensorID(const UMTemperatureClient * _Nonnull client, size_t index);
bool UMTemperatureClientIsPhysicalSensor(const UMTemperatureClient * _Nonnull client, size_t index);
bool UMTemperatureClientReadSensor(UMTemperatureClient * _Nonnull client, size_t index, double * _Nonnull celsius);

// Generic read-only SMC access shares the same checked ABI as thermal reads.
typedef struct UMSMCClient UMSMCClient;
typedef struct {
    uint32_t key;
    uint32_t dataType;
    uint32_t dataSize;
    uint8_t bytes[32];
    uint8_t firmwareResult;
} UMSMCValue;
UMSMCClient * _Nullable UMSMCClientCreate(int32_t * _Nonnull status);
void UMSMCClientDestroy(UMSMCClient * _Nonnull client);
int32_t UMSMCClientGetKeyCount(UMSMCClient * _Nonnull client, uint32_t * _Nonnull count);
int32_t UMSMCClientGetKeyAtIndex(UMSMCClient * _Nonnull client, uint32_t index, uint32_t * _Nonnull key);
int32_t UMSMCClientGetKeyInfo(UMSMCClient * _Nonnull client, uint32_t key, UMSMCValue * _Nonnull value);
int32_t UMSMCClientReadValue(UMSMCClient * _Nonnull client, UMSMCValue * _Nonnull value);
bool UMSMCDecodeNumber(uint32_t dataType, const uint8_t * _Nonnull bytes, size_t count, double * _Nonnull value);

// Pure decoder shared by the native sampler and deterministic format tests.
bool UMTemperatureDecodeSMC(uint32_t dataType, const uint8_t * _Nonnull bytes, size_t count, double * _Nonnull celsius);

#endif
