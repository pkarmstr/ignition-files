---
type: Hardware Reference
title: "hava-amina hardware reference"
description: Physical hardware inventory and stable drive/device identifiers for the hava-amina AMD system, for reproducible Ignition builds.
tags: [hardware, hardware-reference, ignition, fedora-coreos, storage, drives, amd]
status: draft
---

# Hardware Reference — hava-amina

Purpose: hardware reference for building reproducible Ignition configs for this
machine. Only physical hardware and stable device identifiers are documented
here — **not** the current partition layout, filesystems, or software config.

Captured: — (machine not yet provisioned; fill in from a live session via
`ssh keelan@<IP>` right after the install finishes).

## System

| Component | Detail |
|---|---|
| Board | |
| BIOS | |
| CPU | |
| RAM | |

## Drives (stable identifiers)

For each drive: model, serial, firmware, PCI addr/link, and the
`/dev/disk/by-id/...` paths. HDDs get a `/dev/sdX` name that can change
between boots/installs; always use a by-id path in ignition
`storage.disks.device`.

- Boot drive:
  - by-id:

## GPUs

AMD system, no NVIDIA. (List any dGPU; the iGPU works with open-source
amdgpu on the plain `ucore-minimal:stable` tag.)

| # | PCI addr | Model | Link |
|---|---|---|---|

## Network

### Wired — (the ignition NIC)

- **PCI:**
- **MAC:**
- **netdev:**
- **Driver:**

## Hardware needing special drivers (summary)

(none expected — AMD, plain stable tag)

## Suggested stable identifiers for ignition configs

```text
# (fill in by-id paths once captured)
```

## Verifying later

```bash
lsblk -o NAME,MODEL,SERIAL,WWN,TRAN,LOG-SEC,PHY-SEC
ls -l /dev/disk/by-id/
nvme list
sudo dmidecode -s baseboard-product-name
sudo dmidecode -t memory | grep -E "^\s+(Locator|Size):"
sudo lspci -k | grep -A2 -E "VGA|Ethernet|Network|NVMe|USB 4"
```
