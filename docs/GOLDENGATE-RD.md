# Golden Gate (macOS 27 / Darwin 27) Live Boot R&D Log

This document records the live kernel bring-up root-cause analysis and OpenCore `Kernel->Patch` fixes verified on QEMU/KVM (read-only USB overlay, `MacPro6,1` SMBIOS) for macOS Golden Gate `26B131` (`Darwin Kernel Version 27.2.0`, `xnu-13432.41.4~25/RELEASE_X86_64`).

## Current Bring-Up Status (`Test 18`)

* **Validation target**: `OpenCore 1.0.6` (`ocvalidate` `rc=0`, `0` issues), `boot-args`: `keepsyms=1 serial=3 debug=0x14e -v -no_compat_check -lilubetaall -revbeta -cryptbeta -amfipassbeta ipc_control_port_options=0 -nokcmismatchpanic`.
* **`Test 18` serial progression (`1144` lines, `0` spurious CPU resets)**:
  * All `7` Golden Gate patches (`GG T12-Fix1`, `GG T14-Fix2`, `GG T15-Fix3`, `GG T17-Fix4`, `GG T18-Fix5a`, `GG T18-Fix5b`, `GG T18-Fix5c`) applied (`replace count - 1`).
  * `Lilu` + plugins (`WhateverGreen`, `RestrictEvents`, `DebugEnhancer`, `CryptexFixup`, `RSRHelper`, `AMFIPass`) enabled cleanly.
  * Kernel passed early VM startup, `_pmap_init`, `Image4`, `_scale_setup` (`_vm_commpage_init`, `_vm_commpage_text_init`), printed `DSMOS has arrived`, initialized `AppleCredentialManager`, `AppleKeyStore`, `AppleIntelCPUPowerManagement`, and `AppleUSBXHCI` (`QEMU USB Tablet`).
  * Reached `bsd_init`, `MAC Framework`, `dlil_init`, `AMFI`, `rooting via boot-uuid from /chosen: <boot-uuid>`, and started APFS `nx_mount` when the `120s` KVM timeout occurred during slow COMRESET polling across unpopulated AHCI ports.

## Root-Cause Fixes (`GG T12-Fix1` – `GG T18-Fix5`)

### Fix 1 — `GG T12-Fix1`: `_vm_map_steal_memory` (`kernel`)

* **Cause**: In Golden Gate `xnu-13432.41.4~25` (`x86_64`), `_vm_map_steal_memory` calculates stolen virtual addresses from `_virtual_space_start` and advances `_virtual_space_start`, assuming prior initialization. During early boot, callers steal `0x7000` bytes (`0x4000`, `0x2000`, `0x1000`) while `_virtual_space_start == 0` because `_pmap_steal_memory(0, 0)` has not yet run.
* **Effect**: `_vm_map_steal_memory` returns low addresses near `0x0` instead of high-half kernel virtual addresses, faulting early `_vm_page_bootstrap` / `_vm_map_init` allocations immediately on boot.
* **Fix**: Replace the `74`-byte `_vm_map_steal_memory` body in place so it records the three chunk sizes (`0x4000`, `0x2000`, `0x1000`), calls `_pmap_steal_memory(0, 0)` (`xorl %edi, %edi; xorl %esi, %esi; callq _pmap_steal_memory`), initializes `_virtual_space_start = %rax + 0x7000`, and returns `%rax`.
* **Verification**: Applied cleanly (`replace count - 1`) in Tests `12`–`18`; kernel progresses past `_vm_page_bootstrap` and `_vm_map_init`.

### Fix 2 — `GG T14-Fix2`: `_kmem_init` (`kernel`)

* **Cause**: In `_kmem_init` (`0xffffff8000afe44a`), when `trunc_page(start) != VM_MIN_KERNEL_ADDRESS` (`%rbx != %r14`, `%r14 = 0xffffff7f80000000`), `_kmem_init` calls internal map hole-insert helper `0xffffff800035fe90(kernel_map, min, max, 0x81)` with `%rsi` and `%rdx` swapped (`movq %rbx, %rsi; movq %r14, %rdx`, bytes `48 89 de 4c 89 f2`).
* **Effect**: Passing `min > max` causes `0xffffff800035fe90` to fail and return `0`, branching directly to the `ud1l` panic/trap at `0xffffff8000afe63a`.
* **Fix**: Swap the register moves (`48 89 de 4c 89 f2` -> `4c 89 f6 48 89 da`, i.e., `movq %r14, %rsi; movq %rbx, %rdx`) so `min = VM_MIN_KERNEL_ADDRESS` (`%r14`) and `max = trunc_page(start)` (`%rbx`).
* **Verification**: Applied cleanly (`replace count - 1`) in Tests `14`–`18`; execution continues cleanly into `_pmap_init`.

### Fix 3 — `GG T15-Fix3`: `_pmap_init` (`kernel`)

* **Cause**: In `_pmap_init` (`0xffffff8000b0245a`), Loop 1 backfills PV head table entries for pages mapped prior to `_pmap_init` up to `0xffffff8000000000 + trunc_page(_avail_start)`. Early `vm_map_init` and zone initialization steal and map virtual pages past `_avail_start` up to `trunc_page(_virtual_space_start)`.
* **Effect**: Virtual pages between `0xffffff8000000000 + trunc_page(_avail_start)` and `trunc_page(_virtual_space_start)` lack initialized PV table entries, causing a fault/panic when zone relocation unmaps them.
* **Fix**: Patch Loop 1 at `0xffffff8000b02461` (`andq _avail_start(%rip), %r15; addq %rbx, %r15`) to `andq _virtual_space_start(%rip), %r15; nop; nop; nop` (currently using `0x35c198` relative offset for the test KC layout; Phase `1` will resolve `_virtual_space_start` dynamically across KC builds).
* **Verification**: Applied cleanly (`replace count - 1`) in Tests `15`–`18`; `_pmap_init` and zone relocation pass cleanly into IOKit startup.

### Fix 4 — `GG T17-Fix4`: `_image4KernelBoot` (`com.apple.security.Image4`)

* **Cause**: In `Image4.kext` (`_image4KernelBoot`, KDK `0x2bfd`), `_image4KernelBoot` looks up `/chosen`, `/product`, `/defaults`, `/chosen/manifest-properties`, and `/chosen/asmb` via `IORegistryEntry::fromPath`. Unlike `/chosen/asmb` (which only logs when `NULL`), it branches to panic (`je 0x2ceb`/`0x2cf0`/`0x2cf5`) when `/product`, `/defaults`, or `/chosen/manifest-properties` are absent — nodes populated by Apple Silicon iBoot but omitted by `x86_64` UEFI.
* **Effect**: Kernel panics during `Image4` initialization on `x86_64` EFI prior to `_scale_setup`.
* **Fix**: NOP out the three `je` error branches (`0f 84 95 00 00 00`, `74 78`, `74 5b`) following `/product`, `/defaults`, and `/chosen/manifest-properties` lookups so missing DT nodes are tolerated just like `/chosen/asmb`.
* **Verification**: Applied cleanly (`replace count - 1`) in Tests `17`–`18`; kernel initializes `AppleCredentialManager`, `AppleKeyStore`, `AppleACPICPU`, and enters `_scale_setup`.

### Fix 5 — `GG T18-Fix5a / 5b / 5c`: Commpage Initialization & Process Mapping (`kernel`)

* **Cause**: In Golden Gate `x86_64` XNU, `_vm_commpage_text_init` (`0xffffff800039c1f0`), `_vm_commpage_init` (`0xffffff800039c290`), and `_vm_commpage_enter` (`0xffffff800039c330`) were reduced to stubs that do not allocate or store `_commpage32_map`, `_commpage64_map`, `_commpage_text32_map`, `_commpage_text64_map`, `_commpage_text32_location`, or `_commpage_text64_location`, and `_vm_map_exec` (`0xffffff80003511e8`) no longer invokes `_vm_commpage_enter`. Furthermore, `k27` removed `vmkf_beyond_max` (`btq $0x24, %r8`) from `_vm_map_enter_impl`'s fixed bounds check while 64-bit `user_map->max_offset` remains `0x7fffffe00000`, and `_vm_map_lookup_object_and_lock_entry` requires submap flags `((flags & 0x600000) == 0x200000)`.
* **Effect**: Test `17` panicked at `_scale_setup + 0x6bd -> _vm_commpage_init -> _commpage_populate`: `panic(cpu 0 ...): commpage submap is null @commpage.c:135`, blocking VM completion, `bsd_init`, and user process launch.
* **Fix (`3` coordinated OpenCore patches, verified unique match across KDK and `3` KCs)**:
  * **Dynamic `__DATA_CONST` resolution (`5a` & `5b`)**: Reads `%rip`-relative displacements embedded in `_commpage_populate` (`0xffffff8000402051`/`0x402055`) to locate `&(_commpage32_map)` (`__DATA_CONST + 0x11eb8`: `+0x0` `_commpage32_map`, `+0x8` `_commpage64_map`, `+0x10` `_commpage_text32_map`, `+0x18` `_commpage_text64_map`, `+0x18328` `_commpage_text64_location`, `+0x18330` `_commpage_text32_location`) while `__DATA_CONST` is `rwx` prior to `_machine_lockdown`.
  * **`GG T18-Fix5a` (`0xffffff800039c1f0`, `325 B`)**: Reconstructs `_vm_commpage_text_init` (stores `0xffff1000` / `0x7fffffe01000`, creates 32/64-bit submaps via `_pmap_create_options` + `_vm_map_create_with_page_shift` with `(flags & ~0x600000) | 0x200000`, tail-jumps to `_commpage_text_populate`), `_vm_commpage_init` (`0x39c290`, creates 32/64-bit data submaps and tail-jumps to `_commpage_populate`), and `_vm_commpage_enter` (`0x39c330`) tail-jumping into `L_enter_body`.
  * **`GG T18-Fix5b` (`0xffffff8000350eb1`, `287 B`)**: Converts `_vm_map_exec`'s `jl 0x3511be` into `nop; jmp 0x3511be` and hosts `L_enter_body` + `L_hook` inside the bypassed logging block (`0x350ec2..0x350fd0`). `L_enter_body` temporarily sets `user_map->max_offset = 0x800000000000` (restored before return) and maps data (`cur=1/max=1`) and text (`cur=5/max=5`) commpage submaps via `_vm_map_reference` + `_vm_map_enter_impl(..., flags=0x20000000000001)` (matching `_vm_shared_region_insert_submap`, calling `_vm_map_deallocate` on failure). `L_hook` preserves caller registers/16-byte stack alignment, invokes `L_enter_body`, and tail-jumps to `_vm_shared_region_enter`.
  * **`GG T18-Fix5c` (`0xffffff80003511d9`, `20 B`)**: Replaces `0x3511e8 callq _vm_shared_region_enter` in `_vm_map_exec` with `callq L_hook`.
* **Verification (`Test 18`)**: `ocvalidate config_t18_qemu.plist` passed (`0` issues); QEMU/KVM Test `18` booted past `_scale_setup`, `DSMOS has arrived`, `bsd_init`, `MAC Framework`, `AMFI`, and `rooting via boot-uuid` into APFS `nx_mount`.

## Next Session Resume Checklist

1. Run extended QEMU/KVM Test `18` (`timeout 240s` or idle empty AHCI ports eliminated/configured) on the QEMU/KVM testbed to observe APFS root mount completion and `/sbin/launchd` (`PID 1`) + userspace progression under `GG T18-Fix5`.
2. Resolve any remaining userspace/`launchd`/kext blockers revealed in KVM, then validate bare-metal external USB boot on `MacPro6,1`.
3. Generalize `_virtual_space_start` displacement in `GG T15-Fix3` and promote all verified Darwin `27` patches into `opencore_legacy_patcher` (`rd/goldengate` Edition & `rd/OCPBP`).
