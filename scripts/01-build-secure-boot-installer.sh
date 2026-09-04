#!/usr/bin/env bash
set -Eeuo pipefail

# Build a NixOS 26.05 installer that boots through Ubuntu shim 15.8 and an
# owner-enrolled MOK. This script builds an image. It never writes a block
# device and never enrolls a key.

umask 077

nixpkgs_revision=${NIXPKGS_REVISION:-5dfba6236110080a54247d6460bc2ff5dda939cc}
certificate_name=${CERTIFICATE_NAME:-Owner NixOS Secure Boot}
key_dir=${KEY_DIR:-"$PWD/secureboot-keys"}
output_dir=${OUTPUT_DIR:-"$PWD/secureboot-output"}
force=${FORCE:-0}

usage() {
  cat <<'EOF'
Usage: 01-build-secure-boot-installer.sh

Build and verify a Secure Boot NixOS installer image. The script does not
write a USB, modify a block device, or enroll a MOK.

Ubuntu build dependencies:
  shim-signed sbsigntool openssl dosfstools mtools xorriso binutils

Nix with flakes must also be installed. Optional environment variables:
  NIXPKGS_REVISION  Pinned nixpkgs revision
  CERTIFICATE_NAME  Subject CN for a newly generated certificate
  KEY_DIR           Key directory (default: ./secureboot-keys)
  OUTPUT_DIR        Artifact directory (default: ./secureboot-output)
  FORCE=1           Replace only the script's known generated output files
EOF
}

case ${1:-} in
  -h | --help)
    usage
    exit 0
    ;;
  "") ;;
  *)
    usage >&2
    exit 2
    ;;
esac

fail() {
  printf 'secure-boot-installer: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

find_package_file() {
  local package=$1
  local pattern=$2
  local path

  while IFS= read -r path; do
    if [[ -f $path ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done < <(dpkg -L "$package" | grep -E "$pattern" || true)

  return 1
}

for command_name in \
  cmp \
  dpkg \
  dpkg-query \
  grep \
  mcopy \
  mkfs.vfat \
  nix \
  nix-store \
  objdump \
  openssl \
  sbsign \
  sbverify \
  sha256sum \
  strings \
  xorriso; do
  require_command "$command_name"
done

[[ $(uname -m) == x86_64 ]] || fail "this build targets x86_64 UEFI systems"

dpkg-query -W shim-signed >/dev/null 2>&1 || {
  fail "Ubuntu package shim-signed is not installed"
}

shim=$(
  find_package_file \
    shim-signed \
    '/shimx64\.efi\.signed\.latest$'
) || shim=$(
  find_package_file \
    shim-signed \
    '/shimx64\.efi\.signed[^/]*$'
) || fail "could not locate a package-owned x86-64 shim"

mok_manager=$(
  find_package_file shim-signed '/mmx64\.efi$'
) || fail "could not locate the matching package-owned MokManager"

shim_version=$(dpkg-query -W -f='${Version}' shim-signed)
printf 'Using shim-signed %s\n' "$shim_version"
printf '  shim:       %s\n' "$shim"
printf '  MokManager: %s\n' "$mok_manager"

shim_signatures=$(sbverify --list "$shim" 2>&1) || {
  printf '%s\n' "$shim_signatures" >&2
  fail "shim signature inspection failed"
}
printf '%s\n' "$shim_signatures"
grep -qi 'Microsoft' <<<"$shim_signatures" || {
  fail "shim does not report a Microsoft signature; inspect it manually"
}

sbverify --list "$mok_manager"

# This validated recipe relies on the next-stage path in Ubuntu shim 15.8.
# Refuse a different shim convention rather than silently creating an image
# that firmware accepts but shim cannot continue booting.
strings -el "$shim" | grep -Fq '\grubx64.efi' || {
  fail "shim does not advertise \\grubx64.efi as its next stage"
}

mkdir -p "$key_dir"
private_key="$key_dir/deployment.key"
certificate="$key_dir/deployment.crt"
public_der="$key_dir/deployment.der"

if [[ -e $private_key || -e $certificate ]]; then
  [[ -f $private_key && -f $certificate ]] || {
    fail "key and certificate must either both exist or both be absent"
  }
  [[ $(stat -c '%a' "$private_key") == 600 ]] || {
    fail "$private_key must have mode 600"
  }
else
  printf 'Generating a new deployment key in %s\n' "$key_dir"
  openssl req \
    -new \
    -x509 \
    -newkey rsa:4096 \
    -sha256 \
    -nodes \
    -days 3650 \
    -subj "/CN=$certificate_name/" \
    -keyout "$private_key" \
    -out "$certificate"
  chmod 600 "$private_key"
  chmod 644 "$certificate"
fi

key_modulus=$(
  openssl rsa -in "$private_key" -noout -modulus 2>/dev/null |
    sha256sum | cut -d' ' -f1
)
certificate_modulus=$(
  openssl x509 -in "$certificate" -noout -modulus |
    sha256sum | cut -d' ' -f1
)
[[ $key_modulus == "$certificate_modulus" ]] || {
  fail "the deployment key and certificate do not match"
}

openssl x509 -in "$certificate" -outform DER -out "$public_der"
chmod 644 "$certificate" "$public_der"
openssl x509 \
  -in "$certificate" \
  -noout \
  -subject \
  -fingerprint \
  -sha256

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/nixos-secureboot.XXXXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
build_dir="$work_dir/build"
mkdir -p "$build_dir"

cat >"$build_dir/flake.nix" <<EOF
{
  description = "Unsigned NixOS Secure Boot installer payload";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/$nixpkgs_revision";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      installer = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          "\${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          ./installer.nix
        ];
      };
    in
    {
      packages.\${system}.unsigned-installer = pkgs.runCommand
        "nixos-secureboot-unsigned-installer"
        { }
        ''
          mkdir -p "\$out"
          cp \${installer.config.system.build.isoImage}/iso/*.iso \\
            "\$out/nixos-installer.unsigned.iso"
          cp \\
            \${installer.config.system.build.uki}/\${installer.config.system.boot.loader.ukiFile} \\
            "\$out/nixos-installer.unsigned.efi"
        '';
    };
}
EOF

cat >"$build_dir/installer.nix" <<'EOF'
{ pkgs, ... }:

{
  boot.uki = {
    name = "nixos-installer";
    version = null;
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelParams = [
    "console=tty0"
    "systemd.setenv=SYSTEMD_SULOGIN_FORCE=1"
  ];

  networking.hostName = "nixos-installer";
  networking.networkmanager.enable = true;

  services.openssh.enable = true;

  environment.systemPackages = with pkgs; [
    cryptsetup
    efibootmgr
    git
    gptfdisk
    mokutil
    openssl
    parted
    pciutils
    rsync
    sbctl
    sbsigntool
  ];

  isoImage.volumeID = "NIXOS_SECURE_2605";
  image.fileName = "nixos-secureboot-installer-26.05-x86_64-linux.iso";
  boot.zfs.forceImportRoot = false;
}
EOF

printf 'Building the unsigned ISO and UKI...\n'
nix build \
  "path:$build_dir#unsigned-installer" \
  --out-link "$work_dir/unsigned-result"

unsigned_iso="$work_dir/unsigned-result/nixos-installer.unsigned.iso"
unsigned_uki="$work_dir/unsigned-result/nixos-installer.unsigned.efi"
[[ -f $unsigned_iso && -f $unsigned_uki ]] || {
  fail "Nix build did not produce the expected ISO and UKI"
}

objdump -h "$unsigned_uki" | grep -q '[.]sbat' || {
  fail "the installer UKI has no .sbat section"
}

signed_uki="$work_dir/nixos-installer.signed.efi"
sbsign \
  --key "$private_key" \
  --cert "$certificate" \
  --output "$signed_uki" \
  "$unsigned_uki"
sbverify --cert "$certificate" "$signed_uki"

efi_tree="$work_dir/efi-tree"
mkdir -p "$efi_tree/EFI/BOOT" "$efi_tree/EFI/Linux" "$efi_tree/keys"
install -m 0644 "$shim" "$efi_tree/EFI/BOOT/BOOTX64.EFI"
install -m 0644 "$mok_manager" "$efi_tree/EFI/BOOT/mmx64.efi"
install -m 0644 "$signed_uki" "$efi_tree/EFI/BOOT/grubx64.efi"
install -m 0644 "$signed_uki" "$efi_tree/EFI/Linux/nixos-installer.efi"
install -m 0644 "$public_der" "$efi_tree/keys/deployment.der"

build_date=$(date --utc +%Y-%m-%dT%H:%M:%SZ)
certificate_fingerprint=$(
  openssl x509 -in "$certificate" -noout -fingerprint -sha256 |
    cut -d= -f2
)
shim_hash=$(sha256sum "$shim" | cut -d' ' -f1)
uki_hash=$(sha256sum "$signed_uki" | cut -d' ' -f1)

cat >"$efi_tree/README.txt" <<EOF
NixOS 26.05 Secure Boot installer
Build date (UTC): $build_date
Ubuntu shim package: $shim_version
Nixpkgs revision: $nixpkgs_revision
Deployment certificate SHA-256 fingerprint: $certificate_fingerprint
Ubuntu shim SHA-256: $shim_hash
Signed installer UKI SHA-256: $uki_hash

Trust chain:
  UEFI Microsoft third-party CA -> unmodified Ubuntu shim
  Ubuntu shim MOK database -> owner deployment certificate
  owner deployment certificate -> signed NixOS installer UKI

Enroll keys/deployment.der with mokutil from an already trusted Linux system,
then confirm the enrollment physically through MokManager during reboot.

The private deployment key is deliberately absent from this image.
EOF

efi_bytes=$(du -sb "$efi_tree" | cut -f1)
efi_mib=$(((efi_bytes + 1048575) / 1048576 + 16))
if ((efi_mib < 64)); then
  efi_mib=64
fi

efi_image="$work_dir/efi.img"
truncate -s "${efi_mib}M" "$efi_image"
mkfs.vfat -F 32 -n NIXOS_EFI "$efi_image"
mcopy -s -i "$efi_image" "$efi_tree/EFI" ::/
mcopy -s -i "$efi_image" "$efi_tree/keys" ::/
mcopy -i "$efi_image" "$efi_tree/README.txt" ::/README.txt

if [[ -e $output_dir && ! -d $output_dir ]]; then
  fail "$output_dir exists and is not a directory"
fi
mkdir -p "$output_dir"

final_image="$output_dir/nixos-secureboot-installer.img"
for output_file in \
  "$final_image" \
  "$output_dir/nixos-installer.signed.efi" \
  "$output_dir/nixos-installer.unsigned.efi" \
  "$output_dir/SHA256SUMS"; do
  if [[ -e $output_file && $force != 1 ]]; then
    fail "$output_file already exists; set FORCE=1 to replace generated outputs"
  fi
done

if [[ $force == 1 ]]; then
  rm -f -- \
    "$final_image" \
    "$output_dir/nixos-installer.signed.efi" \
    "$output_dir/nixos-installer.unsigned.efi" \
    "$output_dir/SHA256SUMS"
fi

xorriso \
  -indev "$unsigned_iso" \
  -outdev "$final_image" \
  -boot_image any replay \
  -update "$efi_image" /boot/efi.img \
  -rm_r /EFI/BOOT -- \
  -map "$efi_tree/EFI/BOOT" /EFI/BOOT \
  -mkdir /EFI/Linux -- \
  -map \
  "$efi_tree/EFI/Linux/nixos-installer.efi" \
  /EFI/Linux/nixos-installer.efi \
  -mkdir /keys -- \
  -map "$public_der" /keys/deployment.der \
  -map "$efi_tree/README.txt" /README.txt \
  -commit

extracted_shim="$work_dir/extracted-shim.efi"
extracted_uki="$work_dir/extracted-uki.efi"
xorriso \
  -osirrox on \
  -indev "$final_image" \
  -extract /EFI/BOOT/BOOTX64.EFI "$extracted_shim" \
  >/dev/null 2>&1
xorriso \
  -osirrox on \
  -indev "$final_image" \
  -extract /EFI/BOOT/grubx64.efi "$extracted_uki" \
  >/dev/null 2>&1

cmp "$shim" "$extracted_shim"
cmp "$signed_uki" "$extracted_uki"
sbverify --cert "$certificate" "$extracted_uki"

if xorriso -indev "$final_image" -find / -name deployment.key -print \
  2>/dev/null | grep -q deployment.key; then
  fail "private key filename found in the final image"
fi

if grep -aFq -- "$(head -c 64 "$private_key")" "$final_image"; then
  fail "private key material found in the final image"
fi

if nix-store --query --requisites "$work_dir/unsigned-result" |
  grep -Eq 'deployment[.]key|secureboot-keys'; then
  fail "the unsigned Nix closure references private signing material"
fi

install -m 0644 "$signed_uki" "$output_dir/nixos-installer.signed.efi"
install -m 0644 "$unsigned_uki" "$output_dir/nixos-installer.unsigned.efi"
install -m 0644 "$public_der" "$output_dir/deployment.der"

(
  cd "$output_dir"
  sha256sum \
    nixos-secureboot-installer.img \
    nixos-installer.signed.efi \
    nixos-installer.unsigned.efi \
    deployment.der \
    >SHA256SUMS
)

printf '\nCreated and verified:\n  %s\n' "$final_image"
printf 'Public enrollment certificate:\n  %s\n' \
  "$output_dir/deployment.der"
printf '\nThe private key remains in:\n  %s\n' "$private_key"
printf '%s\n' \
  'Back it up securely. Enroll only the public DER file before booting the image.' \
  'This script did not write a USB or modify a block device.'
