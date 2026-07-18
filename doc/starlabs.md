# Star Labs boards

This layer builds Heads for the 17 physical Star Labs coreboot release
configurations current in release 26.07. StarBook MTL is the proof board and
`starlabs_qemu` is the software gate.

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
Cezanne coreboot configuration:

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

Space-constrained Intel targets include `boards/starlabs/compact.config`.
That profile keeps the graphical UI, GPG verification, TPM2 tools, USB
storage, flash tools, CBMEM tools, and kexec. It omits encrypted-storage and
LVM tools, HOTP/TOTP enrollment, QR generation, mobile tethering, extra
filesystem-maintenance tools, PCI inspection, and loadable keymaps. The full
profile remains mandatory for the StarBook MTL proof board.

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
The Gemini Lake analysis targets intentionally expose no flash command.
Every physical coreboot configuration selects the UEFI-variable option
backend, so the per-unit serial number continues to come from the preserved
`SMMSTORE` region. The compiled serial is only a board-family fallback for an
uninitialized store.

Before a first boot on hardware:

1. Make two full-chip reads with the external programmer and require matching
   SHA-256 hashes. Keep one read immutable as the per-unit recovery image.
2. Audit the backup and Heads ROM with `bin/starlabs-fmap-audit.sh`, including
   the correct `--expected-size` and Intel `--ifd-platform` where applicable.
3. Use `bin/starlabs-merge-coreboot.sh` to copy only Heads `COREBOOT` into a
   copy of the per-unit backup when both images have an identical FMAP.
4. Audit the merged image again. The merge tool must report that every byte
   outside `COREBOOT` is identical to the backup.
5. Do not flash until the board is locally recoverable with that programmer,
   or the hardware owner has explicitly made recovery available.

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
Cezanne images do not yet fit, so this procedure prepares the migration path
but does not authorize a candidate flash.

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
| `starlabs_byte_cezanne` | AMD Cezanne, 16 MiB | `0xf0f000` | Capacity deficit: 549,660 bytes; external AMD publication also required |
| `starlabs_byte_twl` | TWL/ADL, 16 MiB | `0x92f000` | Build passes |
| `starlabs_labtop_cml` | CML, 16 MiB | `0xb2fe00` | Build passes |
| `starlabs_labtop_kbl` | KBL, 8 MiB | `0x54fe00` | Capacity deficit: 3,362,908 bytes |
| `starlabs_lite_adl` | ADL, 16 MiB | `0x92f000` | Build passes |
| `starlabs_lite_glk` | GLK signed IFWI, 8 MiB | `0x1ffe00` | Capacity deficit: 8,128,732 bytes; signed IFWI also required |
| `starlabs_lite_glkr` | GLK signed IFWI, 8 MiB | `0x1ffe00` | Capacity deficit: 8,128,028 bytes; signed IFWI also required |
| `starlabs_starbook_adl` | ADL, 32 MiB | `0xf2f000` | Build passes |
| `starlabs_starbook_adl_n` | ADL-N, 16 MiB | `0x92f000` | Build passes |
| `starlabs_starbook_cezanne` | AMD Cezanne, 16 MiB | `0xf0f000` | Capacity deficit: 556,828 bytes; external AMD publication also required |
| `starlabs_starbook_mtl` | MTL, 32 MiB | `0xd2f000` | Build passes; proof-board hardware gate pending |
| `starlabs_starbook_rpl` | RPL, 32 MiB | `0xf2f000` | Build passes |
| `starlabs_starbook_tgl` | TGL, 16 MiB | `0xa2f000` | Build passes |
| `starlabs_starfighter_mtl` | MTL, 32 MiB | `0xf2f000` | Build passes |
| `starlabs_starfighter_rpl` | RPL, 32 MiB | `0xf2f000` | Build passes |
| `starlabs_qemu` | Q35/TPM2 software gate | `0xfe0000` | Build, TPM2 boot, and reproducibility pass |

StarFighter PHX and Horizon 1334U are excluded because they are not current,
stable physical release configurations at this source revision.

## Proof-board gates

Record all of these before marking StarBook MTL proven:

- Heads graphical UI on the internal display, with working keyboard input.
- NVMe discovery and selection of a bootable operating system.
- USB recovery media discovery and recovery workflow.
- Successful OS `kexec` handoff.
- TPM2 PCR measurements plus an attestation or quote.
- `cbmem -c` console retrieval and timestamp output.
- Full flash read reporting and `flashprog --wp-status` output; any write test
  remains constrained to FMAP `COREBOOT`.

## Representative hardware matrix

The smallest defensible set is six systems:

| Board | Coverage added |
| --- | --- |
| StarBook MTL | MTL, 32 MiB/14 MiB BIOS layout, discrete TPM2, ITE EC, eDP and PS/2 input |
| StarBook Cezanne | AMD PSP/APCB/fTPM, AMD display initialization, 16 MiB single-region layout |
| Lite GLKR | Gemini Lake signed IFWI, Nuvoton EC, tablet input/display, smallest ROM layout |
| LabTop KBL | Older Intel 8 MiB layout without a Merlin EC image |
| Byte TWL | Headless/mini-PC path, USB keyboard, external HDMI display, PTT/CRB TPM |
| StarFighter RPL | 32 MiB/16 MiB BIOS layout and distinct StarFighter input/display platform |

Do not allocate the five additional systems until StarBook MTL passes and the
KBL/GLK capacity blockers have a viable architecture.

The two Cezanne targets must also fit without removing verified boot, TPM2,
display, USB recovery, or kexec functionality before allocating either AMD
system. The exact deficits are 549,660 bytes for Byte Cezanne and 556,828 bytes
for StarBook Cezanne.
