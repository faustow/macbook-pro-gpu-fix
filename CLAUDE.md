# MacBook Pro 2018 (15,1) — Disable Failing AMD GPU

You are helping a user fix a MacBook Pro 15,1 (2018, 15-inch) whose AMD Radeon Pro 560X discrete GPU is failing, causing kernel panics and reboots. The fix is to install OpenCore bootloader with WhateverGreen to disable the AMD GPU at the driver level, forcing macOS to use only the Intel UHD Graphics 630 integrated GPU.

Read `INVESTIGATION_EN.md` in this directory for the full technical investigation, failure history, and root cause analysis. Read `INVESTIGACION_ES.md` for the Spanish version.

---

## Critical rules — violations will brick or crash the machine

1. **NEVER suggest resetting NVRAM** (Cmd+Option+P+R). This wipes boot-args, gpu-policy, gpu-power-prefs, and gpuswitch. The machine will boot with the AMD GPU active and crash immediately.

2. **NEVER suggest resetting SMC** unless the machine is completely unresponsive. SMC reset can change gpuswitch back to automatic (2), which activates the failing AMD GPU.

3. **NEVER try to delete AMD kexts from /System.** macOS 11+ uses a Signed System Volume. Writes to /System are impossible, even as root, even with SIP disabled. Do not waste time on this.

4. **NEVER set gpuswitch=2 (automatic).** Must always be gpuswitch=0 (force integrated only). With automatic, macOS will activate the failing AMD GPU under load.

5. **NEVER use OpenCore's SampleCustom.plist as-is on a real Mac.** It is a hackintosh template. On a real Mac, you must set: Vault=Optional, SecureBootModel=Disabled, UpdateSMBIOS=false, and disable VirtualSMC/AppleALC kexts. See the config section below.

6. **The EFI partition (disk0s1) CANNOT be mounted from running macOS 13.** The msdos.kext filesystem driver does not load during normal boot. All EFI partition work MUST be done from Recovery Mode (Cmd+R at boot).

7. **NEVER update macOS** without first verifying compatibility with the installed OpenCore, Lilu, and WhateverGreen versions.

---

## Diagnosis phase

Run these commands to assess the machine's current state:

```bash
# What GPU(s) are active?
system_profiler SPDisplaysDataType | grep -A5 "Chipset Model"

# Are Lilu and WhateverGreen loaded?
kextstat | grep -v com.apple

# Current NVRAM GPU settings
nvram boot-args 2>/dev/null
nvram gpu-policy 2>/dev/null
nvram FA4CE28D-B62F-4C99-9CC3-6815686E30F9:gpu-power-prefs 2>/dev/null
nvram 4D1EDE21-7FDE-4053-9556-E55836157E45:gpuswitch 2>/dev/null

# System uptime (frequent reboots = GPU panics)
uptime

# Recent panic logs
ls -lt /Library/Logs/DiagnosticReports/ | head -10

# Hardware model (must be MacBookPro15,1)
sysctl hw.model

# Power management (hibernatemode should be 0)
pmset -g custom | grep -E "hibernatemode|standby|powernap"

# Dangerous third-party kexts
kextstat | grep -v com.apple
ls /Library/Extensions/
```

### Interpreting results

- If **AMD Radeon** appears in SPDisplaysDataType → the dGPU is active and needs to be disabled
- If **only Intel UHD 630** appears → the fix is already working
- If **boot-args** does not contain `-wegnoegpu agdpmod=pikera -igfxblr` → OpenCore is not configured correctly or not installed
- If **gpuswitch** is not 0 → set it to 0 immediately
- If **Lilu/WhateverGreen** are not in kextstat → OpenCore is not injecting kexts (config issue or not installed)

---

## Fix implementation

### Phase 1: Immediate NVRAM stabilization (from running macOS)

These reduce crash frequency but do not fully fix the problem. Apply them first to buy time:

```bash
# Force integrated GPU only
sudo nvram 4D1EDE21-7FDE-4053-9556-E55836157E45:gpuswitch=%30  # ASCII "0"

# GPU policy and power preferences
sudo nvram gpu-policy=%01
sudo nvram FA4CE28D-B62F-4C99-9CC3-6815686E30F9:gpu-power-prefs=%01%00%00%00

# Disable sleep/hibernate (GPU wake = crash)
sudo pmset -a hibernatemode 0
sudo pmset -a standby 0
sudo pmset -a powernap 0
sudo pmset -a lowpowermode 0
```

### Phase 2: Remove crash-contributing software (from running macOS)

```bash
# Remove dangerous third-party kexts
sudo kextunload -b com.paragon-software.filesystems.ntfs 2>/dev/null
sudo rm -rf /Library/Extensions/ntfs.kext
sudo rm -rf /Library/Extensions/HighPointRR.kext
sudo rm -rf /Library/Extensions/SoftRAID.kext
# Rebuild kext cache
sudo kextcache -invalidate /

# Disable unnecessary launch agents that may trigger GPU switching
cd ~/Library/LaunchAgents
for f in *Steam* *AnyTrans* *LastPass*; do
    [ -f "$f" ] && mv "$f" "${f}.disabled"
done
```

### Phase 3: Build OpenCore package (from running macOS)

Download the components:

```bash
WORKDIR=~/Desktop/OpenCore_GPU_Fix
mkdir -p "$WORKDIR/downloads" "$WORKDIR/EFI/BOOT" "$WORKDIR/EFI/OC/Drivers" "$WORKDIR/EFI/OC/Kexts"

# Download OpenCore (check https://github.com/acidanthera/OpenCorePkg/releases for latest)
# Download Lilu (check https://github.com/acidanthera/Lilu/releases for latest)
# Download WhateverGreen (check https://github.com/acidanthera/WhateverGreen/releases for latest)
# Download HfsPlus.efi (from https://github.com/acidanthera/OcBinaryData/blob/master/Drivers/HfsPlus.efi)
```

Assemble the EFI structure:

```bash
# From OpenCore X64 release:
cp downloads/OpenCore/X64/EFI/BOOT/BOOTx64.efi  "$WORKDIR/EFI/BOOT/"
cp downloads/OpenCore/X64/EFI/OC/OpenCore.efi    "$WORKDIR/EFI/OC/"
cp downloads/OpenCore/X64/EFI/OC/Drivers/OpenRuntime.efi "$WORKDIR/EFI/OC/Drivers/"

# HfsPlus.efi — MUST be in Drivers/, not just downloads/
cp downloads/HfsPlus.efi "$WORKDIR/EFI/OC/Drivers/"

# Kexts — only Lilu and WhateverGreen, nothing else
cp -R downloads/Lilu/Lilu.kext "$WORKDIR/EFI/OC/Kexts/"
cp -R downloads/WhateverGreen/WhateverGreen.kext "$WORKDIR/EFI/OC/Kexts/"
```

### Phase 4: Create config.plist

Start from OpenCore's `SampleCustom.plist` but make ALL of the following changes. Missing any one of these will cause boot failure:

**NVRAM section:**
```xml
<key>7C436110-AB2A-4BBB-A880-FE41995C9F82</key>
<dict>
    <key>boot-args</key>
    <string>-v -wegnoegpu agdpmod=pikera -igfxblr</string>
    <key>csr-active-config</key>
    <data>AAAAAA==</data>  <!-- SIP enabled = 0x00000000 -->
</dict>
```

Also add these NVRAM variables (both in `Add` and `Delete` sections):

```xml
<!-- Force integrated GPU at firmware level -->
<key>4D1EDE21-7FDE-4053-9556-E55836157E45</key>
<dict>
    <key>gpuswitch</key>
    <data>MA==</data>  <!-- ASCII "0" = force integrated -->
</dict>

<!-- GPU power management preference -->
<key>FA4CE28D-B62F-4C99-9CC3-6815686E30F9</key>
<dict>
    <key>gpu-power-prefs</key>
    <data>AQAAAA==</data>  <!-- bytes 01 00 00 00 — NOT double-base64 encoded -->
</dict>
```

The `NVRAM > Delete` section must list these same keys so OpenCore clears stale values before writing fresh ones. This self-healing mechanism ensures the GPU fix survives NVRAM resets and macOS updates.

**Security section (Misc > Security):**
```
Vault: Optional              (NOT Secure — we have no vault hash files)
SecureBootModel: Disabled    (NOT Default — conflicts with T2 "No Security")
ScanPolicy: 0                (NOT 17760515 — too restrictive, won't find APFS volume)
BlacklistAppleUpdate: true   (prevents OTA firmware updates that could break OpenCore)
```

**Kernel > Add — enable ONLY these, IN THIS ORDER (Lilu first, WhateverGreen second):**
```
Lilu.kext: Enabled              ← MUST be first. WhateverGreen depends on Lilu's API.
WhateverGreen.kext: Enabled     ← MUST come after Lilu. Will silently fail otherwise.
```

**Kernel > Quirks:**
```
DisableLinkeditJettison: true   ← Required for Lilu on macOS 12+. Without it, Lilu cannot patch.
```

**Kernel > Add — disable ALL of these (they are hackintosh-only):**
```
VirtualSMC.kext: Disabled    (real Mac has real SMC)
AppleALC.kext: Disabled      (real Mac audio works natively)
IntelMausi.kext: Disabled    (not needed)
VoodooPS2*.kext: Disabled    (not needed)
AirportBrcmFixup: Disabled   (not needed)
All others: Disabled
```

**PlatformInfo — do NOT spoof on a real Mac:**
```
UpdateSMBIOS: false
UpdateDataHub: false
UpdateNVRAM: false
SpoofVendor: false
```

**Boot section (Misc > Boot):**
```
ShowPicker: true
Timeout: 10
```

**UEFI > Drivers — enable ONLY:**
```
OpenRuntime.efi: Enabled
HfsPlus.efi: Enabled
All others: Disabled
```

### Phase 5: Prepare install script

Create an `INSTALL.sh` that:
1. Searches multiple volume paths for the package (Recovery Mode mount points vary)
2. Auto-repairs HfsPlus.efi if missing from Drivers/
3. Validates all required files exist and are non-empty
4. Finds the EFI partition (try disk0s1, disk1s1, disk2s1, then `diskutil list`)
5. Mounts EFI via multiple methods (`diskutil mount`, `mount -t msdos`, `mount_msdos`)
6. Verifies mount is writable
7. Copies EFI/BOOT and EFI/OC to the EFI partition
8. Verifies the copy succeeded

### Phase 6: T2 security configuration (one-time, from Recovery Mode)

The user must do this before OpenCore will work:
1. Boot into Recovery Mode (Cmd+R)
2. Utilities > Startup Security Utility
3. Set Secure Boot to: **No Security**
4. Set External Boot to: **Allow Booting from External Media**

### Phase 7: Install OpenCore (from Recovery Mode)

The user must:
1. Restart, hold Cmd+R for Recovery Mode
2. Open Terminal (Utilities > Terminal)
3. Run the install script:
```bash
bash "/Volumes/Macintosh HD - Data/Users/<username>/Desktop/OpenCore_GPU_Fix/INSTALL.sh"
```
4. If "no such file": `diskutil mount "Macintosh HD - Data"` then retry
5. If script fails, manual fallback:
```bash
diskutil mount disk0s1
mkdir -p /Volumes/EFI/EFI
cp -R "/Volumes/Macintosh HD - Data/Users/<username>/Desktop/OpenCore_GPU_Fix/EFI/BOOT" /Volumes/EFI/EFI/
cp -R "/Volumes/Macintosh HD - Data/Users/<username>/Desktop/OpenCore_GPU_Fix/EFI/OC" /Volumes/EFI/EFI/
```

### Phase 8: Reboot and verify

After restarting:
1. OpenCore picker appears (10-second timeout)
2. Select "Macintosh HD"
3. Verbose boot text (white on black) is normal — wait 2-3 minutes
4. Login screen appears

Verify:
```bash
system_profiler SPDisplaysDataType | grep "Chipset Model"  # Only Intel UHD 630
kextstat | grep -v com.apple                                # Lilu + WhateverGreen
uptime                                                      # Stable, no reboots
```

---

## Boot args reference

All four are mandatory for MacBook Pro 15,1 with dGPU disabled:

| Flag | Purpose | What happens without it |
|------|---------|------------------------|
| `-wegnoegpu` | Tells WhateverGreen to prevent AMD dGPU driver from attaching to hardware | AMD driver loads, talks to failing GPU, kernel panic |
| `agdpmod=pikera` | Bypasses Apple's Graphics Device Policy board-id check | AGDP blocks iGPU from driving internal display, black screen |
| `-igfxblr` | Fixes Intel Coffee Lake backlight register initialization bug | LCD backlight stays at zero brightness, screen appears black |
| `-v` | Verbose boot (optional but recommended for debugging) | Silent boot, harder to diagnose issues |

---

## Troubleshooting decision trees

Use these flowcharts to diagnose and fix issues. Follow them step by step.

### Decision tree: User says "my Mac keeps crashing/restarting"

```
1. Can you boot into macOS at all (even briefly)?
   YES → Run diagnostics (see "Diagnosis phase" above)
       → Is AMD Radeon showing in SPDisplaysDataType?
           YES → OpenCore/WhateverGreen not working → go to "OpenCore not injecting kexts"
           NO  → GPU fix is working, crash is from something else → check panic logs
   NO  → go to step 2

2. Does the OpenCore picker appear at boot?
   YES → Select Macintosh HD, does it boot?
       YES → Run diagnostics above
       NO  → Black screen? → go to "Black screen after OpenCore install"
           → Kernel panic text? → go to "System boots but crashes/panics"
   NO  → go to step 3

3. Hold Option/Alt at power on. Does Startup Manager appear?
   YES → Is there an "EFI Boot" option?
       YES → Select it (loads OpenCore) → go to step 2
       NO  → OpenCore is not installed or EFI was wiped → go to "Reinstall OpenCore"
   NO  → Hardware issue (T2 chip, keyboard, etc.) → Nuclear options
```

### Decision tree: User says "I accidentally reset NVRAM"

```
1. OpenCore's NVRAM self-healing should fix this automatically.
   Restart and let OpenCore boot normally.

2. If the Mac crash-loops before reaching OpenCore:
   → Power off (hold 10 sec)
   → Power on with Option/Alt held
   → Select "EFI Boot" if it appears (loads OpenCore, which restores NVRAM)
   → If no "EFI Boot": select "Macintosh HD" directly

3. If nothing works (crash loop, can't reach any boot option):
   → Power off, power on with Cmd+R → Recovery Mode → Terminal
   → Run these commands:
   nvram 7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args="-v -wegnoegpu agdpmod=pikera -igfxblr"
   nvram 4D1EDE21-7FDE-4053-9556-E55836157E45:gpuswitch=%30
   nvram FA4CE28D-B62F-4C99-9CC3-6815686E30F9:gpu-power-prefs=%01%00%00%00
   nvram gpu-policy=%01
   → Restart
```

### Decision tree: User says "I updated macOS and now it won't boot"

```
1. Power off, power on with Option/Alt
   → Does "EFI Boot" appear? Select it → OpenCore should load
   → If OpenCore loads and Mac boots → NVRAM self-healing worked, verify with diagnostics

2. If OpenCore picker appears but Mac won't boot from Macintosh HD:
   → Kext incompatibility likely → boot without OpenCore (Option/Alt > Macintosh HD)
   → From running macOS (may crash, work fast):
     Check kext versions: defaults read ~/Desktop/OpenCore_GPU_Fix/EFI/OC/Kexts/Lilu.kext/Contents/Info.plist CFBundleShortVersionString
   → Download latest Lilu + WhateverGreen from Acidanthera GitHub
   → Replace in OpenCore_GPU_Fix/EFI/OC/Kexts/
   → Reinstall to EFI from Recovery Mode

3. If OpenCore picker does NOT appear (macOS update overwrote BOOTx64.efi):
   → Recovery Mode (Cmd+R) → Terminal → reinstall OpenCore:
   diskutil mount disk0s1
   mkdir -p /Volumes/EFI/EFI
   cp -R "/Volumes/Macintosh HD - Data/Users/daftlog/Desktop/OpenCore_GPU_Fix/EFI/BOOT" /Volumes/EFI/EFI/
   cp -R "/Volumes/Macintosh HD - Data/Users/daftlog/Desktop/OpenCore_GPU_Fix/EFI/OC" /Volumes/EFI/EFI/
   → Restart

4. If Recovery Mode also fails:
   → Internet Recovery (Cmd+Option+R) — WARNING: boots without OpenCore, AMD may activate
   → Work fast, reinstall macOS, then redo OpenCore install
```

### Decision tree: User says "I reset SMC"

```
1. SMC reset (Shift+Control+Option+Power) may change gpuswitch to automatic.
   OpenCore's NVRAM self-healing restores gpuswitch=0 on every boot through OpenCore.
   → Simply restart and let OpenCore boot. It should fix itself.

2. If the Mac crashes before reaching OpenCore:
   → Same steps as "I accidentally reset NVRAM" above (step 2 and 3)
```

### Troubleshooting: specific symptoms

### Black screen after OpenCore install
- The system booted but the display is off
- Recovery: Power off (hold 10 sec), power on with Option/Alt, select "Macintosh HD" directly
- Check: Are `agdpmod=pikera` and `-igfxblr` both in boot-args? Both are required.
- If both are present and it's still black: escalate to SSDT-dGPU-Off (ACPI-level disable)

### OpenCore picker does not appear
- T2 Secure Boot may still be set to "Full Security" or "Medium Security" — must be "No Security"
- External Boot may not be allowed — must be "Allow Booting from External Media"
- EFI partition may not have the files — verify from Recovery Mode:
  ```bash
  diskutil mount disk0s1
  ls /Volumes/EFI/EFI/OC/   # Should show OpenCore.efi, config.plist, Drivers/, Kexts/
  ls /Volumes/EFI/EFI/BOOT/  # Should show BOOTx64.efi
  ```
- A macOS update may have overwritten BOOTx64.efi → reinstall from package

### OpenCore not injecting kexts
- Symptom: AMD shows in SPDisplaysDataType, or kextstat doesn't show Lilu/WhateverGreen
- Check boot-args: `nvram 7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args` — must contain `-wegnoegpu`
- Check config.plist on EFI: Lilu.kext must be Enabled and listed BEFORE WhateverGreen.kext in Kernel > Add
- Check `DisableLinkeditJettison: true` in Kernel > Quirks
- Check that kext binaries exist and are non-empty in EFI/OC/Kexts/

### System boots but crashes/panics
- Boot with Option/Alt to bypass OpenCore
- Check `/Library/Logs/DiagnosticReports/` for panic logs
- Read panic logs from Recovery if system won't stay up: `ls -lt "/Volumes/Macintosh HD - Data/Library/Logs/DiagnosticReports/" | head -5`
- If panic mentions AMD: WhateverGreen isn't blocking it → check kext loading order (Lilu must load before WhateverGreen), check boot-args
- If WindowServer crash: Intel iGPU struggling with 2880x1800 → try lower resolution
- If unrelated panic: check for other problematic kexts in /Library/Extensions/

### "MISSING: HfsPlus.efi" error during install
- The build step forgot to copy it to EFI/OC/Drivers/
- Fix: `cp downloads/HfsPlus.efi EFI/OC/Drivers/HfsPlus.efi`
- Alternative: `cp downloads/OpenCore/X64/EFI/OC/Drivers/OpenHfsPlus.efi EFI/OC/Drivers/HfsPlus.efi`

### OpenCore says "Vault check failed" or similar
- config.plist has `Vault: Secure` — change to `Vault: Optional`
- We don't generate vault hash files for this use case

### Cannot mount EFI partition
- From running macOS 13: this is expected, it will not work
- From Recovery Mode: `diskutil mount disk0s1`
- If that fails: `mkdir -p /tmp/efi && mount -t msdos /dev/disk0s1 /tmp/efi`
- If that fails: `mount_msdos /dev/disk0s1 /tmp/efi`
- Check `diskutil list internal` to confirm which disk has the EFI partition

### Reinstall OpenCore
From Recovery Mode Terminal:
```bash
diskutil mount disk0s1
mkdir -p /Volumes/EFI/EFI
cp -R "/Volumes/Macintosh HD - Data/Users/daftlog/Desktop/OpenCore_GPU_Fix/EFI/BOOT" /Volumes/EFI/EFI/
cp -R "/Volumes/Macintosh HD - Data/Users/daftlog/Desktop/OpenCore_GPU_Fix/EFI/OC" /Volumes/EFI/EFI/
```
If "Macintosh HD - Data" is not mounted: `diskutil mount "Macintosh HD - Data"` first.

### Checking and updating kext versions
```bash
# Check installed versions on EFI (from Recovery Mode after mounting disk0s1):
defaults read /Volumes/EFI/EFI/OC/Kexts/Lilu.kext/Contents/Info.plist CFBundleShortVersionString
defaults read /Volumes/EFI/EFI/OC/Kexts/WhateverGreen.kext/Contents/Info.plist CFBundleShortVersionString

# Check versions in the Desktop backup package:
defaults read ~/Desktop/OpenCore_GPU_Fix/EFI/OC/Kexts/Lilu.kext/Contents/Info.plist CFBundleShortVersionString
defaults read ~/Desktop/OpenCore_GPU_Fix/EFI/OC/Kexts/WhateverGreen.kext/Contents/Info.plist CFBundleShortVersionString

# Latest releases (check these before any macOS update):
# https://github.com/acidanthera/Lilu/releases/latest
# https://github.com/acidanthera/WhateverGreen/releases/latest
# https://github.com/acidanthera/OpenCorePkg/releases/latest
```

To update kexts: download new .kext bundles, replace in `~/Desktop/OpenCore_GPU_Fix/EFI/OC/Kexts/`, then reinstall to EFI from Recovery Mode.

When updating OpenCore itself: `BOOTx64.efi`, `OpenCore.efi`, and `OpenRuntime.efi` MUST all be from the same release. Check `Differences.pdf` in the OpenCore release for config.plist changes between versions.

### EFI partition corruption
If `diskutil mount disk0s1` succeeds but files are missing or garbled:
```bash
# From Recovery Mode — reformat EFI partition and reinstall
diskutil unmount disk0s1
newfs_msdos -v EFI /dev/disk0s1
diskutil mount disk0s1
mkdir -p /Volumes/EFI/EFI
cp -R "/Volumes/Macintosh HD - Data/Users/daftlog/Desktop/OpenCore_GPU_Fix/EFI/BOOT" /Volumes/EFI/EFI/
cp -R "/Volumes/Macintosh HD - Data/Users/daftlog/Desktop/OpenCore_GPU_Fix/EFI/OC" /Volumes/EFI/EFI/
```

---

## Escalation: SSDT-dGPU-Off (if WhateverGreen is not enough)

If `-wegnoegpu` fails to block the AMD GPU (panic logs still mention AMD after WhateverGreen is confirmed loaded), the next step is an ACPI-level disable:

1. Find the PCI path of the AMD GPU: `ioreg -l | grep -A5 "AMD"` or check `system_profiler SPDisplaysDataType`
2. Create an SSDT that calls `_OFF` or `_PS3` on the dGPU's ACPI device at boot
3. Compile the .dsl to .aml using `iasl`
4. Place the .aml in `EFI/OC/ACPI/`
5. Enable it in config.plist under `ACPI > Add`

Sample SSDT sources: `OpenCore/Docs/AcpiSamples/Source/`

---

## Updating macOS

The config.plist has self-healing NVRAM: on every boot through OpenCore, it deletes and re-adds `boot-args`, `gpuswitch`, and `gpu-power-prefs` with the correct values. This survives NVRAM resets and macOS updates.

### Minor updates (13.7.x → 13.7.y)

1. Back up EFI partition first (from Recovery: `diskutil mount disk0s1 && cp -R /Volumes/EFI/EFI ~/Desktop/EFI_BACKUP`)
2. Verify kext compatibility at Acidanthera GitHub releases
3. Install normally — each reboot passes through OpenCore
4. Verify after update: only Intel UHD 630 active, Lilu+WhateverGreen loaded

### Major upgrades (13 → 14 Sonoma)

- MacBook Pro 15,1 is supported up to **Sonoma 14**, NOT Sequoia 15
- Update OpenCore + Lilu + WhateverGreen to latest BEFORE upgrading macOS
- Create a bootable USB installer of current working macOS as fallback
- Copy OpenCore EFI to the USB's EFI partition for emergency boot

### If update breaks things

- Boot with **Option/Alt** to bypass OpenCore temporarily
- Restore EFI from backup via Recovery Mode
- If NVRAM lost: OpenCore restores it on next boot through OpenCore
- If OpenCore overwritten: reinstall from the `OpenCore_GPU_Fix/` package

### Key protections in config.plist

- `run-efi-updater: No` — prevents macOS installer from touching EFI firmware
- `BlacklistAppleUpdate: true` — blocks OTA firmware updates
- `RequestBootVarRouting: true` — isolates OpenCore boot variables from macOS
- NVRAM Delete+Add cycle restores `boot-args`, `gpuswitch`, `gpu-power-prefs` on every boot

---

## Nuclear options (last resort)

- **Apple Diagnostics** — Restart + hold **D**. Codes VDH001-VDH006 = confirmed GPU hardware failure. Useful for warranty claims.
- **macOS reinstall** from Recovery (Cmd+R) — Preserves data, resets system files. Use if sealed system volume is damaged.
- **External display** via USB-C/Thunderbolt — Reduces iGPU load if WindowServer crashes at 2880x1800.

---

## Watchdog (optional, for autonomous repair)

If the machine is crash-looping and the user needs Claude Code to auto-start on each boot to continue the repair:

**LaunchAgent** (`~/Library/LaunchAgents/com.claude.watchdog.plist`):
- RunAtLoad: true, KeepAlive: true
- Restarts the watchdog script within 60 seconds if it exits (StartInterval)
- Script's internal loop checks every 90 seconds

**Watchdog script** (`~/claude_watchdog.sh`):
- Checks if Claude Code process is running
- If not, opens Terminal via AppleScript and starts Claude Code with the mission prompt
- Uses a lock file to prevent multiple instances
- Logs all activity to `~/claude_watchdog.log`

This should be disabled once the machine is stable:
```bash
launchctl unload ~/Library/LaunchAgents/com.claude.watchdog.plist
```

---

## File inventory

| File | Purpose |
|------|---------|
| `CLAUDE.md` | This file — instructions for Claude Code |
| `INVESTIGATION_EN.md` | Full technical investigation (English) |
| `INVESTIGACION_ES.md` | Full technical investigation (Spanish) |

The OpenCore fix package should be at `~/Desktop/OpenCore_GPU_Fix/`:
| Path | Purpose |
|------|---------|
| `INSTALL.sh` | Automated installer for Recovery Mode |
| `LEEME.txt` | User-facing instructions in Spanish |
| `EFI/BOOT/BOOTx64.efi` | OpenCore bootstrap |
| `EFI/OC/OpenCore.efi` | OpenCore main binary |
| `EFI/OC/config.plist` | OpenCore configuration |
| `EFI/OC/Drivers/OpenRuntime.efi` | UEFI runtime driver |
| `EFI/OC/Drivers/HfsPlus.efi` | HFS+ filesystem driver |
| `EFI/OC/Kexts/Lilu.kext/` | Kernel patcher framework |
| `EFI/OC/Kexts/WhateverGreen.kext/` | GPU patcher |
