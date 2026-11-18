# Golden Gate (macOS 27 / Darwin 27) Live Boot R&D Log

This document records the live kernel bring-up root-cause analysis and OpenCore `Kernel->Patch` fixes verified on QEMU/KVM (read-only USB overlay, `MacPro6,1` SMBIOS) for macOS Golden Gate `26B131` (`Darwin Kernel Version 27.2.0`, `xnu-13432.41.4~25/RELEASE_X86_64`).

## Current Bring-Up Status (`Test 35`)

* **Validation target**: `OpenCore 1.0.6` (`ocvalidate` `rc=0`, `0` issues), `boot-args`: `keepsyms=1 serial=3 debug=0x14e -v -no_compat_check -lilubetaall -revbeta -cryptbeta -amfipassbeta ipc_control_port_options=0 -nokcmismatchpanic`, `25` enabled `Kernel->Patch` entries (`AICPM` temporarily disabled in KVM pending TSC-deadline interrupt fix).
* **`Test 35` serial & userspace progression (`2,714` serial lines + extracted `launchd.log` / `Persist` tracev3, `0` kernel panics)**:
  * All `25` Golden Gate patches applied (`GG T12-Fix1`, `GG T14-Fix2`, dynamic `GG T15-Fix3`, `GG T17-Fix4`, `GG T18-Fix5a/5b/5c`, `10` `GG T25` 16 KB CS patches, `7` `GG T26-Sandbox` `0xcc` patches, and `GG T27-Sandbox-Syscall108`).
  * Cleared early kernel VM/commpage, `Image4`, `DSMOS has arrived`, `AppleCredentialManager`, `AppleKeyStore`, `bsd_init`, `MAC Framework`, `AMFI`, `Sandbox` policy initialization, APFS root + Data volume firmlink mount (`Test 28+`), `launchd` (`26B131`), `xpcroleaccountd`, `EndpointSecurity`, `KernelEventAgent`, `WindowServer[100]`, `loginwindow[102]` (`RoleUserInteractiveFocal`), `displaypolicyd`, and `IODisplayWrangler`.

## Root-Cause Fixes (`GG T12-Fix1` – `GG T27-Sandbox-Syscall108`)

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
* **Fix**: Replaced Loop 1's upper-bound check (`0xffffff8000b02461`) so it resolves `_virtual_space_start` dynamically (`GG T15-Fix3` updated in `Test 19` to read the `disp32` operand at `-0x1945(%rip)` across KDK and multiple KC builds, aligning with `andq $-0x1000, %r15`) instead of clamping at `_avail_start`.
* **Verification**: Applied cleanly (`replace count - 1`) in Tests `15`–`35`; `_pmap_init` and zone relocation pass cleanly across KC layouts into IOKit startup.

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
* **Verification (`Test 18`–`35`)**: `ocvalidate` passed (`0` issues); QEMU/KVM booted past `_scale_setup`, `DSMOS has arrived`, `bsd_init`, `MAC Framework`, `AMFI`, and APFS root/Data mount into `launchd` userspace.

### Fix 6 — `GG T25` (`10` patches): 16 KB CodeDirectory Validation (`kernel`)

* **Cause**: Golden Gate `x86_64` binaries (`26B131` `launchd`, `logd`, `RosettaOS` `dyld_shared_cache_x86_64`, DriverKit `dyld_shared_cache_x86_64`) are adhoc/platform-signed with `CodeDirectory` `pageSize = 14` (`16,384` B / four `4 KB` XNU pages per hash slot), whereas `x86_64` XNU hardcodes `PAGE_SIZE = 4096` (`pageSize = 12`) across `CodeDirectory` validation, cluster reads, `_vm_fault_page`, `_vm_fault` fast paths, and `_cs_validate_page_common`.
* **Effect**: In Tests `19`–`24`, `16 KB`-signed `launchd` and shared-cache code pages failed code-signing validation (`cs_tainted` / `CS_KILL`), terminating user processes immediately upon page-in.
* **Fix (`10` coordinated `kernel` patches — `GG T25-CaveB-Guard`, `CaveA/B/C`, `Hook1-CD`, `Hook2-VPCR`, `Hook3-VMFP`, `Hook3b-VMFFast`, `Hook4a-CSAlign`, `Hook4b-CSHash`)**:
  * Accepts `CodeDirectory` `pageSize == 14` (`16 KB`) alongside `12` (`4 KB`) on vnode-backed blobs (`L_cd_check`).
  * Aligns `_vnode_pager_cluster_read` requests on `16 KB` boundaries (`Hook2-VPCR`), ensures all four `4 KB` siblings in a `16 KB` CS slot are resident (`Hook3-VMFP`), and routes unvalidated `16 KB` CS resident pages on the `_vm_fault` fast path through `_vm_fault_page` (`Hook3b-VMFFast` + `CaveC`).
  * Allows `4 KB` faults within `16 KB` CS slots (`Hook4a-CSAlign`) and hashes all four `4 KB` sibling pages together via `data_4k` + resident physmap siblings inside `_cs_validate_page_common` (`Hook4b-CSHash`).
* **Verification (`Test 25`–`35`)**: `26B131` `/sbin/launchd`, `logd`, `Keybag`, and `RosettaOS` `dyld_shared_cache_x86_64` execute with `0` CS taint kills.

### Fix 7 — `GG T26` & `GG T27` (`8` patches): Sandbox `0xcc` Profiles & Syscall `0x108` (`com.apple.security.sandbox`)

* **Cause**: Tahoe `25G342` donor `Sandbox.kext` enforces macOS 26 opcode count `0xc8` (`200` ops), whereas Golden Gate (`26B131`) userspace profiles (`sandboxd` / compiled `.sb` blobs & collections) emit opcode count `0xcc` (`204` ops with `4` inserted operations at indices `>= 2`, `>= 4`, `>= 44`, `>= 86`) and issue macOS `27` sandbox syscall `0x108` (`_syscall_rootless_verify_storage_class`).
* **Effect**: `Test 25` and `Test 26b` panicked in `Sandbox.kext` / `launchd` during early userspace profile initialization (`unexpected sandbox opcode count 0xcc` and missing syscall `0x108`).
* **Fix (`8` patches hosted in `Sandbox.kext` slack `0x6a800`)**:
  * **`GG T26-Sandbox-*` (`7` patches)**: Remaps `0xcc` operation indices onto the `0xc8` donor jump table in `_get_entry_point_for_operation`, accepts `0xcc` alongside `0xc8` in `_profile_init` and `_collection_init`, and computes profile bytecode offsets (`data[4] * 2`, 8-byte aligned) and collection record strides (`data[4] * 2 + 8`) dynamically.
  * **`GG T27-Sandbox-Syscall108` (`1` patch)**: Intercepts syscall dispatch for `0x108` and implements `_syscall_rootless_verify_storage_class` using `_copyin`, `_copyinstr`, `_vfs_context_current`, `_vnode_getfromfd`, `_mac_vnop_getxattr` (`com.apple.rootless.storage`), and `_vnode_put`.
* **Verification (`Test 27`–`35`)**: Zero `Sandbox.kext` panics; `EndpointSecurity`, `KernelEventAgent`, `WindowServer[100]`, `loginwindow[102]`, and `displaypolicyd` launch and stay resident.

## Test 28–35 Userspace Bring-Up & Active Blockers

* **APFS Data Firmlink (`Test 28`–`31`)**: Repaired the test overlay Data volume firmlink extent block so `mount-phase-2` and `sandbox-enable-root-translation` succeed, advancing `Test 29`–`35` into full `launchd` multi-daemon userspace (`WindowServer[100]`, `loginwindow[102]`, `displaypolicyd`, `IODisplayWrangler`).
* **Isolated Userspace & Driver Blockers Under Investigation (`Test 31`–`35` telemetry)**:
  1. **Donor `25G342` daemons vs. `26B131` DSC (`OS_REASON_DYLD`)**: `mediaremoted` and `searchpartyd` on the hybrid image are `25G342` binaries referencing missing Swift symbols in `26B131` `MediaControl` and `FindMyBase`; `MenuBarAgent` and `PreloginSystemBannerRenderer` fail spawn with `EBADARCH` (`86`, ARM64-only in `26B131`); `distnoted` reports `getpwuid` lookup error `0x72`.
  2. **DriverKit `AppleUserHIDDrivers` (`SIGBUS`)**: `dk_dsc_x86_64` (`27,394,048` B, `1668` 16 KB hashes verified `0` bad) loads signatures cleanly under `cs_debug=10`, yet `com.apple.driverkit.AppleUserHIDDrivers` faults (`EXC_BAD_ACCESS`, `code=0x2` `KERN_PROTECTION_FAILURE`) in Test 35 at `rip = base + 0x...03c` referencing DriverKit shared-cache `map[0]` (`0x...6b7`).
  3. **`mds` (`SIGILL` on `SG_PROTECTED_VERSION_1`)**: `mds` (`25G342` protected `__TEXT` `flags=0x8`, encrypted past slice offset `0x3000`, despite `DSMOS has arrived`) traps (`EXC_BAD_INSTRUCTION`, `code=0x1`) repeatedly at `rip = base + 0x...151`.
  4. **`ReportCrashService` corpse exhaustion**: Symbolicating against the `149 MB` shared-cache map exceeds `ReportCrashService`'s `120 MB` soft memory watermark, triggering `Too many corpses being created`.
  5. **QEMU `-vga std` black screen at `WindowServer`**: EFI GOP framebuffer (`1280x800` at `0x80000000`) renders verbose kernel text cleanly, then switches pure black once `IODisplayWrangler` / `WindowServer[100]` / `loginwindow[102]` initialize without a matching framebuffer driver in QEMU.

## Next Session Resume Checklist

1. Capture faulting instruction/target bytes via `_copyin` in `_user_trap` (`EXC_BAD_ACCESS` / `EXC_BAD_INSTRUCTION`) to pinpoint and resolve the DriverKit `AppleUserHIDDrivers` (`0x...03c` / `dk_dsc` `map[0]`) and `mds` (`SG_PROTECTED_VERSION_1` `0x...151`) faults.
2. Replace or shim mismatched `25G342` / ARM64-only daemons (`mediaremoted`, `searchpartyd`, `MenuBarAgent`, `PreloginSystemBannerRenderer`, `distnoted` role account lookup) and resolve GOP / `WindowServer` framebuffer rendering.
3. Re-enable and fix `AppleIntelCPUPowerManagement` (`0x100(%r14)` stale TSC-deadline storm) and `_xcpm_bootstrap` for `MacPro6,1`, then validate bare-metal external USB boot and promote patches into `opencore_legacy_patcher` (`OpenCore-Patcher-GoldenGate`).
