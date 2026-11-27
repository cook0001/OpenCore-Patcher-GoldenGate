DD_INSTALL_NAME := /System/Library/PrivateFrameworks/DynamicDesktop.framework/Versions/A/DynamicDesktop
WAA_INSTALL_NAME := /System/Library/PrivateFrameworks/WallpaperAerialAssets.framework/Versions/A/WallpaperAerialAssets
BRONZE_IMPOSTOR_INSTALL_NAME := /System/Library/Extensions/AMDMTLBronzeDriver.bundle/Contents/MacOS/impostor.dylib
BRONZE_IMPOSTOR_ORIG_NAME := /System/Library/Extensions/AMDMTLBronzeDriver.bundle/Contents/MacOS/impostor_orig.dylib

DD_TARGET := build/DynamicDesktop
WAA_TARGET := build/WallpaperAerialAssets
BRONZE_STANDALONE_TARGET := build/gg_bronze_metal_bridge_standalone.dylib
BRONZE_TEST_TARGET := build/test_bronze_metal_bridge
BRONZE_IMPOSTOR_TARGET := build/impostor.dylib

all: $(DD_TARGET) $(WAA_TARGET) $(BRONZE_STANDALONE_TARGET) $(BRONZE_TEST_TARGET)

$(DD_TARGET): DynamicDesktop.c
	@mkdir -p build
	clang -arch x86_64 -mmacosx-version-min=15.0 -dynamiclib -O2 \
		-install_name $(DD_INSTALL_NAME) \
		-compatibility_version 1.0.0 -current_version 2427.6.0 \
		-o $@ $<
	codesign -f -s - $@

$(WAA_TARGET): WallpaperAerialAssets.swift
	@mkdir -p build
	swiftc -emit-library -O -target x86_64-apple-macosx15.0 \
		-module-name WallpaperAerialAssets \
		-Xlinker -install_name -Xlinker $(WAA_INSTALL_NAME) \
		-Xlinker -compatibility_version -Xlinker 1.0.0 \
		-Xlinker -current_version -Xlinker 245.6.0 \
		-o $@ $<
	codesign -f -s - $@

$(BRONZE_STANDALONE_TARGET): gg_bronze_metal_bridge.m
	@mkdir -p build
	clang -arch x86_64 -mmacosx-version-min=26.0 -fobjc-arc -O2 -Wall -Wextra -Werror \
		-DGG_RB_SELFTEST -dynamiclib \
		-framework Foundation -framework Metal -framework IOSurface \
		-o $@ $<
	codesign -f -s - $@

$(BRONZE_TEST_TARGET): test_bronze_metal_bridge.m $(BRONZE_STANDALONE_TARGET)
	@mkdir -p build
	clang -arch x86_64 -fobjc-arc -O2 -Wall -Wextra -Werror \
		-framework Foundation -framework Metal \
		-o $@ test_bronze_metal_bridge.m

bronze-test: $(BRONZE_TEST_TARGET)
	./$(BRONZE_TEST_TARGET)

bronze-impostor: gg_bronze_metal_bridge.m
	@test -n "$(IMPOSTOR_ORIG)" || { echo "Set IMPOSTOR_ORIG=/path/to/impostor_orig.dylib" >&2; exit 1; }
	@mkdir -p build
	clang -arch x86_64 -mmacosx-version-min=26.0 -fobjc-arc -O2 -Wall -Wextra -Werror -dynamiclib \
		-install_name $(BRONZE_IMPOSTOR_INSTALL_NAME) \
		-Wl,-reexport_library,$(IMPOSTOR_ORIG) \
		-Wl,-reexport_framework,IOKit \
		-framework Foundation -framework Metal -framework IOSurface \
		-o $(BRONZE_IMPOSTOR_TARGET) $<
	install_name_tool -change $(BRONZE_IMPOSTOR_INSTALL_NAME) $(BRONZE_IMPOSTOR_ORIG_NAME) $(BRONZE_IMPOSTOR_TARGET)
	codesign -f -s - $(BRONZE_IMPOSTOR_TARGET)

clean:
	rm -rf build

.PHONY: all bronze-test bronze-impostor clean
