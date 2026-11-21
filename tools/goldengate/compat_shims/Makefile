INSTALL_NAME := /System/Library/PrivateFrameworks/DynamicDesktop.framework/Versions/A/DynamicDesktop
TARGET := build/DynamicDesktop

all: $(TARGET)

$(TARGET): DynamicDesktop.c
	@mkdir -p build
	clang -arch x86_64 -mmacosx-version-min=15.0 -dynamiclib -O2 \
		-install_name $(INSTALL_NAME) \
		-compatibility_version 1.0.0 -current_version 2427.6.0 \
		-o $@ $<
	codesign -f -s - $@

clean:
	rm -rf build

.PHONY: all clean
