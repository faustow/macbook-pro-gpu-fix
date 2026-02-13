# mbp18noamd

Disable a failing AMD Radeon Pro 560X on a MacBook Pro 15,1 (2018) using OpenCore + WhateverGreen. Forces macOS to run exclusively on the Intel UHD Graphics 630 integrated GPU.

This fix was developed over multiple iterations after the discrete GPU started causing kernel panics and boot loops. It works on macOS 13 Ventura where the Signed System Volume makes it impossible to remove AMD kernel extensions directly.

## The problem

The 2018 MacBook Pro 15-inch ships with dual GPUs: an Intel UHD 630 (integrated) and an AMD Radeon Pro 560X (discrete). A known hardware defect causes the AMD GPU's solder joints or die to degrade over time. Symptoms:

- Random kernel panics during normal use
- Boot loops (panic → reboot → AMD activates → panic again)
- WindowServer crashes (black screen, forced reboot)

Apple never issued a recall. The logic board replacement costs $600-800+.

## The solution

Instead of replacing hardware, this repo contains a software fix that prevents macOS from ever talking to the failing AMD GPU:

1. **OpenCore 1.0.6** — UEFI bootloader that injects kernel extensions and boot arguments before macOS loads
2. **Lilu 1.7.1** — Kernel extension patcher framework
3. **WhateverGreen 1.7.0** — GPU patcher that blocks the AMD driver from attaching to hardware
4. **Four mandatory boot arguments:**

| Flag | What it does |
|------|-------------|
| `-wegnoegpu` | Tells WhateverGreen to disable the discrete GPU at the driver level |
| `agdpmod=pikera` | Bypasses Apple's display policy that blocks the iGPU from driving the internal panel when the dGPU is "missing" |
| `-igfxblr` | Fixes a Coffee Lake backlight register bug that leaves the LCD at zero brightness |
| `-v` | Verbose boot for debugging (optional but recommended) |

## Requirements

- MacBook Pro 15,1 (Mid 2018, 15-inch)
- macOS 13 Ventura (tested on 13.7.8, should work on 11+)
- T2 Secure Boot set to **No Security**
- Access to Recovery Mode (Cmd+R at boot)

## Installation

### 1. Set T2 security (one time only)

1. Shut down the Mac
2. Power on, hold **Cmd+R** until Recovery Mode loads
3. Menu bar: **Utilities > Startup Security Utility**
4. Set Secure Boot to: **No Security**
5. Set External Boot to: **Allow Booting from External Media**

### 2. Copy the package to the Mac

Place the `OpenCore_GPU_Fix/` directory on the Desktop:
```
~/Desktop/OpenCore_GPU_Fix/
```

### 3. Install from Recovery Mode

1. Restart, hold **Cmd+R** for Recovery Mode
2. Open Terminal (**Utilities > Terminal**)
3. Run:
```bash
bash "/Volumes/Macintosh HD - Data/Users/YOUR_USERNAME/Desktop/OpenCore_GPU_Fix/INSTALL.sh"
```
4. If "no such file":
```bash
diskutil mount "Macintosh HD - Data"
```
Then retry step 3.

5. If the script fails entirely, install manually:
```bash
diskutil mount disk0s1
mkdir -p /Volumes/EFI/EFI
cp -R "/Volumes/Macintosh HD - Data/Users/YOUR_USERNAME/Desktop/OpenCore_GPU_Fix/EFI/BOOT" /Volumes/EFI/EFI/
cp -R "/Volumes/Macintosh HD - Data/Users/YOUR_USERNAME/Desktop/OpenCore_GPU_Fix/EFI/OC" /Volumes/EFI/EFI/
```

### 4. Reboot

1. Restart the Mac
2. The OpenCore picker appears (10-second timeout)
3. Select **Macintosh HD**
4. White text on black screen = normal (verbose boot)
5. Wait 2-3 minutes for the login screen

### 5. Verify

```bash
# Should show ONLY Intel UHD Graphics 630
system_profiler SPDisplaysDataType | grep "Chipset Model"

# Should show Lilu and WhateverGreen loaded
kextstat | grep -v com.apple

# Confirm stable uptime
uptime
```

## Recommended NVRAM settings

Apply these from a running macOS session for additional stability:

```bash
# Force integrated GPU at firmware level
sudo nvram 4D1EDE21-7FDE-4053-9556-E55836157E45:gpuswitch=%30

# GPU selection preferences
sudo nvram gpu-policy=%01
sudo nvram FA4CE28D-B62F-4C99-9CC3-6815686E30F9:gpu-power-prefs=%01%00%00%00

# Prevent GPU wake from sleep states
sudo pmset -a hibernatemode 0
sudo pmset -a standby 0
sudo pmset -a powernap 0
```

## Emergency recovery

**Black screen after install (>3 min):**
1. Hold power button 10 seconds to force off
2. Power on while holding **Option/Alt**
3. Select "Macintosh HD" directly (bypasses OpenCore)

**Remove OpenCore entirely:**
1. Restart into Recovery Mode (Cmd+R)
2. Terminal:
```bash
diskutil mount disk0s1
rm -rf /Volumes/EFI/EFI/OC /Volumes/EFI/EFI/BOOT
```
3. Restart normally

## What NOT to do

| Action | Why it's dangerous |
|--------|-------------------|
| Reset NVRAM (Cmd+Option+P+R) | Wipes boot-args, gpu-policy, gpu-power-prefs. AMD GPU activates on next boot. Crash. |
| Reset SMC | Can reset gpuswitch to automatic. AMD activates under load. Crash. |
| Delete AMD kexts from /System | Impossible on macOS 11+. Signed System Volume rejects all writes. |
| Set gpuswitch=2 (automatic) | macOS will switch to AMD under load. Crash. |
| Update macOS without checking | May break OpenCore/WhateverGreen compatibility. |

**Additional notes:**
- Lilu.kext **must load before** WhateverGreen.kext in the config (it's a dependency). The included config.plist already has the correct order.
- `DisableLinkeditJettison` must be `true` in Kernel > Quirks for Lilu to work on macOS 12+.
- `BlacklistAppleUpdate` is set to `true` to prevent accidental firmware updates from breaking the boot chain.

## Repo structure

```
mbp18noamd/
  README.md                    ← This file
  CLAUDE.md                    ← Instructions for Claude Code to reproduce this fix
  INVESTIGATION_EN.md          ← Full technical investigation (English)
  INVESTIGACION_ES.md          ← Full technical investigation (Spanish)
  claude_watchdog.sh           ← Auto-starts Claude Code on boot for autonomous repair
  com.claude.watchdog.plist    ← launchd agent for the watchdog
  OpenCore_GPU_Fix/
    INSTALL.sh                 ← Automated installer (run from Recovery Mode)
    LEEME.txt                  ← User instructions (Spanish)
    EFI/
      BOOT/
        BOOTx64.efi            ← OpenCore 1.0.6 bootstrap
      OC/
        OpenCore.efi           ← OpenCore main binary
        config.plist           ← Tested, working configuration
        Drivers/
          OpenRuntime.efi      ← UEFI runtime services
          HfsPlus.efi          ← HFS+ filesystem driver
        Kexts/
          Lilu.kext/           ← Kernel patcher 1.7.1
          WhateverGreen.kext/  ← GPU patcher 1.7.0
```

## How it was built

This fix took 3 iterations to get right. The full investigation documents every failed attempt and why:

- **v1:** Black screen — missing `agdpmod=pikera` and `-igfxblr` boot args
- **v2:** Install script aborted — HfsPlus.efi not copied to Drivers/. Config had 7 critical bugs inherited from OpenCore's hackintosh template (Vault=Secure, SecureBootModel=Default, VirtualSMC enabled, SMBIOS spoofed, wrong boot-args, etc.)
- **v3:** Works. All bugs fixed. This is what's in this repo.

A Claude Code watchdog (`claude_watchdog.sh` + `com.claude.watchdog.plist`) was created to keep the AI agent running between crashes so it could continue diagnosing and iterating on the fix autonomously.

See `INVESTIGATION_EN.md` for the complete technical breakdown.

## Updating macOS

The config.plist includes self-healing NVRAM: on every boot through OpenCore, the `NVRAM > Delete` section clears stale values and `NVRAM > Add` restores the correct `boot-args`, `gpu-power-prefs`, and `gpuswitch`. This means even if an update resets these variables, the next boot through OpenCore fixes them automatically.

### Minor updates (13.7.x to 13.7.y) — generally safe

1. **Back up the EFI partition first.** From Recovery Mode:
   ```bash
   diskutil mount disk0s1
   cp -R /Volumes/EFI/EFI ~/Desktop/EFI_BACKUP
   ```
2. Check that your Lilu/WhateverGreen versions support the target macOS version at [Lilu releases](https://github.com/acidanthera/Lilu/releases) and [WhateverGreen releases](https://github.com/acidanthera/WhateverGreen/releases)
3. Install the update normally from System Preferences
4. The Mac will reboot several times — each reboot passes through OpenCore
5. After updating, verify: `system_profiler SPDisplaysDataType | grep Chipset` should show only Intel UHD 630

### Major upgrades (13 to 14 Sonoma) — proceed with caution

The MacBook Pro 15,1 is officially supported up to **macOS 14 Sonoma**. It is **NOT supported by macOS 15 Sequoia**.

1. Everything from the minor update steps above, **plus:**
2. **Update OpenCore, Lilu, and WhateverGreen to the latest versions FIRST** — test on your current macOS before upgrading
3. **Create a bootable USB installer** of your current working macOS as a fallback:
   ```bash
   sudo /Applications/Install\ macOS\ Ventura.app/Contents/Resources/createinstallmedia --volume /Volumes/MyUSB
   ```
   Then copy the OpenCore EFI to the USB's EFI partition
4. Download the new macOS and install. Monitor the reboots — OpenCore picker should appear each time

### If the update breaks things

- **Mac won't boot:** Power off (hold 10 sec), power on with **Option/Alt** held, select "EFI Boot" or use your USB installer
- **OpenCore was overwritten:** Restore EFI from backup or reinstall from the `OpenCore_GPU_Fix/` package via Recovery Mode
- **Kexts incompatible:** Boot with Option/Alt to bypass OpenCore, download updated kexts, replace in EFI/OC/Kexts/ from Recovery
- **NVRAM lost:** OpenCore restores it automatically on next boot through OpenCore. If you can't boot through OpenCore, from Recovery: `nvram 7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args="-v -wegnoegpu agdpmod=pikera -igfxblr"`

### NVRAM self-healing (how it works)

Each boot through OpenCore:
1. **Deletes** `boot-args`, `gpuswitch`, `gpu-power-prefs` from NVRAM (clears stale values)
2. **Adds** them back with the correct values from config.plist
3. This guarantees the GPU fix survives NVRAM resets, macOS updates, and accidental changes

| Variable | GUID | Value set by OpenCore |
|----------|------|-----------------------|
| `boot-args` | 7C436110 | `-v -wegnoegpu agdpmod=pikera -igfxblr` |
| `gpuswitch` | 4D1EDE21 | `0` (force integrated) |
| `gpu-power-prefs` | FA4CE28D | `01 00 00 00` |

## Applicability

This fix should work on any MacBook Pro 15,1 (2018, 15-inch) with a failing AMD Radeon Pro 560X or 555X. It may also apply to:

- MacBook Pro 11,5 (Mid 2015, 15-inch) — AMD Radeon R9 M370X
- MacBook Pro 16,1 (2019, 16-inch) — AMD Radeon Pro 5300M/5500M

The `config.plist` would need adjustments for different models (different iGPU, different backlight behavior). The core approach (OpenCore + Lilu + WhateverGreen + `-wegnoegpu`) is the same.

## License

The OpenCore bootloader, Lilu, and WhateverGreen are open-source projects by [Acidanthera](https://github.com/acidanthera). HfsPlus.efi is proprietary Apple code. The scripts and documentation in this repo are provided as-is for educational and repair purposes.
