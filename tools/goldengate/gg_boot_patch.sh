#!/bin/sh
set -eu
B="/Library/GoldenGateBridge/Userspace25G342"
L="/private/var/log/gg_early_boot"
LF="$L/bootpatch.log"
S="/System/Library"
H="$S/HIDPlugins"
F="$S/Frameworks"

mkdir -p "$L"
[ -f "$LF" ] && mv -f "$LF" "$LF.prev" 2>/dev/null || true
exec >>"$LF" 2>&1

echo "=== GG Boot Patch Start: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "sw_vers: $(sw_vers 2>/dev/null | tr '\n' ' ')"
echo "uname: $(uname -a)"
[ -d "$B" ] || { echo "ERROR: $B missing"; exit 0; }

ws_b="$(pgrep -x WindowServer 2>/dev/null || true)"
hm=0
gm=0

ov() {
    k="$1"
    t="$2"
    sz="$3"
    shift 3
    sb="$B$t"
    [ -d "$t" ] && [ -d "$sb" ] || { echo "SKIP $t"; return 0; }
    if mount | grep -q " on $t (tmpfs"; then
        echo "ALREADY $t"
    else
        echo "MOUNT $t ($sz)"
        /sbin/mount_tmpfs -o union -s "$sz" "$t"
        [ "$k" = h ] && hm=1 || gm=1
    fi
    for i in "$@"; do
        if [ -e "$sb/$i" ] || [ -L "$sb/$i" ]; then
            cp -Rp "$sb/$i" "$t/" || true
            echo "  OV $t/$i"
        else
            echo "  MISS $sb/$i"
        fi
    done
}

ov h "$S/Extensions/IOHIDFamily.kext/Contents/PlugIns" 4m IOHIDNXEventRouter.plugin
ov h "$H" 8m IOHIDNXEventTranslatorServiceFilter.plugin IOHIDNXEventTranslatorSessionFilter.plugin IOHIDDFREventFilter.plugin IOHIDKeyboardFilter.plugin IOHIDPointerScrollFilter.plugin IOHIDEventProcessorFilter.plugin
ov h "$H/SessionFilters" 4m IOHIDTelemetrySessionFilter.plugin
ov h "$H/ServiceFilters" 8m P192HIDServiceFilter.plugin HIDSensorControlFilter.plugin HIDSensorTimeFilter.plugin UniversalControlServiceFilter.plugin
ov h "$H/ServicePlugins" 4m IOHIDEventServicePlugin.plugin

ov g "$S/Extensions" 192m AMDMTLBronzeDriver.bundle AMDRadeonVADriver.bundle AMDRadeonVADriver2.bundle AMDRadeonX4000GLDriver.bundle AMDShared.bundle
ov g "$S/PrivateFrameworks/RenderBox.framework/Versions/A/Resources" 16m default.metallib
ov g "$F/OpenCL.framework/Versions/A/Libraries" 32m 3425AMD AMDil.dylib IGIL.dylib libCLVMAMDilPlugin.dylib libCLVMIGCPlugin.dylib libCLVMIGILPlugin.dylib
ov g "$F/OpenGL.framework/Versions/A/Libraries" 48m 3425AMD

ws_a="$(pgrep -x WindowServer 2>/dev/null || true)"
ha="$(pgrep -x hidd 2>/dev/null || true)"
amd=0
/usr/sbin/ioreg -c IOPCIDevice -l -w0 2>/dev/null | grep -q '"vendor-id" = <02100000>' && amd=1 || true

if [ "$hm" -eq 1 ] && [ -n "$ws_b$ws_a$ha" ] || { [ "$gm" -eq 1 ] && [ "$amd" -eq 1 ] && [ -n "$ws_b$ws_a" ]; }; then
    echo "Restart GUI $hm/$gm/$amd"
    old="$(pgrep -x 'Language Chooser' 2>/dev/null || true) $(pgrep -x loginwindow 2>/dev/null || true)"
    /bin/launchctl kickstart -k system/com.apple.hidd 2>/dev/null || true
    /bin/sleep 1
    /bin/launchctl kickstart -k system/com.apple.WindowServer 2>/dev/null || true
    /bin/sleep 1
    [ -n "$(echo "$old")" ] && kill -9 $old 2>/dev/null || true
else
    echo "Leaving WS ($ws_a)"
fi
echo "=== End: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
