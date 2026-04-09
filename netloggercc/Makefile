TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = NetLoggerCC

NetLoggerCC_BUNDLE_EXTENSION = bundle
NetLoggerCC_FILES = NetLoggerCC.m
NetLoggerCC_CFLAGS = -fobjc-arc
NetLoggerCC_LDFLAGS = -undefined dynamic_lookup
NetLoggerCC_INSTALL_PATH = /Library/ControlCenter/Bundles

include $(THEOS_MAKE_PATH)/bundle.mk
