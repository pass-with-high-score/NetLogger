ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = NetLoggerPreferences

NetLoggerPreferences_FILES = NetLoggerPreferences.mm NLLogDetailViewController.m
NetLoggerPreferences_INSTALL_PATH = /Library/PreferenceBundles
NetLoggerPreferences_CFLAGS = -fobjc-arc
NetLoggerPreferences_FRAMEWORKS = UIKit
NetLoggerPreferences_PRIVATE_FRAMEWORKS = Preferences
NetLoggerPreferences_LDFLAGS = -F$(THEOS_SDKS_PATH)/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks

include $(THEOS_MAKE_PATH)/bundle.mk
