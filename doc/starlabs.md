# Star Labs boards

This layer supports full in-flash Heads on 14 of the 17 physical Star Labs
coreboot release configurations current in release 26.07. `starlabs_qemu` is
the software gate. LabTop KBL, Lite GLK, and Lite GLKR are explicitly
unsupported because their fixed 8 MiB flash layouts cannot contain the full
Heads payload. The exact StarBook MTL result awaits physical observation;
local Lite ADL is the next first-boot target for unproven firmware.

## Pinned sources

- Heads base: `548526df0f5fa9616d882ff2932ced08b88d04aa`
- Reproducible container: `tlaurion/heads-dev-env@sha256:96f8f91c6464305c4a990d59f9ef93910c16c7fd0501a46b43b34a4600a368de`
- SBOM Go toolchain: `go1.26.0.linux-amd64.tar.gz`, SHA-256
  `aac1b08a0fb0c4e0a7c1555beb7b59180b05dfc5a3d62e40e9de90cd42f88235`
- Star Labs coreboot: `https://github.com/StarLabsLtd/coreboot.git` at
  `3531cde8002a9afff8ad4c272b2c4ea015f45012` (`release_26.07_1`)
- Star Labs coreboot blobs submodule:
  `https://github.com/starlabsltd/blobs.git` at
  `d1acde12d431cf2c38670a7bcbf82afd89d87166`

Intel descriptors, ME images, FSP, EC images, VBTs, and logos are consumed
from the pinned Star Labs coreboot tree and its maintained submodules. They
are not copied into Heads.

The current Cezanne release also needs Star Labs AMD data that is not present
at the maintained repository's current commit. Mount that maintained working
tree read-only; `config/starlabs-amd-binaries.sha256` verifies every consumed
file before coreboot configure and build. The container destination is fixed
to `build/x86/amd_binaries` because that is the exact tree consumed by the
Cezanne coreboot configuration. The verified manifest digest is a normal
coreboot configure/build prerequisite, so a changed manifest invalidates cached
Cezanne artifacts; changed bytes under an unchanged manifest fail verification:

```sh
export AMD_BINARIES=/absolute/path/to/amd_binaries
export GO_TOOLCHAIN=/absolute/path/to/go1.26.0
export HEADS_DOCKER_READONLY_MOUNTS="$GO_TOOLCHAIN=/opt/go1.26.0;$AMD_BINARIES=$(pwd)/build/x86/amd_binaries"
HEADS_DISABLE_USB=1 ./docker_repro.sh env \
  PATH=/opt/go1.26.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  make BOARD=starlabs_starbook_cezanne
```

Publishing those bytes at an immutable Star Labs revision remains necessary
before Cezanne targets can be built by public CI without an external input.
The Cezanne coreboot configurations also select `CONFIG_USE_AMD_BLOBS`, so
coreboot initializes its pinned `3rdparty/amd_blobs` gitlink on a clean build.
Their fTPM configuration reserves `PSP_NVRAM(PRESERVE)` at `0xd0000`, size
`0x20000`; the generated PSP L2 directory must contain type `0x04` with that
same address and size.

## Building

Use the pinned container for every target:

```sh
HEADS_DISABLE_USB=1 ./docker_repro.sh make BOARD=starlabs_qemu

export GO_TOOLCHAIN=/absolute/path/to/go1.26.0
export HEADS_DOCKER_READONLY_MOUNTS="$GO_TOOLCHAIN=/opt/go1.26.0"
HEADS_DISABLE_USB=1 ./docker_repro.sh env \
  PATH=/opt/go1.26.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  make BOARD=starlabs_starbook_mtl
```

`starlabs_qemu` omits the firmware SBOM and does not need Go. Physical targets
generate the SBOM and therefore consume the pinned, read-only Go toolchain.

The supported Cezanne targets include `boards/starlabs/compact.config`. That
profile keeps the graphical UI, GPG verification, TPM2 tools, USB storage,
flash tools, CBMEM tools, and kexec. It omits encrypted-storage and LVM tools,
HOTP/TOTP enrollment, QR generation, mobile tethering, extra
filesystem-maintenance tools, and loadable keymaps. The full profile remains
mandatory for the StarBook MTL proof board. Do not use further profile
reduction to try to support the three excluded 8 MiB targets.

Run the QEMU gate with a TPM2 software device using the normal Heads QEMU
workflow:

```sh
HEADS_DISABLE_USB=1 ./docker_repro.sh make BOARD=starlabs_qemu run
```

## Flash preservation

Physical board configurations expose only this internal flash operation:

```text
flashprog --progress --programmer internal --fmap -i COREBOOT
```

It excludes descriptor, ME/PSP, EC, MRC cache, SMMSTORE, console, and FMAP.
The three unsupported analysis targets intentionally expose no flash command.
Every physical coreboot configuration selects the UEFI-variable option
backend, so the per-unit serial number continues to come from the preserved
`SMMSTORE` region. The compiled serial is only a board-family fallback for an
uninitialized store.

Before a first boot on a designated test box:

1. Reserve the exact unit, verify its identity/release state, and capture the
   read-only firmware, power, BootOrder, TPM/PCR, and device baseline.
2. Audit the live image and Heads ROM with `bin/starlabs-fmap-audit.sh`,
   including the correct `--expected-size` and Intel `--ifd-platform`.
3. Use `bin/starlabs-merge-coreboot.sh` to copy only Heads `COREBOOT` into the
   fresh live image when both images have an identical identity and FMAP.
4. Require the merge tool to prove every byte outside `COREBOOT` is identical,
   then package a signed update whose RMAP selects only `COREBOOT`.
5. Install through the normal signed update path. An external programmer,
   duplicate full-chip read, or exercised restore is not a pre-test gate for a
   designated test box; use physical recovery after an actual brick.

The Cezanne 26.07.1 release has no `PSP_NVRAM` region. Its first transition
to this Heads layout is therefore an explicit exception to the identical-FMAP
rule:

```sh
bin/starlabs-merge-coreboot.sh \
  --migrate-cezanne-2607 \
  --reference unit-backup.rom \
  --heads heads-cezanne.rom \
  --output first-transition.rom \
  --cbfstool /path/to/cbfstool
```

That mode accepts only the exact old and new 16 MiB layouts. It preserves the
per-unit `EC`, `RW_MRC_CACHE`, `SMMSTORE`, and `CONSOLE` bytes below
`0xd0000`; requires the new `PSP_NVRAM` bytes at `0xd0000`-`0xeffff` to be
erased; and replaces the complete tail from `0xd0000` with the new FMAP and
`COREBOOT`. The result is a full-chip first-transition image and must be
written externally after the two-read recovery gate. Internal `COREBOOT`-only
updates are valid only after the unit already has the new layout. The current
compact Cezanne images fit, but this procedure does not authorize a candidate
flash. StarBook Cezanne remains a read-only control until it is explicitly
allocated for this migration test.

For StarBook MTL the full image is `0x2000000` bytes. Its release layout is:

| Region | Offset | Size |
| --- | ---: | ---: |
| `SI_DESC` | `0x0000000` | `0x004000` |
| `SI_ME` | `0x0004000` | `0x80f000` |
| `EC` | `0x1200000` | `0x020000` |
| `RW_MRC_CACHE` | `0x1220000` | `0x010000` |
| `SMMSTORE` | `0x1230000` | `0x080000` |
| `CONSOLE` | `0x12b0000` | `0x020000` |
| `FMAP` | `0x12d0000` | `0x001000` |
| `COREBOOT` | `0x12d1000` | `0xd2f000` |

## Build matrix

| Heads board | SoC/layout family | `COREBOOT` bytes | Software status |
| --- | --- | ---: | --- |
| `starlabs_adl_horizon` | ADL, 16 MiB | `0x92f000` | Build passes |
| `starlabs_byte_adl` | ADL, 16 MiB | `0x92f000` | Build passes |
| `starlabs_byte_cezanne` | AMD Cezanne, 16 MiB | `0xf0f000` | Build and reproducibility pass; 63,524-byte contiguous margin; external AMD publication also required |
| `starlabs_byte_twl` | TWL/ADL, 16 MiB | `0x92f000` | Build passes |
| `starlabs_labtop_cml` | CML, 16 MiB | `0xb2fe00` | Build passes |
| `starlabs_labtop_kbl` | KBL, 8 MiB | `0x54fe00` | Unsupported for full in-flash Heads; fixed layout is 2,744,604 bytes short |
| `starlabs_lite_adl` | ADL, 16 MiB | `0x92f000` | Build/layout pass; signed normal-path candidate passes offline validation |
| `starlabs_lite_glk` | GLK signed IFWI, 8 MiB | `0x1ffe00` | Unsupported for full in-flash Heads; fixed layout is 5,594,396 bytes short |
| `starlabs_lite_glkr` | GLK signed IFWI, 8 MiB | `0x1ffe00` | Unsupported for full in-flash Heads; fixed layout is 5,591,580 bytes short |
| `starlabs_starbook_adl` | ADL, 32 MiB | `0xf2f000` | Build passes |
| `starlabs_starbook_adl_n` | ADL-N, 16 MiB | `0x92f000` | Build passes |
| `starlabs_starbook_cezanne` | AMD Cezanne, 16 MiB | `0xf0f000` | Build and reproducibility pass; 59,556-byte contiguous margin; external AMD publication also required |
| `starlabs_starbook_mtl` | MTL, 32 MiB | `0xd2f000` | Build passes; first signed hardware attempt did not return remotely |
| `starlabs_starbook_rpl` | RPL, 32 MiB | `0xf2f000` | Build passes |
| `starlabs_starbook_tgl` | TGL, 16 MiB | `0xa2f000` | Build passes |
| `starlabs_starfighter_mtl` | MTL, 32 MiB | `0xf2f000` | Build passes |
| `starlabs_starfighter_rpl` | RPL, 32 MiB | `0xf2f000` | Build passes |
| `starlabs_qemu` | Q35/TPM2 software gate | `0xfe0000` | Build, TPM2 boot, and reproducibility pass |

StarFighter PHX and Horizon 1334U are excluded because they are not current,
stable physical release configurations at this source revision.

Fourteen of the 17 maintained release configurations build and pass their
immutable-layout audit. LabTop KBL, Lite GLK, and Lite GLKR are not active
build, capacity, or hardware gates. Their reported deficits are bytes by which
the required firmware content exceeds the largest immutable-layout CBFS region
in the target SPI ROM. They are not host filesystem or build-disk shortages;
additional free space on the build machine cannot change these results.

The corrected compact Cezanne artifacts were built twice after deleting only
their generated board trees; both pairs were byte-identical. Both images are
16 MiB, pass the FMAP audit, retain `PSP_NVRAM(PRESERVE)`, and keep verified
boot, TPM2, display, USB recovery, flash tools, and kexec. The compact BusyBox
tree receives the normal Heads patches, has a deterministic banner, passes
XZ+BCJ decompression, provides the numeric `lspci` interface used by blob-jail
detection, and removes its remaining ARP applet. The compact runtime libraries
are fully rebuilt before applying their maintained export maps; libpng's
generated link rule retains its map through the final link.

Further compact-profile trimming cannot solve KBL or GLK without crossing the
required verified-boot, TPM2, display, USB recovery, flash, or kexec gates.
Historical software evidence explored an immutable SPI stage0 and signed
A/B/recovery stage1 images on ESP. It includes QEMU signature rejection,
corruption fallback, A/B epoch selection, rollback, TPM2/IMA measurement, and
kexec results. That prototype is retained under the capacity-analysis evidence
as a possible future architecture input only. A security-complete stage0 was
not integrated or proven to fit every target, and staged or reduced modes are
not part of the current Heads scope.

## Proof-board gates

The first StarBook MTL attempt used signed FMP 26.09 capsule SHA-256
`d1b029ff3e27c9379d4b33c0330840e610dde9f7f43aeb5abf0517f390b83c75`
from source `d5c9e993be1518d48820d4dc7adc65e45640702c`. Only `COREBOOT` differed
from the fresh live 26.07 image. After the single update reboot, TCP/22 stayed
closed for all 30 bounded checks. This exact result is preserved pending
physical display and keyboard observation: the unit may be waiting at the
interactive Heads UI. No remote retry is permitted meanwhile.

Record all of these before marking StarBook MTL proven:

- Heads graphical UI on the internal display, with working keyboard input.
- NVMe discovery and selection of a bootable operating system.
- USB recovery media discovery and recovery workflow.
- Successful OS `kexec` handoff.
- TPM2 PCR measurements plus an attestation or quote.
- `cbmem -c` console retrieval and timestamp output.
- Full flash read reporting and `flashprog --wp-status` output; any write test
  remains constrained to FMAP `COREBOOT`.

Lite ADL is the next first-boot target after its current EC IFU/security owner
releases it. Source `47ab6471c12e05c272eb69f6dec2e5e7af4c87cc` produces a
16 MiB ROM with SHA-256
`a387c83b98881dc00a0863465073a365c7f5311ad604118241344aeae8181f0d`.
Its FMAP/IFD audit passes and `COREBOOT` is the only region named by the RMAP.
The validation FMP advertises Lite ADL GUID
`975cd0e6-c540-4e2b-906c-72c0d0d1e40d`, version 26.09, and LSV 26.07; its
decoded payload is byte-identical to the RMAP input and its PKCS#7 signature
verifies against the Star Labs capsule chain. Do not contact or stage it while
another lane holds the unit. No other remote board substitutes for this proof.

## Representative hardware matrix

The supported coreboot hardware matrix reduces required Heads coverage to four
SoC and layout families. Gemini Lake has no supported full in-flash Heads
target in the current fixed 8 MiB layouts.

| Board | Coverage added |
| --- | --- |
| StarBook Cezanne | AMD PSP/APCB/fTPM, AMD display initialization, 16 MiB single-region layout |
| StarBook MTL | Meteor Lake, 32 MiB/14 MiB BIOS layout, discrete TPM2, ITE EC, eDP and PS/2 input |
| Lite ADL (Triangle) | First local/recovery-backed risk target, Alder Lake-N FSP, PTT, ITE EC, eDP and keyboard/touch input |
| StarBook ADL | Alder Lake, 32 MiB/16 MiB BIOS layout, PTT, ITE EC, eDP and PS/2 input |

Do not flash another remote system while StarBook MTL awaits physical
observation. Complete the Lite ADL first-boot proof next. KBL, GLK, and GLKR
have no active Heads hardware or staged-payload validation gate.

The two Cezanne targets now fit without removing verified boot, TPM2, display,
USB recovery, or kexec functionality. StarBook Cezanne remains unchanged as
the known-working AMD control.
