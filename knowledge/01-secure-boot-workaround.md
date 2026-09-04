---
title: "Boot NixOS through an Ubuntu shim and an enrolled MOK"
summary: "An unmodified Microsoft-signed Ubuntu shim and an owner-enrolled Machine Owner Key booted a signed NixOS installer and installed system while firmware Secure Boot remained enabled."
date: 2026-09-04
last_verified: 2026-09-04
status: draft
authorship: llm-generated
tags: [nixos, secure-boot, uefi, shim, mok, uki]
environment: ["Lenovo ThinkPad P15v Gen 1", "Ubuntu shim 15.8", "NixOS 26.05", "systemd-boot 260.2", "Lanzaboote 1.1.0"]
validation: observed
license: CC0-1.0
---

# Boot NixOS through an Ubuntu shim and an enrolled MOK

## Outcome

An unmodified Microsoft-signed Ubuntu shim can start an owner-signed NixOS
Unified Kernel Image (UKI) when the owner's public certificate is enrolled as a
Machine Owner Key (MOK). This kept firmware Secure Boot enabled and retained
MokManager's physical confirmation step. It did not require the firmware
supervisor password or a change to the firmware key database.

The same trust chain was carried into the installed system. The tested laptop
now boots Microsoft-signed shim, a MOK-signed systemd-boot executable, and a
MOK-signed NixOS generation built by Lanzaboote.

## Problem

I bought a used Lenovo ThinkPad P15v Gen 1 without its firmware supervisor
password. Secure Boot was enabled, and the available firmware controls could
not disable it. A stock NixOS installer was not accepted, but a current Ubuntu
installer booted because its shim was already trusted through the Microsoft
third-party UEFI certificate authority in the firmware.

The goal was to install NixOS without clearing firmware keys, resetting the
supervisor password, or weakening Secure Boot. The working Ubuntu installation
also had to remain intact until a custom NixOS installer had booted
successfully.

## Constraints and assumptions

This procedure was performed by the machine's owner with physical access. It
depends on four conditions:

- The firmware permits booting removable media.
- The firmware trusts the Microsoft certificate that signed the selected
  Ubuntu shim.
- A compatible Ubuntu shim and its matching MokManager are available from
  package-owned files.
- The operator can run `mokutil` from an already trusted Linux installation and
  confirm enrollment physically in MokManager.

The tested stack used Ubuntu shim 15.8, NixOS 26.05, systemd-boot 260.2, and
Lanzaboote 1.1.0. These versions matter. Shim behavior, SBAT revocations,
firmware databases, and NixOS options can change.

The private deployment key was excluded from the installer image and the Nix
store. A known-working Ubuntu installer remained available as the recovery
path.

## Approach

The installer used this trust chain:

```text
UEFI firmware db
  -> Microsoft UEFI certificate authority
  -> unmodified Ubuntu shim
  -> owner-enrolled MOK certificate
  -> owner-signed NixOS installer UKI
  -> NixOS installer
```

We reused the signed shim binary, not Microsoft's certificate or signing
capability. A new self-signed certificate was enrolled in shim's MOK database.
Its private key signed the NixOS EFI payload. MOK enrollment extends what shim
will trust; it does not add the owner's certificate to the firmware `db`.

The build was split in two. Nix built an unsigned installer ISO and UKI from
pinned inputs. A separate script signed and packaged the UKI so the private key
never became a Nix input or entered `/nix/store`.

## Implementation

The complete build-only helper is
[`scripts/01-build-secure-boot-installer.sh`](../scripts/01-build-secure-boot-installer.sh).
It creates and verifies the image but never writes a USB or another block
device. The steps below explain its trust decisions and can be checked
independently.

Run it from the repository root on an Ubuntu builder with Nix installed:

```bash
./scripts/01-build-secure-boot-installer.sh
```

Use `--help` for the Ubuntu package list and optional output, key-directory,
certificate-name, and nixpkgs-revision settings.

### 1. Inspect the working boot path

First confirm Secure Boot state and locate the exact files owned by the Ubuntu
packages:

```bash
mokutil --sb-state
dpkg-query -W shim-signed grub-efi-amd64-signed mokutil sbsigntool
dpkg -L shim-signed | sort
dpkg -L grub-efi-amd64-signed | sort
```

Use `sbverify` on each EFI executable before copying it:

```bash
sbverify --list /path/to/package-owned/shimx64.efi
sbverify --list /path/to/package-owned/mmx64.efi
sbverify --list /path/to/package-owned/grubx64.efi
```

The selected `shimx64.efi` carried Microsoft's signature. MokManager and the
packaged GRUB carried Canonical's signature and matched the same Ubuntu package
set. We also compared the package files with Ubuntu's working EFI System
Partition (ESP) copies and recorded SHA-256 hashes.

Do not assume the name of shim's next executable. The tested Ubuntu shim was
compiled to open `\grubx64.efi`, which we confirmed from the actual binary:

```bash
strings -el /path/to/package-owned/shimx64.efi | grep -F '\grubx64.efi'
```

That filename became part of the boot interface even though our
`grubx64.efi` contained a UKI rather than GRUB.

### 2. Create and enroll a deployment certificate

Generate the key outside the installer source tree with restrictive
permissions:

```bash
umask 077
mkdir -p keys

openssl req \
  -new -x509 -newkey rsa:4096 -sha256 -nodes -days 3650 \
  -subj "/CN=Owner NixOS Secure Boot/" \
  -keyout keys/deployment.key \
  -out keys/deployment.crt

openssl x509 \
  -in keys/deployment.crt \
  -outform DER \
  -out keys/deployment.der

chmod 600 keys/deployment.key
openssl x509 -in keys/deployment.crt -noout -fingerprint -sha256
```

Copy only `deployment.der` to the trusted Ubuntu installation and request
enrollment:

```bash
sudo mokutil --import deployment.der
```

Choose a temporary password, reboot, and use the blue MokManager interface to
select `Enroll MOK`, confirm the certificate, and enter the password. This
physical step is intentional and should not be automated away.

After rebooting Ubuntu, verify the enrolled subject:

```bash
mokutil --list-enrolled | grep -A4 "Owner NixOS Secure Boot"
```

### 3. Build an unsigned NixOS installer UKI

The installer flake pinned its nixpkgs input and imported the NixOS minimal ISO
module. The relevant NixOS settings were:

```nix
{
  boot.uki = {
    name = "nixos-installer";
    version = null;
  };

  networking.networkmanager.enable = true;
  services.openssh.enable = true;

  isoImage.volumeID = "NIXOS_SECURE_2605";
}
```

The stable volume ID is not decorative. The UKI command line and early boot
environment use it to find the live medium and its squashfs Nix store.

The flake exposed the stock ISO and its UKI as an unsigned build output:

```bash
nix build .#unsigned-installer
```

### 4. Sign outside Nix

Sign the UKI only after the Nix build has completed:

```bash
sbsign \
  --key keys/deployment.key \
  --cert keys/deployment.crt \
  --output nixos-installer.signed.efi \
  nixos-installer.unsigned.efi

sbverify \
  --cert keys/deployment.crt \
  nixos-installer.signed.efi
```

The UKI included an `.sbat` section. The systemd stub in this build also
supported the validation protocol used by shim versions before 16, which let
shim start the embedded kernel directly.

### 5. Build the removable-media EFI layout

The finished EFI tree was:

```text
EFI/
  BOOT/
    BOOTX64.EFI          unmodified Microsoft-signed Ubuntu shim
    mmx64.efi            matching Ubuntu MokManager
    grubx64.efi          MOK-signed NixOS installer UKI
  Linux/
    nixos-installer.efi  second copy of the signed UKI
keys/
  deployment.der         public certificate only
README.txt
```

`BOOTX64.EFI` is the standard removable-media fallback path. The UKI was named
`grubx64.efi` only because that is the next-stage filename compiled into this
shim.

The stock NixOS ISO is a hybrid image. Replacing files in its visible ISO tree
is not enough because UEFI boots the embedded El Torito EFI image. We built a
new FAT EFI image, then used `xorriso` to replay the stock boot metadata while
replacing both representations:

```bash
xorriso \
  -indev nixos-installer.unsigned.iso \
  -outdev nixos-secureboot-installer.img \
  -boot_image any replay \
  -update efi.img /boot/efi.img \
  -rm_r /EFI/BOOT -- \
  -map efi-tree/EFI/BOOT /EFI/BOOT \
  -mkdir /EFI/Linux -- \
  -map efi-tree/EFI/Linux/nixos-installer.efi \
    /EFI/Linux/nixos-installer.efi \
  -mkdir /keys -- \
  -map keys/deployment.der /keys/deployment.der \
  -map efi-tree/README.txt /README.txt \
  -commit
```

The packaging script extracted shim and the UKI back out of the completed image
and compared them byte for byte with their inputs. It also generated a
`SHA256SUMS` manifest and rejected an image containing the private key.

### 6. Carry the chain into the installed system

The installer created an encrypted NixOS root and installed Lanzaboote.
Lanzaboote signed systemd-boot and each NixOS generation UKI with the enrolled
deployment key. A small external bootloader install hook then restored this
layout after every rebuild:

```text
EFI/BOOT/BOOTX64.EFI   unmodified Ubuntu shim
EFI/BOOT/mmx64.efi     matching MokManager
EFI/BOOT/grubx64.efi   MOK-signed systemd-boot
EFI/Linux/*.efi        MOK-signed Lanzaboote generation UKIs
```

The installed trust chain is therefore:

```text
UEFI firmware db
  -> Microsoft-signed Ubuntu shim
  -> MOK-signed systemd-boot
  -> MOK-signed Lanzaboote generation UKI
  -> NixOS
```

The installation automation checked the target disk's model and serial before
offering one default-deny `[y/N]` erase prompt. Passphrase entry used
`/dev/tty`; the script itself was uploaded before execution so an SSH heredoc
and `cryptsetup` did not compete for the same standard input.

## Validation

The signed installer booted from USB with firmware Secure Boot still enabled.
The installed NixOS system subsequently reported this state:

```text
SecureBoot enabled
Firmware: UEFI
Current Boot Loader: systemd-boot 260.2
Loader: /EFI/BOOT/grubx64.efi
Measured UKI: yes
```

The following trust boundaries were checked:

| Boundary | Check | Result |
| --- | --- | --- |
| Firmware to shim | `sbverify --list BOOTX64.EFI` and comparison with the package file | Microsoft-signed shim remained unmodified |
| Shim to installer UKI | `sbverify --cert deployment.crt grubx64.efi` and physical USB boot | Deployment signature verified; installer booted |
| MOK enrollment | `mokutil --list-enrolled` | Deployment certificate subject was present |
| Shim to installed loader | `sbverify --list /boot/EFI/BOOT/grubx64.efi` | systemd-boot carried the deployment signature |
| Loader to NixOS generation | `sbverify --list /boot/EFI/Linux/<generation>.efi` | Current UKI carried the deployment signature |
| Runtime state | `mokutil --sb-state` and `bootctl status` | Secure Boot enabled; signed chain active |
| Image contents | extract, `cmp`, `sha256sum`, and private-key scans | Packaged files matched; private key was absent |

An unsigned copy of the installer UKI was retained for a negative test. That
test has not been observed yet, so this entry does not claim that shim's
rejection path was verified independently.

## Failure modes and recovery

- Re-signing shim removes the value of the Microsoft signature. Preserve the
  package binary byte for byte.
- A mismatched shim and MokManager can fail before enrollment is possible. Use
  files from the same package set.
- Shim's expected next-stage filename is build-specific. Inspect the binary
  rather than assuming `grubx64.efi` or another name.
- A valid signed UKI in the visible ISO tree still will not boot if the
  embedded El Torito EFI image contains the old files.
- MOK enrollment is incomplete until MokManager confirms it during reboot.
  `mokutil --import` only stages the request.
- An SSH-fed script can hang at a passphrase prompt when its script body and
  interactive input share standard input. Upload it first, then execute it in
  a separate terminal-backed session.
- Firmware `dbx` or SBAT updates can revoke an older shim. Recheck signatures
  and current revocation status when rebuilding the image.

Keep a known-working vendor-signed installer until the custom installer and
the installed NixOS chain have both booted. A non-destructive repair path can
boot the custom USB, unlock the existing encrypted root, install a corrected
generation, verify its signatures, and unmount without repartitioning.

## Security and privacy

This approach preserves Secure Boot's authentication boundary. It adds one
owner-controlled certificate through the physical MOK enrollment workflow; it
does not recover, bypass, or replace the firmware supervisor password.

The public certificate is safe to place on the installer. The private key is
not. The tested installation retained the private key on its encrypted root so
normal NixOS rebuilds could sign new generations. Encryption protects that key
while the machine is off, but root compromise while it is running exposes the
key. A shared fleet key would make that compromise affect every machine that
trusts it. Per-host MOK keys or an offline signing service are better choices
for a larger deployment.

Secure Boot verifies boot artifacts; it does not encrypt the disk or protect a
running system from an administrator. Disk encryption, update policy, and
runtime hardening remain separate controls.

Machine serials, network addresses, credentials, internal hostnames, and
unrelated infrastructure details were deliberately omitted from this public
entry.

## Generalizable lessons

- Start from a boot path the firmware already trusts, then extend trust through
  a supported owner-enrollment mechanism.
- Inspect the exact shim binary. Package version, signer, next-stage filename,
  and SBAT compatibility are inputs, not assumptions.
- Keep signing outside a pure Nix build when the key must stay out of the Nix
  store.
- Verify the final image after packaging. Checking intermediate files does not
  prove the bytes on the USB are the same.
- Treat key storage and rotation as part of the design. A successful boot does
  not make a fleet-wide private key safe.
- Preserve one known-good recovery medium until both the installer and the
  installed operating system have booted under Secure Boot.

## References

- [Ubuntu Secure Boot](https://wiki.ubuntu.com/UEFI/SecureBoot)
- [shim source and documentation](https://github.com/rhboot/shim)
- [Unified Kernel Image specification](https://uapi-group.org/specifications/specs/unified_kernel_image/)
- [`systemd-stub`](https://www.freedesktop.org/software/systemd/man/latest/systemd-stub.html)
- [Lanzaboote](https://github.com/nix-community/lanzaboote)
