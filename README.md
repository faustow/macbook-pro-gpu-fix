# MacBook Pro 2018 (15,1) — Disable Failing AMD Radeon Pro 560X

**Status: WORKING** — Tested and confirmed April 5, 2026. Machine stable, fans normal, Intel UHD 630 driving display, AMD Radeon Pro 560X idle with power management active.

Fix for a known hardware defect on the 2018 MacBook Pro 15-inch where the AMD Radeon Pro 560X discrete GPU degrades over time, causing kernel panics, boot loops, and WindowServer crashes. Apple never issued a recall. Logic board replacement costs $600-800+.

This repository documents every approach attempted, what worked, what failed, and why — so others don't waste time repeating dead ends.

## TL;DR — What actually works

**Keep AMD drivers loaded** (they manage GPU power — without them the GPU overheats) but **prevent macOS from using the AMD GPU** via NVRAM + LaunchDaemon:

```bash
# From Recovery Mode (Cmd+R > Utilities > Terminal):
nvram 7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args="agc=-1"
nvram 4D1EDE21-7FDE-4053-9556-E55836157E45:gpuswitch=%30
nvram fa4ce28d-b62f-4c99-9cc3-6815686e30f9:gpu-power-prefs=%01%00%00%00
nvram gpu-policy=%01
csrutil disable
```

Then from running macOS, install the LaunchDaemon from `scripts/disable-amd-gpu-daemon.plist` to re-apply on every boot.

**Important:** `agc=-1` is the most critical setting. `gpuswitch=0` alone only controls which GPU drives the **display** — macOS can still send rendering/compute work to the AMD GPU, causing GPU Reset panics. `agc=-1` disables the Apple Graphics Controller switching entirely, preventing macOS from using the AMD for anything.

SIP must be disabled for the LaunchDaemon to re-apply NVRAM settings on boot.

Intel UHD 630 drives the display. AMD stays powered but idle, managed by its drivers. No OpenCore needed. No kext removal needed.

## The problem

The 2018 MacBook Pro 15-inch ships with dual GPUs: Intel UHD 630 (integrated) and AMD Radeon Pro 560X (discrete). A known hardware defect causes the AMD GPU's solder joints or die to degrade over time. Symptoms:

- Random kernel panics during normal use
- Boot loops (panic → reboot → AMD activates → panic again)
- WindowServer crashes (black screen, forced reboot)

## Approaches tested

### ❌ OpenCore + WhateverGreen (FAILED — do not use on this Mac)

**Problem 1: WiFi "Timeout!" during OpenCore boot.** OpenCore's boot process corrupts the T2 chip's internal USB bus. The BCM4364 WiFi chip (connected via T2 USB) fails to download firmware. Every configuration was tested:

| Config | Result |
|--------|--------|
| All Booter quirk combinations (SampleCustom, OCLP, Dortania, none) | Timeout |
| All kext combinations (with/without Lilu, WEG, both disabled) | Timeout |
| NVRAM manipulation (empty Delete/Add, RequestBootVarRouting off) | Timeout |
| WiFi kext blocking (AppleBCMWLANBusInterfacePCIeMac etc.) | Still hung |
| ExitBootServicesDelay=3s | Inconsistent — works ~30% of the time |
| ExitBootServicesDelay=5s | Always fails (too much delay) |
| ForceExitBootServices=true | Inconsistent |
| OpenCore 1.0.7 update | No improvement |
| ShowPicker=false instant boot | Timeout |
| No verbose mode (-v removed) | Sometimes reaches login |

**Conclusion: OpenCore itself is incompatible with this Mac's T2/WiFi. The boot process changes something fundamental about the UEFI environment that prevents the T2 USB bus from initializing.**

**Problem 2: Login hangs after password entry** (on the rare occasions boot succeeded). WindowServer gets stuck in IOGraphicsFamily during the loginwindow-to-desktop transition:

| Approach | Result |
|----------|--------|
| `-wegnoegpu` boot-arg | WindowServer crash — SafeEjectGPUAgent/AppleGPUWrangler conflict |
| `disable-external-gpu` DeviceProperty on IGPU | Still hangs (shutdown_stall) |
| SSDT-dGPU-Off v1 (`_OFF` method) + WEG | Still hangs |
| SSDT-dGPU-Off v2 (Bumblebee `_DSM`+`_PS3`) + WEG | Still hangs |
| SSDT + WEG + 7 AMD kext blocks + class-code spoof | Still hangs |
| SSDT without WEG | Garbled display/panic (agdpmod/igfxblr are WEG-only flags) |
| Auto-login to bypass loginwindow | Boot hung at WiFi before reaching login |

**Conclusion: Even when OpenCore boots successfully, WhateverGreen's GPU disabling mechanism triggers a WindowServer deadlock during login.**

### ❌ Remove AMD kexts from sealed system volume (FAILED — makes things WORSE)

**Critical discovery: removing AMD kexts causes the GPU to OVERHEAT.** Without drivers, the AMD GPU hardware runs at full power with no power management. CPU temperature hit 99°C and fans maxed out at 5500+ RPM. The machine became unstable and crashed.

Additional problems:
- `kmutil` requires a KDK (Kernel Development Kit) to rebuild kernel collections on macOS 13+
- Apple never published a KDK for build 22H730 — `kmutil` cannot work
- `--allow-missing-kdk` fails with dependency resolution errors
- Skipping `kmutil` and using only `bless --create-snapshot` destroyed the sealed system snapshot
- The raw volume boots in an inconsistent state

**Conclusion: AMD drivers are REQUIRED for GPU power management. Never remove them.**

### ✅ NVRAM + LaunchDaemon (WORKS — current solution)

Keep AMD drivers loaded so they manage the GPU's power state, but configure macOS to never use the AMD GPU for display or compute:

| Setting | Value | Purpose |
|---------|-------|---------|
| `gpuswitch` | `0` | Force integrated GPU (Intel) via gmux chip |
| `gpu-power-prefs` | `01000000` | Tell macOS to prefer integrated GPU |
| `boot-args` | `agc=-1` | Disable Apple Graphics Controller switching |
| `gpu-policy` | `01` | Prefer integrated GPU |
| `pmset gpuswitch` | `0` | Force integrated at OS level |

A LaunchDaemon re-applies these settings on every boot to survive NVRAM resets.

## Installation

### 1. Set NVRAM + disable SIP (from Recovery Mode)

1. Restart, hold **Cmd+R** for Recovery Mode
2. **Utilities > Terminal**
3. Run each command:

```bash
nvram 7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args="agc=-1"
nvram 4D1EDE21-7FDE-4053-9556-E55836157E45:gpuswitch=%30
nvram fa4ce28d-b62f-4c99-9cc3-6815686e30f9:gpu-power-prefs=%01%00%00%00
nvram gpu-policy=%01
csrutil disable
```

4. `reboot`

**Why disable SIP?** The LaunchDaemon needs to write NVRAM on every boot to re-apply `agc=-1` (protects against NVRAM resets). This requires SIP to be off.

### 2. Install LaunchDaemon (from running macOS)

```bash
sudo cp scripts/disable-amd-gpu-daemon.plist /Library/LaunchDaemons/com.local.disable-amd-gpu.plist
sudo chmod 644 /Library/LaunchDaemons/com.local.disable-amd-gpu.plist
sudo chown root:wheel /Library/LaunchDaemons/com.local.disable-amd-gpu.plist
sudo launchctl load /Library/LaunchDaemons/com.local.disable-amd-gpu.plist
```

### 3. Verify

```bash
# GPU status — both visible, Intel drives display
system_profiler SPDisplaysDataType | grep "Chipset Model"

# Should show gpuswitch 0
pmset -g | grep gpuswitch

# AMD kexts loaded (CORRECT — they manage power)
kextstat | grep -i amd
```

## Verified results

### April 5, 2026 — Initial fix (gpuswitch=0 + gpu-power-prefs)

Machine stable for 2 days with Intel driving display and AMD idle.

### April 7, 2026 — GPU Reset panics returned

After 2 days, the AMD GPU started crashing again with `GPU Reset` panics. Root cause: **`gpuswitch=0` only controls display routing**. macOS was still sending rendering/compute work to the AMD via WindowServer, triggering GPU Reset events every ~30 seconds at boot.

**Fix**: Added `agc=-1` to boot-args (disables Apple Graphics Controller switching entirely). This prevents macOS from using the AMD GPU for ANY purpose — display, rendering, or compute.

### Current stable config

```
$ nvram boot-args
boot-args    agc=-1

$ pmset -g | grep gpuswitch
 gpuswitch            0

$ kextstat | grep -i amd | wc -l
       7

$ system_profiler SPDisplaysDataType | grep "Chipset Model"
      Chipset Model: Intel UHD Graphics 630
      Chipset Model: Radeon Pro 560X
```

- **7 AMD kexts loaded** — managing GPU power state (prevents overheating)
- **Intel UHD 630** driving the internal display at 2880x1800
- **Radeon Pro 560X** visible but idle — `agc=-1` prevents any GPU work being sent to it
- **Fans normal** — not spinning at max RPM

## What NOT to do

| Action | Why it's dangerous |
|--------|-------------------|
| Remove AMD kexts from /System | GPU overheats without power management drivers. CPU hits 99°C. |
| Use OpenCore on MBP 15,1 with T2 | WiFi Timeout during boot. Login hangs when it does boot. |
| Reset NVRAM (Cmd+Option+P+R) | Wipes gpuswitch and gpu-power-prefs. AMD activates. Panic. |
| Reset SMC | Can reset gpuswitch to automatic. AMD activates under load. Panic. |
| Set gpuswitch=2 (automatic) | macOS switches to AMD under load. Panic. |
| Use `bless --create-snapshot` without `kmutil` | Destroys sealed system snapshot. Inconsistent boot state. |
| Disable SIP + modify system volume without KDK | `kmutil` fails. Broken kernel cache. Unbootable system. |

## Emergency recovery

**If the system won't boot normally:**

1. Power off (hold 10 seconds)
2. Power on holding **Cmd+R** → Recovery Mode
3. **Utilities > Terminal**
4. Restore the sealed snapshot: `bless --mount /Volumes/"Macintosh HD" --last-sealed-snapshot`
5. If that fails: **Reinstall macOS** from Recovery (preserves your data)

**If the system overheats after kext removal:**

Recovery Mode Terminal:
```bash
# Mount system volume
mount_apfs -o nobrowse /dev/diskXsY /Volumes/mnt1

# Restore AMD kexts from backup
mv /Volumes/mnt1/AMD_Kext_Backup/*.kext /Volumes/mnt1/System/Library/Extensions/

# Restore sealed snapshot
bless --mount /Volumes/mnt1 --last-sealed-snapshot

# Reboot
reboot
```

## Technical details

| Component | Detail |
|-----------|--------|
| Model | MacBook Pro 15,1 (July 2018, 15-inch) |
| CPU | Intel Core i7-8750H (Coffee Lake, 8th gen) |
| iGPU | Intel UHD Graphics 630 |
| dGPU | AMD Radeon Pro 560X (4GB) — **defective** |
| WiFi | Broadcom BCM4364 (on T2 internal USB bus) |
| Security | Apple T2 chip |
| macOS | 13.7.8 Ventura (build 22H730) |
| ACPI path (AMD) | `_SB.PCI0.PEG0.GFX0` |
| PCI path (AMD) | `PciRoot(0x0)/Pci(0x1,0x0)/Pci(0x0,0x0)` |

## Applicability

This investigation applies to any MacBook Pro 15,1 (2018) with a failing AMD GPU. The NVRAM approach should work on macOS 11 Big Sur through macOS 14 Sonoma. It may also apply to:

- MacBook Pro 11,5 (Mid 2015) — AMD Radeon R9 M370X
- MacBook Pro 16,1 (2019) — AMD Radeon Pro 5300M/5500M

The core principle is the same: keep AMD drivers loaded for power management, use NVRAM to force Intel as the primary GPU.

## Repo structure

```
macbook-pro-gpu-fix/
  README.md                          ← This file
  INVESTIGATION_EN.md                ← Full technical investigation (English)
  INVESTIGACION_ES.md                ← Full technical investigation (Spanish)
  scripts/
    disable-amd-gpu-daemon.plist     ← LaunchDaemon to enforce GPU settings on boot
    restore.sh                       ← Emergency restore script (run from Recovery)
  OpenCore_GPU_Fix/                  ← OpenCore package (DOES NOT WORK — kept for reference)
```

## License

Documentation and scripts in this repo are provided as-is for educational and repair purposes.
