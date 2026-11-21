DD_INSTALL_NAME := /System/Library/PrivateFrameworks/DynamicDesktop.framework/Versions/A/DynamicDesktop
WAA_INSTALL_NAME := /System/Library/PrivateFrameworks/WallpaperAerialAssets.framework/Versions/A/WallpaperAerialAssets

DD_TARGET := build/DynamicDesktop
WAA_TARGET := build/WallpaperAerialAssets

all: $(DD_TARGET) $(WAA_TARGET)

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

clean:
	rm -rf build

.PHONY: all clean
