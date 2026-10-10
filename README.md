# Unified Memory

Native macOS desktop monitor, built with SwiftUI and Swift Charts. No third-party dependencies, network access, administrator privileges, or background service.

## Run

The app is installed at `~/Applications/Unified Memory.app`.

```sh
open "$HOME/Applications/Unified Memory.app"
```

- **Memory overview:** live physical-memory usage, macOS pressure, swap, app/wired/compressed/cache/free breakdown, usage history, and physical-memory/swap/disk used-versus-free bars. GPU driver allocations share the physical pool; they are not extra VRAM.
- **Memory by process:** names, PIDs, memory footprints, and percentage of the full installed 32 GiB, sorted largest first. Search by name or exact PID. Select a row to **Terminate…** (SIGTERM) or **Force Kill…** (SIGKILL), then confirm. Cancel is the default keyboard action. Unsaved work can be lost; app helpers may restart.
- **Sensors:** live numeric cards with search and categories. Click a card for the exact source, units, timestamp, and availability. Star a tile to pin it into the top Favorites section; favorites persist locally across launches. Related icons identify lid, battery, keyboard, disk, motion, light, and memory cards.
- Memory/temperature/power/system counters refresh every 1, 2, or 5 seconds. Motion/light refresh at 5 Hz while Sensors is open. **⌘P** pauses displayed updates across all tabs; **⌘R** takes a sample even while paused.
- The header shows the hottest valid exposed internal temperature sensor, not case/surface/room temperature. Click it for individual temperature readings.

## What the numbers mean

Physical-memory readings come from `host_statistics64` and `host_page_size`. Installed capacity comes from macOS. Pressure and swap come from `sysctlbyname`.

- **App memory:** resident anonymous pages minus purgeable pages.
- **Wired:** pages the kernel keeps in RAM.
- **Compressed:** actual physical RAM occupied by the compressor, not its uncompressed equivalent.
- **Cached files:** file-backed pages, excluding speculative pages, plus purgeable pages.
- **Free:** the kernel's free-page count, which already includes speculative pages.
- **Other:** installed capacity not attributed by those counters, including reserved memory. Snapshots are approximate; rapidly changing counters may not perfectly reconcile.
- **Memory used:** app + wired + compressed. **Reclaimable / free:** cached files + free pages.
- **Swap:** disk storage, not additional physical RAM.

CPU and GPU share unified memory. GPU driver-reported allocations are also shown, explicitly as part of that same RAM pool. Swap is disk-backed virtual memory. CPU cache sizes are shown in Sensors when exposed, not added to app-allocatable RAM. The boot APFS storage bar shows used and free volume/pool space; APFS volumes can share that pool.

Per-process usage is `ri_phys_footprint` from `proc_pid_rusage`. It represents the process's memory charge, including compressed memory, rather than only resident RAM. Do not add the process rows and compare the result with physical memory used: the accounting is different, and system/kernel/shared allocations are not a one-to-one per-process partition. macOS can deny access to protected processes; these display **Unavailable**, not a fabricated zero. Processes that exit during sampling disappear on subsequent samples. Process enumeration runs off the UI actor.

GiB means 1,073,741,824 bytes; MiB means 1,048,576 bytes.

## Hardware sensors and status

On this Apple M5, discovery exposed 195 thermal channels (61 corroborated physical readings), 286 sensor-prefixed SMC channels in total, 81 electrical HID channels, motion/light, battery/charger counters, and system/GPU/radio/storage telemetry. The dashboard displayed 582 distinct channels/status cards after merging duplicate thermal keys. These counts are machine/OS-specific, not a promise that all channels are physical sensors.

- **Lid:** actual hinge Tilt X degrees from the native HID report descriptor. Observed live readings changed from 132° to 113°.
- **Motion:** six actual accelerometer/gyroscope axes from a process-owned rate-controlled sensor subscription. These remain explicitly **raw/unclassified** because the vendor report exposes no confirmed physical unit/chassis-axis mapping. Acceleration-vector pitch/roll are degrees in the sensor frame, not calibrated laptop attitude. Events older than one second become unavailable.
- **Brightness/light:** actual built-in display and keyboard-backlight settings in percent, ambient illuminance in lux, and separately labeled raw light channels. Brightness percent is not luminance in nits.
- **Temperature:** native HID events and read-only AppleSMC die channels; all discovered channels retain status. Calibration, disconnected/sentinel, nonnumeric, and unclassified firmware channels are not converted into invented physical Celsius readings.
- **Electrical/battery:** established SMC power/current/voltage readings and native battery charge, voltage/current, capacities, cycles, health/status, per-cell voltages, and exposed numeric charger counters. Unknown electrical HID scale stays raw instead of guessing volts/amps. AppleSmartBattery Temperature uses deciKelvin; virtual-temperature fields remain raw.
- **Other status:** CPU utilization and caches, native thermal pressure, GPU driver counters, storage capacity, Wi-Fi radio/signal/link status, and detected Touch ID hardware. Biometric payloads and keyboard reports are never read. No fan service/key was exposed on this Mac; the fan card reports that instead of a fake RPM.

Every tile has a top status strip. Green/orange/red levels use explicit display guidelines only where a meaningful scale exists: internal temperature 70/85 °C, battery temperature 40/45 °C, storage temperature 60/75 °C; utilization medium/high at70/90%; brightness setting bands40/80%; low battery charge25/10%. These are **not manufacturer safety limits**. Unknown/raw/lid/ambient/electrical channels without defensible normal/high limits stay gray and say why. Click/hover for the thresholds and interpretation.

Temperature, rate-controlled motion, DisplayServices, CoreBrightness, and AppleSMC include private macOS interfaces. They work without root on this machine, but may change across OS/hardware versions. Discovered unavailable/permission-blocked channels remain visible. Sensor readings are read-only; the motion client requests only its own 200 ms interval and releases that ownership on teardown. No persistent global sensor power/reporting-state settings are changed.

## Process termination safety

The confirmation captures PID plus process start time; the service revalidates that exact identity immediately before sending the chosen signal. PID1, invalid/nonpositive PIDs, the monitor itself, and unreadable/zero identities are rejected. Permission errors, exited processes, and PID reuse are reported honestly, without elevation. Successful status means the kernel accepted the signal, not that exit is guaranteed. macOS has no pidfd-style atomic identity-plus-signal API; a small kernel race remains between revalidation and the signal call.

Verification exercised real changing lid/light/temperature/motion readings, sampling pause/manual refresh, favorite pinning and card details, capacity bars, and native PID confirmation cancel/SIGTERM/SIGKILL using only owned temporary `/bin/sleep` children. The 30 deterministic regressions cover native decoding, sensor bounds, accounting, counter wrap, and process-identity safety.

## Build

Requires macOS 14 or newer and a Swift 6 toolchain (Xcode or Command Line Tools).

```sh
./build.sh
swift test
```

The script creates `dist/Unified Memory.app`, generates its native icon, and ad-hoc signs the bundle for local use. To install a rebuilt version, quit the running app first:

```sh
ditto "dist/Unified Memory.app" "$HOME/Applications/Unified Memory.app"
open "$HOME/Applications/Unified Memory.app"
```

The accounting regression test protects against double-counting speculative pages and confusing physical compressed memory with uncompressed contents.
