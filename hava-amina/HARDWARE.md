---
type: Hardware Reference
title: "hava-amina hardware reference"
description: Physical hardware inventory and stable drive/device identifiers for the hava-amina AMD system (CORSAIR AI WORKSTATION 300, Ryzen AI MAX+ 395, 2× 2 TB NVMe), for reproducible Ignition builds.
resource: ssh://keelan@192.168.0.46/
tags: [hardware, hardware-reference, ignition, fedora-coreos, storage, drives, amd, strix-halo]
status: stable
stale_after: 2027-09-07T00:00:00Z
generated: { by: pi-coding-agent, at: 2026-09-07 }
sources:
  - id: live-system-scan
    resource: "hardware introspection commands (lsblk, /dev/disk/by-id, nvme list, lspci -k/-vv, dmidecode, dmesg, dnf provides) run against keelan@192.168.0.46 on 2026-09-07"
    title: Live system introspection of hava-amina
    author: pi-coding-agent
---

# Hardware Reference — hava-amina

Purpose: hardware reference for building reproducible Ignition configs for this
machine. Only physical hardware and stable device identifiers are documented
here — **not** the current partition layout, filesystems, or software config.

Captured: 2026-09-07, right after the fresh `ucore-minimal:stable` install
(kernel 7.1.8-200.fc44, ignition platform = metal).[^live-system-scan]

[^live-system-scan]: Live system introspection of hava-amina

## System

| Component | Detail |
|---|---|
| Board | CORSAIR AI WORKSTATION 300 (Strix Halo mini-PC) |
| BIOS | AXB35-02 3.07 (2025-10-16), power/performance mode set to “performance” (set before the 2026-09-07 install; not the fix for the BT enumeration issue — see USB section) |
| CPU | AMD Ryzen AI MAX+ 395 (Strix Halo) — 16 cores / 32 threads, up to ~5.19 GHz, single socket, 1 NUMA node |
| RAM | 128 GiB LPDDR5X, **soldered** (SPD shows 8 × 16 GiB Micron `MT62F4G32D8DV-023 WT` at 8532 MT/s, configured 8000 MT/s; all SPD locators read "DIMM 0"). Not upgradeable |
| iGPU | AMD Radeon 8060S (PCI `c6:00.0`, Strix Halo display controller), amdgpu — open-source driver, no extras needed |
| NPU | AMD XDNA2 (PCI `c7:00.1`), in-kernel `amdxdna` driver |

## Drives (stable identifiers)

Two **identical** white-label 2 TB NVMe drives — same model string `PCIe SSD`
(no vendor identity), same controller (Phison PS5027-E27T, PCIe4, DRAM-less),
same firmware `ERFM30.1`. Disambiguate **only by serial/EUI**; the model name
tells you nothing. Both report 512-byte logical and physical sectors.

### 1. Boot drive — 2 TB white-label NVMe (Phison PS5027-E27T)

- **Model string:** `PCIe SSD` (vendor: none)
- **Serial:** `511250820055001423`
- **EUI-64:** `00000000000000006479a7aeda2005be`
- **NVMe firmware:** ERFM30.1
- **PCI:** `c4:00.0`, linked at **Gen4 x4** (16GT/s, confirmed `LnkSta`)
- by-id paths (all equivalent, pick one and be consistent):
  - `/dev/disk/by-id/nvme-PCIe_SSD_511250820055001423`
  - `/dev/disk/by-id/nvme-eui.00000000000000006479a7aeda2005be`

### 2. Second 2 TB white-label NVMe (Phison PS5027-E27T)

- **Model string:** `PCIe SSD` (vendor: none)
- **Serial:** `511250820055001080`
- **EUI-64:** `00000000000000006479a7aed5f0000e`
- **NVMe firmware:** ERFM30.1
- **PCI:** `c5:00.0`, linked at **Gen4 x4** (16GT/s, confirmed `LnkSta`)
- by-id paths:
  - `/dev/disk/by-id/nvme-PCIe_SSD_511250820055001080`
  - `/dev/disk/by-id/nvme-eui.00000000000000006479a7aed5f0000e`
- **Note:** at capture this drive already carried a single 1.9 TB
  partition (`nvme1n1p1`) from before the install. If it is ever used for
  storage, wipe and build it deliberately — do not assume it is clean.

### Slot topology summary (for future disk-layout planning)

| Location | PCI addr | Link | Drive |
|---|---|---|---|
| M.2 slot 1 | c4:00.0 | Gen4 x4 | white-label 2 TB — boot drive |
| M.2 slot 2 | c5:00.0 | Gen4 x4 | white-label 2 TB |

Strix Halo exposes the M.2 slots through the SoC's GPP/USB4 bridges; there is
no chipset-level M.2 and no SATA at all.

## GPUs

| # | PCI addr | Model | Driver |
|---|---|---|---|
| iGPU | c6:00.0 | AMD Radeon 8060S (Strix Halo) | amdgpu (open-source, in the plain `ucore-minimal:stable` image) |

No discrete GPU, no NVIDIA — the plain `stable` tag is the correct rebase
target.

## Network

### Wired — RTL8125 2.5GbE (the ignition NIC)

- **PCI:** `c1:00.0`, vendor/device `10ec:8125` (Realtek RTL8125, rev 05)
- **MAC:** `84:47:09:73:b0:61`
- **netdev:** `eno1` — a slot-name override ("OnBoard LAN") beats the
  PCI-derived name, so this is `eno1`, not `enp…`
- **Driver:** `r8169` (in-kernel). Verified at 2500 Mb/s full duplex

### Wi-Fi 7 + Bluetooth — MediaTek MT7925 (RZ717) — ⚠ missing firmware by default

- **PCI:** `c3:00.0`, MediaTek MT7925 Wi-Fi 7 160 MHz (Wi-Fi + BT combo)
- **Driver:** `mt7925e` (in-kernel)
- **Status at capture: NOT WORKING.** The `mediatek/mt7925/` firmware files
  are **not** in the `linux-firmware` package on FCOS — they live in the
  separate **`mt7xxx-firmware`** package. Without it, the driver fails with
  `Direct firmware load for mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin
  failed with error -2` in a retry loop that **floods the console at every
  boot** (looks like "bluetooth driver" spam; it is this Wi-Fi/BT combo card),
  and no `wlan*`/Bluetooth interfaces appear.
- **Fix (applied at capture):** `sudo rpm-ostree install mt7xxx-firmware` +
  reboot. The package is also in `install-user-packages.service` in
  `hava-amina.bu`, so a fresh install gets it automatically. Wi-Fi and
  Bluetooth both work after this (Wi-Fi interface is `wlp195s0` —
  PCI-derived name, not `wlan0`). The Bluetooth half had a separate,
  now-resolved enumeration issue; see the USB section above.

## USB4 / Thunderbolt

- Two **AMD Strix Halo USB4 host routers** (PCI `c8:00.5`, `c8:00.6`), bound to
  the in-kernel `thunderbolt` driver
- USB-C docks/USB4 peripherals should work with no out-of-tree driver

## USB / misc

- Genesys Logic GL9755 SD card reader (PCI `c2:00.0`, `sdhci-pci`)
- Working devices at capture: 4-port USB 2.0 hub (1-1) with a
  Winchiphead `USB2IIC_CTP_CONTROL` touch/I2C bridge (1-1.1) and a USB
  keyboard (1-1.3); 4-port USB 3.0 hub (2-1)
- ⚠ **Internal Bluetooth USB function intermittently fails enumeration**
  (seen 2026-09-07, twice — see recurrence note below). Port 3-5 of root hub `usb3` (xHCI at PCI
  `c8:00.0`) is the **USB-facing Bluetooth radio of the MT7925 Wi-Fi/BT
  combo card** (`0e8d:0717 “Wireless_Device”, MediaTek Inc.`) — an
  *internal* connection, not an external port. On several boots it presented
  but never answered a descriptor read (`error -110`); the kernel
  power-cycled the port and retried until `unable to enumerate` — a ~60–70 s
  storm that blocked one udev worker (``usb3: Worker … taking a long
  time``) and delayed boot that long, with no `hci0`. The storms happened
  on the boots right after the `mt7xxx-firmware` deployment first took
  effect (the BT radio had been through repeated firmware-failure retries
  before that); after a BIOS session/real power cycle, three consecutive
  boots enumerated cleanly (~1–2 s, `hci0` up) and two deliberate test
  reboots stayed clean. The BIOS power mode was already “performance”
  during the storming boots, so it is not the fix.
- **Recurred on the 2026-09-07 fresh reinstall, with a clean timeline.**
  Both no-firmware install boots (11 `Direct firmware load for mediatek`
  failures each) storm; the storm then persisted across **three
  consecutive warm reboots after `mt7xxx-firmware` was installed** —
  zero firmware failures, yet `usb 3-5` still failed to enumerate every
  boot and no `hci0`. Meanwhile **Wi-Fi (the PCIe half, `c3:00.0`) came
  up normally every time** — only the USB/BT half is latched. Also seen
  during the storm: `xhci_hcd 0000:c8:00.0: Timeout while waiting for
  setup device command`. This is strong support for the latched-state
  theory: a boot before the firmware is present wedges the radio and
  warm reboots do not clear it. A full power-off (powered down, then
  powered back on) cleared it: the next boot enumerated `usb 3-5`
  instantly (~0 s, no retries) with `hci0` up. **Consequence for
  future fresh installs:** after `mt7xxx-firmware` is first layered,
  do a **full shutdown + power-on**, not a reboot — a reboot is not
  enough, and expect no Bluetooth until the power cycle.
- Benign boot noise seen on these installs, not related to the storm:
  `faux_driver regulatory: Direct firmware load for regulatory.db failed`
  (`wpa_supplicant` is not in `ucore-minimal`) and, on early boots,
  `SELinux: Permission firmware_load in class system not defined in
  policy`.
- **Watch the first boot after any full power-off**: `dmesg | grep
  "usb 3-5"`; a repeat after a genuine power cycle is a case for CORSAIR
  support, not OS config

## Hardware needing special drivers (summary)

1. **MediaTek MT7925 Wi-Fi 7/BT** — needs the **`mt7xxx-firmware`** rpm-ostree
   package (Wi-Fi *and* Bluetooth firmware). Until installed, its retry loop
   floods the console at boot. Covered in the install config.
2. **AMD XDNA2 NPU** — works with in-kernel `amdxdna`, nothing to do.

## Suggested stable identifiers for ignition configs

```text
# Boot drive 2 TB
/dev/disk/by-id/nvme-PCIe_SSD_511250820055001423
# Second 2 TB
/dev/disk/by-id/nvme-PCIe_SSD_511250820055001080
# Wired NIC (for network ignition / WoL)
eno1   (or MAC 84:47:09:73:b0:61)
```

## Verifying later

```bash
lsblk -o NAME,MODEL,SERIAL,WWN,TRAN,LOG-SEC,PHY-SEC
ls -l /dev/disk/by-id/
nvme list
sudo dmidecode -s system-product-name        # CORSAIR AI WORKSTATION 300
sudo dmidecode -t memory | grep -E "^\s+(Size|Type|Speed):"
sudo lspci -k | grep -A2 -E "VGA|Ethernet|Network controller|NVMe|USB 4"
```

Re-run these to check whether this document is still current once
`stale_after` passes; drive serials/EUIs are the fields most likely to
change (e.g. after a disk swap — and with two identical drives, swapping one
silently swaps the identifier).
