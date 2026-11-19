# Golden Gate (macOS 27 / Darwin 27) Live Boot R&D Log

This document records the live kernel and userspace bring-up root-cause analysis, OpenCore `Kernel->Patch` fixes, and `dyld_shared_cache` (`CS` SHA-256 re-hashed) fixes verified on QEMU/KVM (`MacPro6,1` SMBIOS, read-only USB backing overlay) for macOS Golden Gate `26B131` (`macOS 27.2.1`, `Darwin Kernel Version 27.2.0`, `xnu-13432.41.4~25/RELEASE_X86_64`).

## Current Bring-Up Status (`Test 64`, 2026-11-18)

* **Validation target**: `OpenCore 1.0.6` (`ocvalidate` `rc=0`, `0` issues), `boot-args`: `keepsyms=1 serial=3 debug=0x14e -v -no_compat_check -lilubetaall -revbeta -cryptbeta -amfipassbeta ipc_control_port_options=0 -nokcmismatchpanic`, `27` enabled `Kernel->Patch` entries (`25` bring-up patches + `2` `_user_trap` `_copyin` diagnostic patches `GG T36-Diag-Cave/Hook`), `23` enabled `Kernel->Add` kexts, `65,568,768`-byte `BootKernelExtensions.kc` (`189` fileset slices), and `45` shared-cache binary patches across `7` `16 KB` `CodeDirectory` slots (`DriverKit` `libdyld`, `DiskArbitration`, and `SkyLight`).
* **`Test 64` serial, userspace & display progression (`serial_t64.log`: `2,423` lines, `0` kernel panics, `27/27` OC patches applied)**:
  * Cleared early kernel VM/commpage, `Image4`, `DSMOS has arrived`, `AppleCredentialManager`, `AppleKeyStore`, `bsd_init`, `MAC Framework`, `AMFI`, `Sandbox` policy initialization, APFS root + Data volume firmlink mount, `launchd` (`26B131`), and multi-daemon userspace.
  * **DriverKit HID stack healthy**: Following `libdyld.dylib` vtable realignment (`Test 41`), `com.apple.driverkit.AppleUserHIDDrivers` boots with `crashed 0 time(s)` and `AppleUserUSBHostHIDDevice` + `AppleUserHIDEventDriver` start cleanly.
  * **DiskArbitration IPC healthy**: Following `DiskArbitration.framework` MIG alignment (`Test 57`), `DASessionCreate` succeeds (`sess=0x110000`) against the `25G342` `diskarbitrationd` donor.
  * **Framebuffer, `WindowServer` & `Language Chooser` onscreen**: `AppleVirtualGraphics` (`AppleBochVGAFB`) attaches to `0x11111234` (`1280x800`), `SkyLight` (`957.8.8`) + `CoreDisplay` (`291.4`) run under `CompositorSW` (`CGL = Apple Software Renderer`) with `0` crashes, registering `com.apple.windowserver.active`, `com.apple.CARenderServer`, `com.apple.CoreDisplay.master`, and `com.apple.iohideventsystem`, and rendering `11` tracked windows (`Language Chooser[267]` + top-left hardware cursor `w#10` `(5,5,28,40)` visible on `t64` screendump).
  * **Next (`Test 65` staged, ready to apply)**: Clear `SetupAssistantSupportUI` Hello Metal wait (`BackgroundTextureCreator` / `HelloMetalLayer`) so `Language Chooser` advances to its picker UI, and inject `13` universal `[x86_64, arm64e]` `25G342` `HIDPlugins` into `/System/Library/HIDPlugins` + `IOHIDFamily.kext/Contents/PlugIns`.

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

## Test 28–64 Userspace, DriverKit & Shared-Cache Fixes

### APFS Data Firmlink Repair (`Test 28`–`35`)

* **Cause & Effect**: Incorrect test-overlay Data volume firmlink extent block caused `mount-phase-2` and `sandbox-enable-root-translation` to fail prior to `Test 28`.
* **Fix & Verification (`Test 29`–`64`)**: Repaired the firmlink extent block on the test overlay so root + Data volumes mount and unlock `launchd` multi-daemon userspace (`EndpointSecurity`, `KernelEventAgent`, `WindowServer`, `loginwindow`, `displaypolicyd`, `IODisplayWrangler`).

### Fix 8 — `GG T36` & DriverKit `libdyld.dylib` vtable Alignment (`Test 36`–`41`)

* **Cause**: Under `GG T36-Diag-Cave` / `GG T36-Diag-Hook` (`_user_trap` `_copyin` instruction/fault telemetry), `com.apple.driverkit.AppleUserHIDDrivers` was caught faulting (`EXC_BAD_ACCESS`, `code=0x2` `KERN_PROTECTION_FAILURE`) at `rip = base + 0x...03c` executing `48 89 06` (`movq %rax, (%rsi)`) against read-execute `DriverKit` `dyld_shared_cache_x86_64` `map[0]` (`0x7ff80ccb06b7`, `initp=0x5`). Disassembly of `/System/DriverKit/usr/lib/system/libdyld.dylib` (`DriverKit` DSC CS slot `9`, `0x24287..0x24a89`) revealed an `8`-byte `dyld4::LibSystemHelpers` vtable ABI displacement shift (`+0x418..+0x450` instead of `+0x420..+0x458`) relative to `26B131` `dyld`.
* **Effect**: Every DriverKit USB/HID user-server instance (`AppleUserUSBHostHIDDevice` / `AppleUserHIDEventDriver`) crashed during initialization before attaching USB keyboard/mouse interfaces.
* **Fix (`patch_dk_dsc.py`, `8` sites in CS slot `9`)**: Incremented all `8` `LibSystemHelpers` vtable displacements (`+0x418..+0x450` -> `+0x420..+0x458` at offsets `0x24287`, `0x2491b`, `0x24948`, `0x24a05`, `0x24a3e`, `0x24a5c`, `0x24a74`, `0x24a89`) and updated the `16 KB` SHA-256 `CodeDirectory` hash for slot `9`.
* **Verification (`Test 41`–`64`)**: `DriverKit` CS hash readback verified (`initial_cs_ok=True`); `AppleUserUSBHostHIDDevice` and `AppleUserHIDEventDriver` start cleanly (`ok`), and `com.apple.driverkit.AppleUserHIDDrivers` runs with `crashed 0 time(s)`.

### Fix 9 — `DiskArbitration.framework` (`26B131`) MIG ID Alignment (`Test 55`–`58`)

* **Cause**: `26B131` `DiskArbitration.framework` (in `System` `dyld_shared_cache_x86_64`) renumbered Mach MIG subsystem IDs (`0..21`), shifting `_DAServerSessionCreate` from `8` (reply `108`) to `9` (reply `109`), whereas the bridged `25G342` `diskarbitrationd` donor expects IDs `0..19` and rejects `mid=9` with `MIG_BAD_ID` (`0xfffffed0` / `-304`).
* **Effect**: `apfsd` (`could not create DiskArbitration session`) and `DASessionCreate` (`0x0`) failed system-wide, blocking storage/volume notifications and downstream services.
* **Fix (`patch_da_dsc.py`, `34` patches across `3` `16 KB` CS slots `0x60f6`, `0x60f7`, `0x60f8`)**: Returns `MIG_BAD_ID` (`0xfffffed1`) for removed ID `1` (`0x6393`), returns `ENOTSUP` (`0xc02d`) for ID `18` (`0x73A9`), remaps request and reply MIG IDs (`2..21` -> `1..19`) inside `DiskArbitration.framework`, and recomputes SHA-256 hashes for all `3` slots.
* **Verification (`Test 57`–`64`)**: `probe_da` confirmed `mid=8 kr=0x0 rep_id=108 rep_sz=40 ret=0x0 sess=0x110000` and non-null `DASessionCreate` (`0x600002838630`).

### Fix 10 — Framebuffer, `SkyLight` (`957.8.8`) / `CoreDisplay` (`291.4`) & `CompositorSW` Bring-Up (`Test 47`–`64`)

* **Framebuffer & Userspace Overlays (`Test 47`–`56`)**: Under QEMU `-vga std` (`0x11111234`), `AppleVirtualGraphics.kext` (`AppleBochVGAFB`) matches `1280x800`, attaching `AppleUpstreamUserClientDriver`, `AGPM`, and `display0`. A `LaunchDaemon` (`com.oclp.goldengate.bootpatch` -> `gg_boot_patch.sh`) mounts `mount_tmpfs -o union` overlays from `/Library/GoldenGateBridge/Userspace25G342` (`System/Library/Extensions` `AMD*.bundle`, `RenderBox/default.metallib`, `OpenCL`/`OpenGL` `3425AMD`).
* **Cause 1 (`CoreDisplay` `291.4` vs `SkyLight` `957.8.8` `DisplaySystemState`)**: Bridged/donor `CoreDisplay` writes `v0` `DisplaySystemState` without the `1B` flag + `16B` UUID read unconditionally by `26B131` `SkyLight` at `SL_TEXT_FOFF + 0x1BAA37`.
* **Cause 2 (`CompositorSW` backdrop clipping in `ca_prepare_begin_window_update`)**: `SkyLight` unconditionally called `CARenderUpdateSetWillClipBackdrops(..., 1)` (`0x117EB8`), preventing `CompositorSW` (`layer_tile_traverse` / `CGLayerKitFetch`) from receiving finalized backdrop invalidations when `WSMetalCompositorEnabled() == 0`.
* **Fix (`patch_sl_dsc.py`, `3` patches across `3` `16 KB` CS slots `0x16b2`, `0x16da`, `0x17f2`)**: Bypasses the `1B`/`16B` UUID read at `0x1BAA37`, routes `0x117EB8` through a cave at `0x61A320` that invokes `CARenderUpdateSetWillClipBackdrops` only when `WSMetalCompositorEnabled()` returns non-zero, and updates all `3` slot SHA-256 hashes.
* **Verification (`Test 63`–`64`)**: `WindowServer[152]` stays resident with `0` crashes (`CGL = Apple Software Renderer`), `CGMainDisplayID = 0x5b81c5c0` (`1280x800`, `asleep=0`), `com.apple.windowserver.active`, `CARenderServer`, `CoreDisplay.master`, and `iohideventsystem` resolve (`kr=0x0`), and `t64_probe` lists `11` windows with `Language Chooser[267]` (`w#0`/`w#1` onscreen) and the hardware cursor (`w#10 (5,5,28,40) on=1`) visible on `t64` screendump.

## Active Blockers Pinpointed at `Test 64` Exit (Staged for `Test 65`)

1. **`Language Chooser` Blank Canvas / Hello Metal Wait (`SetupAssistantSupportUI`, `dyld_shared_cache_x86_64.05`, base `0x7ffd2295e000`)**:
   * Full disassembly of `Language Chooser` (`_desktopImageForScreen:`, `desktopImageWithFiltersForScreen:`, `onAnimationDidFinish`) and `26B131` `SetupAssistantSupportUI` (`BookendViewProvider`, `HelloMetalLayer`) confirmed that `Language Chooser`'s blurred desktop background (`NSImageView` + `CAFilter`) is pure Core Animation (`0` Metal calls), but it only lowers `_helloWindow` and calls `updateBackgroundWindows` + `showLanguagePickerWindowNotifiy:` `0.5s` after `SetupAssistantSupportUI`'s `onAnimationDidFinish` fires.
   * Under `CompositorSW`, `BackgroundTextureCreator` fails `_MTLCreateSystemDefaultDevice()` (`== nil`), leaving `BookendViewProvider +0xb0` (`backgroundTexture`) `nil`, `HelloMetalLayer.init` without Metal pipelines, and both `startAnimation_inner` (`0x7ffd22991950`) and `resumeAnimation_inner` (`0x7ffd22991c10`) stuck in `'Waiting for background data'` (`0x7ffd22991a34` / `0x7ffd22991cf4`). A `448`-byte `__TEXT` cave (`0x7ffd229e7e40..0x7ffd229e8000`, CS slot `35449`) and `willAnimateWithLogo` (`0x7ffd22990bdf`) are targeted for `Test 65` to trigger immediate `onAnimationDidFinish` when `_MTLCreateSystemDefaultDevice() == nil`.
2. **Missing `x86_64` Userland `HIDPlugins` (`WindowServer` `0xe00002be` `kIOReturnUnsupported`)**:
   * `t64_log.txt` showed `WindowServer[152]` failing `__IOHIDServiceLoadObjcServicePlugin` / `IOHIDSessionFilterCreateWithClass` (`0xe00002be`) even with healthy DriverKit `AppleUserHIDEventDriver`.
   * Architecture audit of `GoldenGate` HID bundles found `15` `arm64e`-only plugins, of which `13` exist on Tahoe `25G342` as universal `[x86_64, arm64e]` bundles (including `IOHIDEventServicePlugin.plugin` in `ServicePlugins/`, `IOHIDNXEventRouter.plugin` in `IOHIDFamily.kext/Contents/PlugIns/`, and core keyboard/pointer/scroll/translator filters in `HIDPlugins/`); only `IOHIDXPCEventSessionFilter.plugin` and `EXBrightHIDPlugin.plugin` lack `25G342` `x86_64` slices. All `13` universal bundles (`hid_25g342.tar.gz`, `1,257,396` B) are staged for `mount_tmpfs` union overlay in `Test 65`.
3. **Remaining Isolation & Hardware Bring-Up Items**:
   * Replace/bridge `mds` (traps with `SIGILL` `exc=2 code=0x1` at `rip = base + 0x...151` on `SG_PROTECTED_VERSION_1` `__TEXT`), mismatched `25G342` daemons (`mediaremoted`, `searchpartyd`, `nsurlsessiond`), and `ARM64`-only `MenuBarAgent` / `PreloginSystemBannerRenderer`.
   * Re-enable and fix `AppleIntelCPUPowerManagement` (`0x100(%r14)` stale TSC-deadline timer storm) and `_xcpm_bootstrap`, complete interactive `Language Chooser` -> `Setup Assistant` -> desktop verification, validate bare-metal external USB boot on `MacPro6,1`, and integrate patches into `opencore_legacy_patcher` (`OpenCore-Patcher-GoldenGate`).
