Unified Memory
 MacOS Native Desktop Monitor SwiftUI + Swift Charts
- No third-party dependencies
- No internet access
- No admin rights
- No background process

Run
 App is at ~/Applications/Unified Memory.app

open "$HOME/Applications/Unified Memory.app"
 - Memory Overview:
 - Current physical memory usage:
 - macOS pressure
 - Swap
 - App / Wired / Compressed / Cache / Free breakdown
 - History of usage
 - Bars for physical memory / swap / disk used vs free.
 - GPU driver allocations draw from physical pool. Not extra VRAM.
 - Memory per process
 - Name, PID, memory footprint and percentage of the total installed 32 GiB. Sorted by largest.
 - Search for name or exact PID.
 - Click row to **Terminate...** (SIGTERM) or **Force Kill...** (SIGKILL).
 - Press enter for confirm.
 - Default keyboard press is cancel.
 - Not saved work can be lost. App helpers might restart.
 - Sensors
 - Current numerical cards. Search and categories.
 - Click card for precise source, units, timestamp, availability.
 - Click star on a tile to put it into the Favorites section at the top.
 - Favorites are stored locally for each run.
 - Look for related icons to show lid, battery, keyboard, disk, motion, light and memory cards.
 - Memory / Temperature / Power / System counters update at 1s, 2s, 5s.
 - Motion / Light update at 5Hz when Sensors tab is open.
 - ⌘P to pause all visible update in all tabs.
 - ⌘R to take a sample even in paused state.
 - Header displays hottest valid exposed internal temperature sensor. (not case/surface/room temp.)
 - Click for individual temperatures.

What do the numbers mean?
 - Physical memory is from host_statistics64 and host_page_size.
 - Installed from macOS.
 - Pressure and swap from sysctlbyname.
 - App Memory: resident anon pages - purgeable pages.
 - Wired: pages kernel keeps in RAM.
 - Compressed: real physical RAM occupied by compressor, not the equivalent uncompressed.
 - Cached files: file backed pages (minus speculative) + purgeable pages.
 - Free: Kernel free pages count. Already includes speculative pages.
 - Other: installed - that which isn't accounted by those counters. (ex. reserved memory)
 - Snapshots are approximate. Counters that change quickly might not line up perfectly.
 - Used memory: app + wired + compressed. Reclaimable / Free: cached files + free pages.
 - Swap. Disk space. Not extra physical RAM.

CPU/GPU unified memory. We show also gpu driver reported allocations - explicitly as part of same RAM pool.
Swap is disk backed virtual memory.
Sensor show CPU cache sizes if exposed, not adding them to app allocable RAM.
Boot APFS storage bar shows used/free volume/pool space. APFS volumes can share pool.

ri_phys_footprint from proc_pid_rusage is per process usage. it's not just resident ram, it's also memory charge of process including compressed. don't just add rows for processes to compare with physical memory used. it's different accounting and not a 1:1 per process partition of system/kernel/shared allocations. can deny access to protected processes on macOS, showing **Unavailable** (not some made up zero)
processes that have exited in between sampling are gone on next sample.
process enumeration goes via ui actor.

GiB is 1073741824 bytes, MiB is 1048576 bytes

## hardware sensors & status

Apple M5 this had discovery of 195 thermal channels (61 physical/correlated values)
total 286 (sensor prefix) smc channels, 81 electrical (HID) channels, motion/light, battery/charger counters, system/GPU/radio/storage telemetry.
dashboard after merging thermal duplicate keys has 582 different channels/status cards.
machine/OS specific - not guaranteeing every channel is physical sensors.

- Lid: actual hinge Tilt X degrees from native HID report descriptor. Raw/live changed 132° to 113°.
- Motion: six actual axes for accelerometer/gyroscope from rate-control sensor sub (process-owned). **Raw/unclassified**, explicitly, since we don't see a known physical unit/chassis axis mapping in vendor report. Degrees pitch/roll from acceleration vector in sensor frame, not calib laptop att. Data over 1 sec ago no longer accessible.
- Brightness/Light: actual in-built display/keyboard backlight settings % and lux ambient illuminance. Separate labeled raw light channels. Brightness % not nits of luminance.
- Temp: native HID events and readonly AppleSMC die channels. We keep all discovered channels' status. We don't interpret calib'd, disconnected/sentinel, nonnumeric, or raw/unclass'd fw channels to invent phys Celsius values.
- Electric/Battery: known SMC power/current/voltage. Native battery: charge/voltage/current/caps/cycles/health/status. Per-cell voltages. Charger exposed numeric counters. Unknown electric HID scale -- we don't guess volts/amps. AppleSmartBattery Temp in deciKelvin. All virt temp fields -- raw.
- Other status: CPU usage/caches. Native thermal pressure. GPU driver counters. Storage capacity. WiFi radio/signal/link status. Detected TouchID hardware. (We never read biometrics payloads or kbds.) No fan svc/key -- this Mac not exposing it; the fan card gives fan's report instead of fake RPM.

Each tile has a top status strip. Explicitly use only display guidelines for grn/orng/red levels where scale is sensible: 70/85°C internal temp. 40/45°C batt temp. 60/75°C storage temp. medium/high usage at70/90%. Brightness setting bands40/80%. low battery charge25/10%. Not manufacturer safety limits! All unknown/raw/lid/ambient/electric, no reason to defend normal/high limit -- gray and explains. click/hover for threshold/interpretation.

Some private macos interfaces for temperature, rate-controlled motion, DisplayServices, CoreBrightness, ApplesMC. No need for root. This machine. Could vary by os/hardware. Discovered and rejected/permission-denied channels still available. Read-only sensor values. Motion client only asking for their own 200ms interval. Give up their own on teardown. No permanent, global sensor power/report state alterations.

### Safety of process kill

Confirm pid + time since process started. Before sending the selected signal, service immediately rechecks for the specific identity. Deny pid1. Deny bad/non-positive pid. Deny monitor. Deny unreadable/zero identity. Report error conditions (permissions, exited, re-used pid) straight up. No elevation. Kernel accepted signal if successful. Not guaranteed exit. No pidfd-like atomic pid+signal interface in macos. There's still a tiny kernel race between rechecking and signalling.

Actual lid/light/temp/motion changes tested for verification. Various sample/pause and manual refresh. Pin favorites and card info. Capacity bars. Native pid confirmation cancel/sigterm/sigkill (owned ephemeral /bin/sleep kids only). 30 regressions, deterministic: native decode. Sensor min/max. Accounting. Counter wrap. Process identity safety.

### Build

macOS 14 or later. Swift 6 toolchain (xcode or command line tools).

./build.sh
 swift test

builds dist/Unified Memory.app. Makes the native icon. Adhoc signs the bundle for local use. To put a re-built version into use, first close any running app.

ditto "dist/Unified Memory.app" "$HOME/Applications/Unified Memory.app"
 open "$HOME/Applications/Unified Memory.app"

Accounting regression test to avoid double counting speculative pages. Avoids false-positives with physical compressed memory versus uncompressed memory content.

#### Needs macOS 14+ swift6 toolchain (xcode or command line tools)
