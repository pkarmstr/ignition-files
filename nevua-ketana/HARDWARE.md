---
type: Hardware Reference
title: "nevua-ketana hardware reference"
description: Physical hardware inventory and stable drive/device identifiers for the nevua-ketana workstation (MSI PRO X870E-P WIFI, Ryzen 9 9900X, 3× drives), for reproducible Ignition builds.
resource: ssh://keelan@192.168.0.45/
tags: [hardware, hardware-reference, ignition, fedora-coreos, storage, drives, nvidia, workstation]
status: stable
stale_after: 2027-08-27T00:00:00Z
generated: { by: pi-coding-agent/qwen3.8-27b, at: 2026-08-27T01:15:52Z }
sources:
  - id: live-system-scan
    resource: "hardware introspection commands (lsblk, /dev/disk/by-id, nvme list/id-ctrl, lspci -k/-vvv, dmidecode, dmesg, hdparm, /proc/cmdline) run against keelan@192.168.0.45 on 2026-08-27"
    title: Live system introspection of nevua-ketana
    author: pi-coding-agent/qwen3.8-27b
---

# Hardware Reference — nevua-ketana

Purpose: hardware reference for building reproducible Ignition configs for this
machine. Only physical hardware and stable device identifiers are documented
here — **not** the current partition layout, filesystems, or software config.

Captured: 2026-08-27, while running Fedora CoreOS (kernel 7.1.6-201.fc44,
ignition platform = metal).[^live-system-scan]

[^live-system-scan]: Live system introspection of nevua-ketana

## System

| Component | Detail |
|---|---|
| Board | MSI PRO X870E-P WIFI (MS-7E70, v2.0), AMD X870 chipset, AM5 |
| BIOS | American Megatrends 2.A30 (2025-08-14) |
| CPU | AMD Ryzen 9 9900X — 12 cores / 24 threads, Zen 5 (Granite Ridge), up to 5.66 GHz |
| RAM | 32 GiB total: 2 × 16 GiB DDR5-4800 (part `CMH32GX5M2M6000Z36`, SPD manufacturer reads "Unknown") in DIMMA1 + DIMMB1. DIMMA2 + DIMMB2 **empty**. Running at 4800 MT/s, 1.1 V |
| iGPU | AMD Granite Ridge Radeon (PCI 7a:00.0, 1002:13c0), amdgpu |

## Drives (stable identifiers)

### 1. Toshiba (HGST) 20 TB enterprise HDD — SATA

HDDs get a `/dev/sdX` name that can change between boots/installs; always use
one of the by-id paths below in ignition `storage.disks.device`.

- **Model:** TOSHIBA HDWR62AUZSVA (Ultrastar DC HC550, 20 TB, 7200 RPM, CMR)
- **Serial:** `X5E2A00MFWXJ`
- **ATA firmware:** 0103
- **WWN:** `0x5000039e58d0650e` (SCSI ID `35000039e58d0650e`)
- **Interface:** SATA, on X870 chipset controller at PCI `15:00.0` (ata7/host6)
- **Sectors:** 512-byte logical / 4096-byte physical (**512e**, not 4Kn — confirmed
  2026-08-29 by `vgcreate`, which reported physical 4096 (HDD) vs 512 (NVMe)
  while accepting both *logical* sizes; LVM makes a logical mismatch a hard
  error, so both logical sizes must be 512). This is why `pvcreate`/`vgcreate`
  on this disk pair print
  `WARNING: Devices have inconsistent physical block sizes (4096 and 512)` —
  harmless, and documented in `setup-storage.sh`.
- by-id paths (all equivalent, pick one and be consistent):
  - `/dev/disk/by-id/ata-TOSHIBA_HDWR62AUZSVA_X5E2A00MFWXJ`
  - `/dev/disk/by-id/scsi-35000039e58d0650e`
  - `/dev/disk/by-id/wwn-0x5000039e58d0650e`

### 2. Crucial P5 Plus 1 TB NVMe

- **Model:** CT1000P510SSD8 (Micron/Crucial P5 Plus, DRAM-less)
- **Serial:** `2537E9CABC5C`
- **EUI-64:** `00a07501e9cabc5c`
- **NVMe firmware:** K1CR5102
- **PCI:** `02:00.0`, vendor/device `c0a9:560a` (Micron P510), linked at **Gen5 x4** (32GT/s)
- **Slot:** M.2 wired to the **CPU** (behind CPU GPP bridge 00:02.1)
- by-id paths:
  - `/dev/disk/by-id/nvme-CT1000P510SSD8_2537E9CABC5C`
  - `/dev/disk/by-id/nvme-eui.00a07501e9cabc5c`

### 3. 512 GB white-label NVMe (Phison E12)

Generic/white-label drive — no vendor identity in NVMe metadata; the model
string is literally `PCIe SSD`.

- **Model string:** `PCIe SSD` (vendor: none)
- **Serial:** `20090851200275`
- **NVMe firmware:** ECFM22.6
- **PCI:** `05:00.0`, vendor/device `1987:5012` (Phison E12 controller), linked at **Gen3 x4** (8GT/s) — the drive itself is Gen3
- **Slot:** M.2 wired to the **chipset** (behind X870 PCIe switch 03:00.0)
- by-id path:
  - `/dev/disk/by-id/nvme-PCIe_SSD_20090851200275`
- **Quirks** (seen in dmesg, informational): reports `missing or invalid SUBNQN
  field` and `bogus Namespace Identifiers` (incomplete NVMe metadata). Because
  the model name is the generic "PCIe SSD", the by-id name is only unique via
  the serial suffix — if a second identical white-label drive is ever added,
  disambiguate by serial or by PCI slot (`/sys/devices/pci.../0000:05:00.0/`).

### Slot topology summary (for future disk-layout planning)

| Location | PCI addr | Link | Drive |
|---|---|---|---|
| CPU M.2 slot | 02:00.0 | Gen5 x4 | Crucial P5 Plus 1 TB |
| Chipset M.2 slot | 05:00.0 | Gen4 x4 (drive at Gen3) | white-label 512 GB (Phison E12) |
| Chipset SATA (15:00.0, ata7) | 15:00.0 | SATA | Toshiba 20 TB |
| Chipset SATA (13:00.0) | 13:00.0 | SATA | (unused at capture) |

## GPUs

| # | PCI addr | Model | Link | GPU UUID |
|---|---|---|---|---|
| 0 | 01:00.0 | NVIDIA RTX PRO 4000 Blackwell (GB203GL, 10de:2c34) | Gen5 x16 | `GPU-e5a76ff5-8a2c-e47c-91be-93c7dcba7166` |
| 1 | 11:00.0 | NVIDIA RTX PRO 4000 Blackwell (GB203GL, 10de:2c34) | **Gen4 x4 (downgraded)** | `GPU-7df7fc16-6155-2d04-af5b-e0e2a162c6f8` |

Note: the second GPU slot only provides a Gen4 x4 electrical path (the card is
Gen5 x16 capable) — expected limitation of the board/riser, not a defect.

## Network

### Wired — RTL8126 5GbE (the ignition NIC)

- **PCI:** `0e:00.0`, vendor/device `10ec:8126` (Realtek RTL8126A), subsystem MSI 7e70
- **MAC:** `fc:9d:05:06:77:a0`
- **netdev:** `enp14s0` (predictable name from PCI path 0e:00.0)
- **Driver:** `r8169` (in-kernel, nothing special needed)

### Wi-Fi 7 — Qualcomm WCN785x (FastConnect 7800) — ⚠ special driver + firmware

- **PCI:** `0f:00.0`, vendor/device `17cb:1107`, Foxconn module
- Driver identifies hardware as **WCN7850 hw2.0**
- **Driver:** `ath12k_wifi7` module (special backported package layered on
  `ath12k` — not the plain mainline `ath12k` name)
- **Firmware required:** `ath12k/WCN7850/hw2.0/amss.bin` (from the
  `linux-firmware` package)
- **Status at capture: NOT WORKING.** Module loads but probe fails with
  "Direct firmware load for ath12k/WCN7850/hw2.0/amss.bin failed with error
  -2" (firmware file not present on the system), so no `wlan*` interface
  exists. To enable Wi-Fi: install the WCN7850 linux-firmware files and the
  `ath12k_wifi7` module package.

## USB4 / Thunderbolt

- **ASMedia ASM4242** USB4/Thunderbolt-3 host router, PCI `79:00.0`
  (1b21:2425) + companion xHCI `78:00.0` (1b21:2426)
- Bound to the in-kernel `thunderbolt` driver (supports this AMD-platform
  USB4/TB3 router; no out-of-tree driver needed)
- No TB/USB4 peripherals attached at capture.

## USB / misc

- No external USB devices attached at capture.
- Board USB: AMD X870 chipset USB3.x XHCI (12:00.0, 14:00.0) + CPU Raphael USB
  controllers (7a:00.3–7b:00.0).

## Hardware needing special drivers (summary)

1. **NVIDIA RTX PRO 4000 Blackwell (×2)** — requires the proprietary `nvidia`
   driver; Blackwell (GB203) is not supported by nouveau and needs a recent
   driver (R575+ open kernel-module series). System was running
   `nvidia` 610.57.04. On Fedora CoreOS the nvidia driver is not in the
   default image (kernel module extension / custom image required).
2. **Qualcomm WCN785x Wi-Fi 7** — needs the special `ath12k_wifi7` module
   package **and** the `WCN7850/hw2.0` linux-firmware; currently broken due to
   missing firmware (see Network above).
3. **ASM4242 USB4/TB3 router** — works with in-kernel `thunderbolt`, but keep
   it in mind when trimming kernel modules from a custom CoreOS image.
4. **White-label Phison E12 NVMe** — no special driver (standard `nvme`), but
   its broken SUBNQN/namespace metadata means the serial is the only reliable
   identifier.

## Suggested stable identifiers for ignition configs

```text
# HDD 20 TB
/dev/disk/by-id/wwn-0x5000039e58d0650e
# Crucial 1 TB (Gen5, CPU slot)
/dev/disk/by-id/nvme-CT1000P510SSD8_2537E9CABC5C
# White-label 512 GB (Gen3, chipset slot)
/dev/disk/by-id/nvme-PCIe_SSD_20090851200275
# Wired NIC (for network ignition)
enp14s0   (or MAC fc:9d:05:06:77:a0)
```

## Verifying later

```bash
lsblk -o NAME,MODEL,SERIAL,WWN,TRAN,LOG-SEC,PHY-SEC
ls -l /dev/disk/by-id/
nvme list
sudo dmidecode -s baseboard-product-name   # PRO X870E-P WIFI (MS-7E70)
sudo dmidecode -t memory | grep -E "^\s+(Locator|Size):"
sudo lspci -k | grep -A2 -E "VGA|Ethernet|Network|NVMe|USB 4"
```

Re-run these to check whether this document is still current once
`stale_after` passes; drive serials/WWNs are the fields most likely to
change (e.g. after a disk swap).
