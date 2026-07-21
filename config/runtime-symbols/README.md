# Runtime symbol contracts

These GNU ld version scripts are the exported API contracts for shared
libraries included in the Heads initramfs. They retain every symbol consumed
by the largest Star Labs profile while allowing section garbage collection to
remove unreachable APIs.

The contracts were generated from the undefined dynamic symbols in the full
Lite GLK tools archive, then checked against the compact Cezanne archive. They
also retain APIs used by dependent modules during configure and linking, such
as zlibVersion. A new consumer that needs another symbol will fail during its
normal module build; update the corresponding map and rerun the full build
matrix.

The maps do not remove required features: TPM2, GPG verification, graphical
recovery, PNG rendering, USB recovery, and kexec remain part of the runtime
and must be exercised by QEMU and hardware validation.
