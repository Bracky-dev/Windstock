ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = windstock
windstock_FILES = Tweak.mm
windstock_CFLAGS = -fobjc-arc -Wno-unused-variable
# `make RAIDS=1` = the separate raids build (0.71-style raid screens on; see Tweak.mm).
ifeq ($(RAIDS),1)
windstock_CFLAGS += -DRAIDS=1
endif
# The 0.71 port (raids, gym v2, 0.71 gym screen) lives in work/port071/tweak.
windstock_CFLAGS += -I../../port071/tweak
windstock_FRAMEWORKS = Foundation AVFoundation UIKit QuartzCore CoreText CoreGraphics WebKit SafariServices CoreImage
# MSHookFunction is provided at runtime by LiveContainer's TweakLoader, not linked
# here -- leave it undefined and let the loader bind it (else: "Undefined _MSHookFunction").
windstock_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
