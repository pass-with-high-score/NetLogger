ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

THEOS_DEVICE_IP = 127.0.0.1
THEOS_DEVICE_PORT = 2222

THEOS_DEVICE_USER = mobile

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NetLogger
NetLogger_FILES = Tweak.x
NetLogger_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += netloggerprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
