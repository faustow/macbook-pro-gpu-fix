# MacBook Pro 15,1 (2018) — Failing AMD GPU Investigation

## Machine Identification

- **Model:** MacBook Pro 15,1 (Mid 2018, 15-inch with Touch Bar)
- **CPU:** 6-Core Intel Core i7 @ 2.6 GHz (Coffee Lake, 8th gen)
- **RAM:** 16 GB
- **GPUs:** Intel UHD Graphics 630 (integrated) + AMD Radeon Pro 560X (discrete)
- **Display:** 15.4" Retina, 2880 x 1800 native resolution
- **Storage:** Apple SSD (APFS)
- **Security Chip:** Apple T2
- **macOS:** 13.7.8 Ventura (Darwin 22.6.0)
- **Serial:** C02XJ3SQJG5M
- **Firmware:** 2094.40.1.0.0 (iBridge: 23.16.13087.5.3,0)
- **Date of fix:** February 13, 2026

---

## The Problem

The AMD Radeon Pro 560X discrete GPU was failing intermittently. Symptoms:

1. **Kernel panics** — Sudden reboots with no warning. The system would crash mid-use.
2. **Boot loops** — After a panic, macOS would attempt to reboot, activate the AMD GPU again, and crash again.
3. **WindowServer crashes** — The display server would freeze due to GPU errors, causing the screen to go black and forcing a hard reboot.

This is a well-documented hardware defect in the 2018 MacBook Pro 15-inch line. The AMD Radeon Pro 555X/560X solder joints or the GPU die itself degrades over time, especially under thermal stress. Apple never issued a formal recall for this specific model year.

### Why this is hard to fix

On a normal Mac, you would either:
- Replace the logic board (expensive, ~$600-800)
- Remove the AMD GPU kernel extensions to prevent macOS from talking to the failing hardware

But on macOS 13 Ventura, the system volume is **cryptographically sealed** (Signed System Volume, SSV). You literally cannot modify `/System/Library/Extensions/` — not even with SIP disabled, not even as root. The seal is verified at boot time by the T2 chip and the APFS snapshot mechanism. This means you cannot delete the AMD kexts.

The only viable software solution is to **intercept the GPU at the bootloader level** before macOS ever sees it.

---

## Timeline of Events

### Jan 29, 2026 — First Claude Code session
- Claude Code watchdog launched for the first time at 15:24
- Initial diagnosis began
- System was crashing repeatedly due to AMD GPU panics

### Jan 29 - Feb 6, 2026 — NVRAM fixes and software hardening
- Set `gpuswitch=0` to force integrated graphics at firmware level
- Set `gpu-policy` and `gpu-power-prefs` NVRAM variables
- Disabled hibernation, standby, power nap (to avoid GPU wake triggers)
- Removed dangerous third-party kexts: Paragon NTFS, HighPoint RAID, SoftRAID
- Disabled launch agents: AnyTrans, Steam, LastPass
- Configured T2 Secure Boot to "No Security" (required for OpenCore)
- These fixes reduced crash frequency but did not eliminate it — AMD drivers still loaded

### Feb 6, 2026 — OpenCore v1 attempt
- Built OpenCore bootloader package with Lilu + WhateverGreen
- boot-args: `-wegnoegpu` only
- **Result: BLACK SCREEN** — system booted but display remained off
- Root cause identified (see Attempt 1 below)

### Feb 12, 2026 — OpenCore v2 attempt
- Rebuilt package with corrected boot-args
- **Install script failed** — HfsPlus.efi missing from Drivers directory
- Even if it had installed, config.plist had 7 critical bugs (see Attempt 3 below)
- WindowServer watchdog crash at 15:28 during debugging

### Feb 12, 2026, ~16:43 — Stable boot achieved
- With the older OpenCore config (from a partially successful earlier install), the system booted and stayed stable
- 15+ hours uptime confirmed

### Feb 13, 2026 — OpenCore v3 installed from Recovery Mode
- User booted into Recovery Mode (Cmd+R)
- Ran the corrected INSTALL.sh script
- Script mounted EFI partition, copied corrected OpenCore files
- Rebooted, selected "Macintosh HD" from OpenCore picker
- **System booted successfully with Intel UHD 630 only**
- Lilu 1.7.1 + WhateverGreen 1.7.0 confirmed loaded
- No kernel panics, no AMD GPU visible to macOS

---

## What Was Tried and Why Each Failed

### Attempt 0: Remove AMD kexts from /System — IMPOSSIBLE

**What we tried:** Delete AMD GPU kernel extensions from `/System/Library/Extensions/AMD*.kext`

**Why it failed:** macOS 13 Ventura uses a Signed System Volume (SSV). The system partition is mounted as a cryptographically sealed APFS snapshot. Any modification to `/System` would break the seal, and the T2 chip would refuse to boot from that snapshot. This is not a permissions issue — it is a fundamental architectural constraint of modern macOS. Even with SIP fully disabled and root access, writes to `/System` are rejected.

**Lesson:** On macOS 11 Big Sur and later, you cannot modify system files. Period. Solutions must work *around* the sealed volume, not through it.

### Attempt 1: NVRAM-only GPU disable — INSUFFICIENT

**What we tried:** Set NVRAM variables to tell macOS to prefer the integrated GPU:
```
nvram FA4CE28D-B62F-4C99-9CC3-6815686E30F9:gpu-power-prefs=%01%00%00%00
nvram gpu-policy=%01
nvram 4D1EDE21-7FDE-4053-9556-E55836157E45:gpuswitch=0
```
Plus power management changes:
```
sudo pmset -a hibernatemode 0
sudo pmset -a standby 0
sudo pmset -a powernap 0
```

**Why it was insufficient:** These NVRAM variables tell macOS to *prefer* integrated graphics, but macOS still loads the AMD kernel extensions into memory. The failing GPU hardware can still be probed by the driver, and any driver interaction with a failing GPU can trigger a kernel panic. The `gpuswitch=0` setting prevents *intentional* switching to the dGPU, but doesn't prevent the AMD driver from initializing.

**Lesson:** NVRAM preferences are a hint to macOS, not a hard block. The AMD kext drivers will still load and can still crash. You need a mechanism that prevents the drivers from attaching to the GPU hardware entirely.

### Attempt 2: gpuswitch=2 (automatic) — NOT ENOUGH

**What we tried:** Set `gpuswitch=2` which lets macOS automatically choose between iGPU and dGPU.

**Why it failed:** With `gpuswitch=2`, macOS will activate the AMD GPU whenever a process requests higher GPU performance (Metal rendering, external display, some apps). Since the GPU hardware is failing, any activation = crash.

**Lesson:** Must use `gpuswitch=0` (force integrated only), never `gpuswitch=2` (automatic).

### Attempt 3: OpenCore v1 — BLACK SCREEN

**What we tried:** Installed OpenCore 1.0.6 bootloader on the EFI partition with:
- Lilu 1.7.1 (kernel extension patcher framework)
- WhateverGreen 1.7.0 (GPU-specific patches)
- boot-args: `-wegnoegpu` (tells WhateverGreen to disable external/discrete GPU)

**Why it failed:** The system booted fine (we could hear the startup chime and SSH was accessible) but the **display remained completely black**. Two critical boot arguments were missing:

1. **`agdpmod=pikera`** — Apple's Graphics Device Policy (AGDP) driver performs a board-id verification. On MacBook Pros with dual GPUs, AGDP expects the discrete GPU to drive certain display outputs. When you disable the dGPU with `-wegnoegpu`, AGDP sees that the expected GPU is gone and **refuses to let the Intel iGPU drive the internal display**. The `agdpmod=pikera` flag patches AGDP to skip this board-id check entirely, allowing the iGPU to output to the built-in Retina panel.

2. **`-igfxblr`** — Intel Coffee Lake (8th gen) processors have a bug in the integrated graphics driver where the **backlight register is never properly initialized** during early boot. On a Retina MacBook Pro, this means the LCD backlight stays at zero brightness even though the framebuffer is rendering correctly. The `-igfxblr` flag (Intel Graphics Fix Backlight Register) tells WhateverGreen to patch the backlight initialization sequence so the display actually illuminates.

**Lesson:** Disabling the dGPU with `-wegnoegpu` alone is not sufficient on a MacBook Pro. You also need `agdpmod=pikera` (to bypass Apple's display policy that blocks the iGPU from driving the panel) and `-igfxblr` (to fix the Coffee Lake backlight register bug). All three flags are mandatory.

### Attempt 4: OpenCore v2 install script — SCRIPT ABORTED

**What we tried:** Created an improved OpenCore package (v2) with corrected boot-args and an automated install script. Ran the script from Recovery Mode terminal.

**Why it failed:** The script validated all required files before copying them to the EFI partition. It found that `EFI/OC/Drivers/HfsPlus.efi` was missing and aborted with:
```
MISSING: EFI/OC/Drivers/HfsPlus.efi — Cannot proceed
```

The build script that assembled the package had downloaded HfsPlus.efi (37KB) into a `downloads/` staging directory but **never copied it to its final location** at `EFI/OC/Drivers/`. This is a classic build pipeline error — the download step succeeded but the copy/assembly step had a bug.

**Lesson:** Always verify the final assembled package, not just the download cache. The v3 install script was improved to auto-repair this by copying HfsPlus.efi from `downloads/` if it's missing from `Drivers/`.

### Attempt 5: OpenCore v2 config.plist — 7 CRITICAL BUGS

Even if the install script had succeeded, the config.plist had seven separate issues that would have prevented a successful boot. The root cause was that the config.plist was barely modified from OpenCore's `SampleCustom.plist` template — a template designed for **hackintosh builds** (running macOS on non-Apple hardware), not for real Macs.

| # | Setting | Wrong Value | Correct Value | Why It Matters |
|---|---------|------------|---------------|----------------|
| 1 | `Vault` | `Secure` | `Optional` | OpenCore's Secure vault mode requires cryptographic hash files (`vault.plist`, `vault.sig`). We don't have these. With `Secure`, OpenCore refuses to load at all. |
| 2 | `SecureBootModel` | `Default` | `Disabled` | T2 chip is set to "No Security" (required for OpenCore). `Default` tells OpenCore to enforce Apple Secure Boot, which conflicts with the T2 setting and causes a boot failure. |
| 3 | `ScanPolicy` | `17760515` | `0` | This bitmask restricts which file systems and device types OpenCore will scan. The value `17760515` is highly restrictive and may not find the macOS APFS boot volume. `0` means "scan everything". |
| 4 | `VirtualSMC.kext` | `Enabled` | `Disabled` | VirtualSMC emulates Apple's SMC chip for hackintosh builds. This is a **real Mac** — it has a real SMC. Enabling VirtualSMC without the actual kext file in the package causes an OpenCore error. |
| 5 | `AppleALC.kext` | `Enabled` | `Disabled` | AppleALC patches audio codecs for hackintosh. Real Mac audio works natively. The kext file wasn't even in the package, so OpenCore would error trying to load it. |
| 6 | `UpdateSMBIOS` | `true` (iMac19,1) | `false` | SMBIOS spoofing makes the machine report as an iMac19,1 instead of MacBookPro15,1. On a real Mac, this overwrites the real serial number and breaks iCloud, Find My Mac, iMessage activation, and warranty status. |
| 7 | `boot-args` | `-v keepsyms=1` | `-v -wegnoegpu agdpmod=pikera -igfxblr` | The boot-args were the defaults from SampleCustom.plist. All three GPU-critical flags were missing. The system would boot with the AMD GPU active, immediately crash. |

**Lesson:** OpenCore's sample configs are hackintosh templates. On a real Mac, most of the hackintosh-specific settings must be disabled. Every field in config.plist must be reviewed against the actual hardware. Blindly using a template is dangerous.

### Attempt 6: Mounting EFI from running macOS — FAILS

**What we tried:** `diskutil mount disk0s1` from a normal macOS boot to access the EFI partition (FAT32/MSDOS filesystem).

**Why it failed:** On macOS 13 Ventura with standard boot security, the `msdos.kext` filesystem driver is not loaded during normal boot. The `diskutil mount` command fails silently or with an error. This means you **cannot access the EFI partition from a running macOS session** on this machine.

**Lesson:** The EFI partition can only be mounted from **Recovery Mode** (Cmd+R at boot), where the security restrictions are relaxed and all filesystem drivers are available. Any OpenCore installation or modification must be done from Recovery Mode.

---

## Destructive Actions That Must Be Avoided

### NEVER reset NVRAM (Cmd+Option+P+R at boot)
Resetting NVRAM wipes `boot-args`, `gpu-policy`, `gpu-power-prefs`, and `gpuswitch`. The system would boot with the AMD GPU active and crash immediately. All the NVRAM configuration that keeps this machine stable would be lost.

### NEVER reset SMC (unless absolutely necessary)
SMC reset can change `gpuswitch` back to its default value (2 = automatic), which allows macOS to activate the failing AMD GPU. Only reset SMC if the machine is completely unresponsive and you have no other option.

### NEVER update macOS without testing
A macOS update could change the sealed system volume, modify GPU driver behavior, or reset NVRAM variables. Before updating, verify that the new version is compatible with the installed OpenCore version and WhateverGreen.

---

## The Working Solution — OpenCore v3

### Architecture

The fix uses a multi-layer approach:

```
Layer 1: Firmware (NVRAM)
  gpuswitch=0           → Tell firmware to prefer integrated GPU
  gpu-policy=%01        → Policy hint for GPU selection
  gpu-power-prefs       → Power management preference for iGPU

Layer 2: Bootloader (OpenCore)
  boot-args: -wegnoegpu → Tell WhateverGreen to disable dGPU at driver level
  boot-args: agdpmod=pikera → Bypass Apple's display policy check
  boot-args: -igfxblr   → Fix Coffee Lake backlight register bug
  boot-args: -v         → Verbose boot (for debugging)

Layer 3: Kernel Extensions (loaded by OpenCore)
  Lilu 1.7.1            → Kernel/kext patcher framework
  WhateverGreen 1.7.0   → GPU-specific patches (reads -wegnoegpu flag)

Layer 4: macOS Power Management
  hibernatemode 0       → Disable hibernation (avoids GPU wake)
  standby 0             → Disable standby (avoids GPU wake)
  powernap 0            → Disable power nap (avoids GPU wake)
```

### How it works

1. **At power-on**, the Mac's firmware reads `gpuswitch=0` from NVRAM and initializes only the Intel UHD 630 for pre-boot display.

2. **OpenCore loads from the EFI partition** (disk0s1). It reads `config.plist` and injects `boot-args` into the macOS boot process. It also loads `Lilu.kext` and `WhateverGreen.kext` into the kernel extension cache.

3. **During macOS kernel init**, Lilu patches the kernel to allow WhateverGreen to hook into GPU driver initialization. WhateverGreen reads the `-wegnoegpu` boot argument and **prevents the AMD Radeon Pro 560X driver from attaching to the hardware**. The GPU is effectively invisible to macOS.

4. **`agdpmod=pikera`** patches Apple's AGDP driver so it doesn't reject the Intel iGPU as a display output. Without this, AGDP would see that the "expected" dGPU is missing and refuse to let the iGPU drive the internal panel.

5. **`-igfxblr`** patches the Intel graphics driver to properly initialize the backlight register on Coffee Lake. Without this, the LCD backlight stays off.

6. **macOS boots normally** with only the Intel UHD 630 active. The Retina display works at 2880x1800. All macOS features (iCloud, Find My, etc.) work because SMBIOS is not spoofed.

### config.plist key settings

```
Misc > Security > Vault: Optional
Misc > Security > SecureBootModel: Disabled
Misc > Security > ScanPolicy: 0
Misc > Security > BlacklistAppleUpdate: true   ← prevents OTA updates that could break OpenCore
Misc > Boot > ShowPicker: true
Misc > Boot > Timeout: 10

Kernel > Add > Lilu.kext: Enabled              ← MUST be first in the array (loads before WhateverGreen)
Kernel > Add > WhateverGreen.kext: Enabled     ← MUST come after Lilu (depends on Lilu's patching API)
Kernel > Add > VirtualSMC.kext: Disabled
Kernel > Add > AppleALC.kext: Disabled
Kernel > Quirks > DisableLinkeditJettison: true ← required for Lilu to work on macOS 12+

NVRAM > Add > 7C436110 > boot-args: -v -wegnoegpu agdpmod=pikera -igfxblr
NVRAM > Add > 7C436110 > csr-active-config: 00000000 (SIP enabled)
NVRAM > Add > 4D1EDE21 > gpuswitch: MA== (base64 of ASCII "0" = force integrated)
NVRAM > Add > FA4CE28D > gpu-power-prefs: AQAAAA== (base64 of bytes 01 00 00 00)

PlatformInfo > UpdateSMBIOS: false
PlatformInfo > UpdateDataHub: false
PlatformInfo > UpdateNVRAM: false

UEFI > Drivers > OpenRuntime.efi: Enabled
UEFI > Drivers > HfsPlus.efi: Enabled
```

**Important config details not obvious from the settings list:**
- **Lilu must load before WhateverGreen** in the `Kernel > Add` array. WhateverGreen is a Lilu plugin — it calls Lilu's API to patch GPU drivers. If WhateverGreen loads first, it has nothing to hook into and `-wegnoegpu` silently fails.
- **`DisableLinkeditJettison: true`** prevents macOS from discarding the `__LINKEDIT` segment from kernel memory. Lilu needs this segment to perform runtime patching. Without it, Lilu fails to load on macOS 12 Monterey and later.
- **`BlacklistAppleUpdate: true`** prevents Apple firmware updates from being offered through Software Update. An accidental firmware update could change boot behavior and break the OpenCore chain.
- **`gpu-power-prefs` must be correctly base64-encoded.** The original v3 config.plist contained `QVFBQUFBPT0=` which decodes to the ASCII string "AQAAAA==" — a double-base64 encoding error. The correct value is `AQAAAA==` which decodes to the raw bytes `01 00 00 00`. This bug was harmless in practice because the correct value was already set directly in NVRAM via `sudo nvram`, but it was fixed in the final config.plist to prevent issues on fresh installs.
- **NVRAM self-healing:** The config.plist `NVRAM > Delete` section clears `boot-args`, `gpuswitch`, and `gpu-power-prefs` on every boot through OpenCore, then `NVRAM > Add` writes the correct values back. This ensures the GPU fix survives NVRAM resets, macOS updates, and accidental changes. The `gpuswitch` variable (GUID `4D1EDE21`) was added to the NVRAM config during the final audit — it was previously only set manually via `sudo nvram` and could have been lost during an update.

### EFI partition layout

```
/Volumes/EFI/
  EFI/
    BOOT/
      BOOTx64.efi          ← OpenCore bootstrap loader
    OC/
      OpenCore.efi          ← OpenCore main binary
      config.plist          ← Configuration (all settings above)
      Drivers/
        OpenRuntime.efi     ← UEFI runtime services
        HfsPlus.efi         ← HFS+ filesystem driver
      Kexts/
        Lilu.kext/          ← Kernel patcher (1.7.1)
        WhateverGreen.kext/ ← GPU patcher (1.7.0)
```

### Software versions

| Component | Version | Purpose |
|-----------|---------|---------|
| OpenCore | 1.0.6 | UEFI bootloader |
| Lilu | 1.7.1 | Kernel extension patcher framework |
| WhateverGreen | 1.7.0 | GPU-specific kernel patches |
| HfsPlus.efi | Apple proprietary | HFS+ filesystem driver for OpenCore |
| OpenRuntime.efi | 1.0.6 (bundled) | UEFI runtime services for OpenCore |

---

## The Install Script

The v3 install script (`INSTALL.sh`) was designed to be run from Recovery Mode terminal. It performs seven steps:

1. **Locate the OpenCore package** — Searches multiple possible volume mount paths (`/Volumes/Macintosh HD - Data/...`, `/Volumes/Data/...`, etc.) because Recovery Mode doesn't always mount volumes at the same path.

2. **Auto-repair missing files** — If `HfsPlus.efi` is missing from `EFI/OC/Drivers/`, it copies it from `downloads/HfsPlus.efi` or falls back to `downloads/OpenCore/X64/EFI/OC/Drivers/OpenHfsPlus.efi`.

3. **Validate all required files** — Checks that every critical file exists and is non-empty: `BOOTx64.efi`, `OpenCore.efi`, `config.plist`, `OpenRuntime.efi`, `HfsPlus.efi`, `Lilu.kext`, `WhateverGreen.kext`.

4. **Find the EFI partition** — Tries `disk0s1`, `disk1s1`, `disk2s1`, then `diskutil list` grep for "EFI".

5. **Mount the EFI partition** — Tries `diskutil mount`, then `mount -t msdos`, then `mount_msdos`. Verifies the mount is writable.

6. **Install OpenCore** — Removes old `EFI/OC` and `EFI/BOOT` directories, copies new ones. Preserves `EFI/APPLE` if it exists.

7. **Verify installation** — Checks all files were copied correctly to the EFI partition.

### Manual install fallback

If the script fails for any reason, the manual commands from Recovery Mode terminal are:
```bash
diskutil mount disk0s1
mkdir -p /Volumes/EFI/EFI
cp -R "/Volumes/Macintosh HD - Data/Users/daftlog/Desktop/OpenCore_GPU_Fix/EFI/BOOT" /Volumes/EFI/EFI/
cp -R "/Volumes/Macintosh HD - Data/Users/daftlog/Desktop/OpenCore_GPU_Fix/EFI/OC" /Volumes/EFI/EFI/
```

---

## The Claude Code Watchdog

A launchd agent (`com.claude.watchdog.plist`) was created to ensure Claude Code would automatically start after every reboot to continue the repair process. This was necessary because the machine was crashing repeatedly and the user needed an autonomous repair agent.

### How it works

- **launchd plist** at `~/Library/LaunchAgents/com.claude.watchdog.plist`:
  - `RunAtLoad: true` — starts immediately at login
  - `KeepAlive: true` — restarts if the watchdog script exits
  - `StartInterval: 60` — launchd restarts the script within 60 seconds if it exits

- **Watchdog script** at `~/claude_watchdog.sh`:
  - Uses a lock file (`/tmp/claude_watchdog.lock`) to prevent multiple instances
  - Internal loop checks every 90 seconds if Claude Code is running via `ps aux | grep claude`
  - If Claude Code is not running, opens Terminal.app via AppleScript and starts Claude Code with the mission file
  - Logs all activity to `~/claude_watchdog.log`

### Timeline from watchdog log

| Date | Event |
|------|-------|
| Jan 29, 15:24 | First watchdog start, initial diagnosis |
| Jan 29, 16:31 | Reboot (likely crash), watchdog restarts Claude |
| Feb 6, 17:19 | System rebooted after 8 days, watchdog restarts Claude |
| Feb 12, 14:27 | Reboot, major debugging session begins |
| Feb 12, 15:28 | Last log entry before crash (WindowServer watchdog timeout) |
| Feb 13, 08:42 | Final boot — v3 installed from Recovery Mode, system stable |

---

## Other Software Fixes Applied

### Third-party kernel extensions removed
These kexts were found in `/Library/Extensions/` and were potential crash contributors:
- **Paragon NTFS** (`com.paragon-software.filesystems.ntfs`) — Third-party filesystem driver, known to cause kernel panics
- **HighPoint RAID** — RAID controller driver, not needed
- **SoftRAID** — Software RAID driver, not needed

### Launch agents disabled
These were renamed from `.plist` to `.plist.disabled` to prevent auto-launch:
- **AnyTrans** — File transfer utility (unnecessary background process)
- **Steam** — Game client (would trigger GPU switching)
- **LastPass** — Password manager agent (unnecessary load)

### Power management
```
hibernatemode 0    → Prevents hibernate (GPU wake can trigger crash)
standby 0          → Prevents deep sleep standby
powernap 0         → Prevents Power Nap (would wake GPU)
lowpowermode 0     → Disabled low power mode
```

### Security configuration
- **SIP (System Integrity Protection):** Enabled (`csr-active-config = 0`)
- **T2 Secure Boot:** Set to "No Security" (required for OpenCore)
- **External Boot:** Allowed (required for OpenCore on EFI partition)

---

## Emergency Recovery Procedures

### If the system boots to a black screen (>3 minutes)
1. Hold the power button for 10 seconds to force shutdown
2. Power on while holding **Option/Alt** key
3. Select "Macintosh HD" directly (this bypasses OpenCore)
4. The system will boot without OpenCore — AMD GPU will be active but the system may survive long enough to troubleshoot

### If you need to remove OpenCore entirely
1. Restart, hold **Cmd+R** for Recovery Mode
2. Open Terminal from Utilities menu
3. Run:
```bash
diskutil mount disk0s1
rm -rf /Volumes/EFI/EFI/OC /Volumes/EFI/EFI/BOOT
```
4. Restart — system boots normally without OpenCore

### If OpenCore v3 stops working after a macOS update
1. Boot with Option/Alt to bypass OpenCore
2. Download updated versions of Lilu and WhateverGreen from their GitHub releases
3. Replace the kexts in `~/Desktop/OpenCore_GPU_Fix/EFI/OC/Kexts/`
4. Re-run the install from Recovery Mode

### Escalation path (if WhateverGreen stops blocking AMD)
- **SSDT-dGPU-Off.aml** — An ACPI table override that disables the discrete GPU at the ACPI firmware level, before any OS driver loads. More aggressive than `-wegnoegpu`. Sample source files exist at `~/Desktop/OpenCore_GPU_Fix/downloads/OpenCore/Docs/AcpiSamples/`
- **DeviceProperties disable-gpu** — Add the AMD GPU's PCI path to the `DeviceProperties > Add` section of config.plist with a `disable-gpu` property

### Nuclear options (if the above fail)
- **Apple Diagnostics** — Restart and hold **D** at boot. If the test returns codes VDH001 through VDH006, the GPU has a confirmed hardware failure. This is useful for warranty claims or confirming the diagnosis.
- **macOS reinstall from Recovery** — Restart with Cmd+R, select "Reinstall macOS". This preserves user data but resets system files. Useful if the sealed system volume is damaged.
- **External display via USB-C/Thunderbolt** — Reduces load on the Intel iGPU by offloading pixels. If WindowServer crashes are happening due to the iGPU struggling with the 2880x1800 Retina panel, an external display at a lower resolution can help.

---

## Boot Process (Normal Operation)

1. Press power button
2. T2 chip initializes, firmware loads
3. **OpenCore picker appears** (10-second timeout) — shows "Macintosh HD"
4. Select "Macintosh HD" or wait for auto-select
5. **Verbose boot text** appears (white text on black background) — this is normal, it's the `-v` flag
6. Screen may flicker or go briefly black — this is the display mode switch
7. **Wait 2-3 minutes** — boot is slower with verbose mode
8. Login screen appears
9. System is running on Intel UHD 630 only

### How to verify the fix is working
```bash
# Should show ONLY "Intel UHD Graphics 630"
system_profiler SPDisplaysDataType | grep "Chipset Model"

# Should show Lilu and WhateverGreen
kextstat | grep -v com.apple

# Should show increasing uptime without unexpected reboots
uptime
```

---

## Key Technical Concepts

### Signed System Volume (SSV)
Introduced in macOS 11 Big Sur. The system partition is an immutable, cryptographically sealed APFS snapshot. The T2 chip verifies the seal at boot. Any modification to `/System` breaks the seal and prevents boot. This is why you cannot simply delete AMD kexts.

### OpenCore
An open-source UEFI bootloader. Originally designed for hackintosh (running macOS on non-Apple hardware), but also useful on real Macs for injecting kernel extensions and boot arguments that macOS doesn't natively support. OpenCore lives on the EFI System Partition (ESP), which is separate from the sealed system volume.

### Lilu
A kernel extension patcher framework. It hooks into the macOS kernel early in the boot process and provides an API for other kexts (like WhateverGreen) to patch kernel code and other kexts on-the-fly, without modifying files on disk.

### WhateverGreen
A Lilu plugin that patches GPU-related kernel extensions. The `-wegnoegpu` flag tells it to prevent the discrete GPU driver from attaching to hardware. The `agdpmod=pikera` flag patches Apple's display policy. The `-igfxblr` flag fixes Intel backlight register initialization.

### EFI System Partition (ESP)
A FAT32 partition (typically disk0s1) that contains bootloader files. On a Mac, Apple's own boot.efi lives here. OpenCore adds its own bootloader (BOOTx64.efi) that runs before macOS loads. This partition is not part of the sealed system volume, so it can be freely modified — but only from Recovery Mode on macOS 13.

### NVRAM Variables (GPU-related)
- `gpuswitch` (GUID: 4D1EDE21) — `0` = integrated only, `1` = discrete only, `2` = automatic
- `gpu-policy` — Binary preference for GPU selection
- `gpu-power-prefs` (GUID: FA4CE28D) — Power management GPU preference
- `boot-args` (GUID: 7C436110) — Kernel boot arguments passed to macOS

---

## File Locations

| File | Purpose |
|------|---------|
| `~/CLAUDE_FIX_COMPUTER_MISSION.md` | Master mission document with status and instructions |
| `~/Desktop/OpenCore_GPU_Fix/` | v3 package (ready to reinstall if needed) |
| `~/Desktop/OpenCore_GPU_Fix/INSTALL.sh` | Automated installer script |
| `~/Desktop/OpenCore_GPU_Fix/LEEME.txt` | Install instructions in Spanish |
| `~/Desktop/OpenCore_GPU_Fix/EFI/` | Complete EFI directory structure |
| `~/Desktop/OpenCore_GPU_Fix/EFI/OC/config.plist` | OpenCore configuration |
| `~/Desktop/OpenCore_GPU_Fix/downloads/` | Original downloaded components |
| `~/Library/LaunchAgents/com.claude.watchdog.plist` | Watchdog launchd agent |
| `~/claude_watchdog.sh` | Watchdog script |
| `~/claude_watchdog.log` | Watchdog activity log |
| `~/.claude/projects/-Users-daftlog/memory/MEMORY.md` | Claude Code persistent memory |

---

## Summary

A MacBook Pro 15,1 (2018) with a failing AMD Radeon Pro 560X was made stable by:

1. **OpenCore 1.0.6** bootloader on the EFI partition
2. **Lilu 1.7.1** + **WhateverGreen 1.7.0** kexts to block the AMD driver
3. **boot-args:** `-v -wegnoegpu agdpmod=pikera -igfxblr`
4. **NVRAM:** `gpuswitch=0`, `gpu-policy=%01`, `gpu-power-prefs` set
5. **Power management:** hibernation, standby, and power nap disabled
6. **Cleanup:** dangerous third-party kexts removed, unnecessary launch agents disabled

It took 3 iterations of the OpenCore config to get it right. The main obstacles were:
- macOS 13's sealed system volume (prevents kext deletion)
- The EFI partition being unmountable from running macOS (requires Recovery Mode)
- Missing `agdpmod=pikera` and `-igfxblr` boot args (causes black screen)
- A build script bug that forgot to copy HfsPlus.efi
- A config.plist that was a barely-modified hackintosh template with 7 critical errors

The system is now stable and should remain so as long as the NVRAM is not reset and macOS updates don't break WhateverGreen compatibility.
