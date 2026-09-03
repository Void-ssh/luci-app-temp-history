#
# Copyright (C) 2026 Void
#
# Licensed under the GNU General Public License v3.0 or later.
#
# Build with the OpenWrt SDK:
#   cp -r luci-app-temp-history <sdk>/package/
#   cd <sdk> && make package/luci-app-temp-history/compile V=s
#
# Or build a .ipk directly from a checkout, with no SDK at all:
#   sh tools/build-ipk.sh
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-temp-history
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Void
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE

LUCI_TITLE:=Temperature and fan history for LuCI
LUCI_DESCRIPTION:=Long-term temperature and fan monitoring with a 30-day chart, \
	configurable thresholds, manual fan control and watchdogs for silent failures. \
	Readings are buffered in RAM and committed to flash once a day.
LUCI_DEPENDS:=+luci-base
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# The version is stamped into the two files that report it, so the page can
# tell the version it was served from the version it is running.
define Build/Prepare
	$(call Build/Prepare/Default)
	$(SED) 's/@@PKG_VERSION@@/$(PKG_VERSION)/g' \
		$(PKG_BUILD_DIR)/root/www/cgi-bin/get-temp-history.cgi \
		$(PKG_BUILD_DIR)/htdocs/luci-static/resources/view/status/temperature-history.js
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/temp_history
endef

# rpcd SILENTLY SKIPS anything in /usr/libexec/rpcd without the user-execute
# bit (plugin.c: !(s.st_mode & S_IXUSR) -> continue), so do not rely on the
# archive's modes surviving.
# The real work lives in a shipped script, so these stay three lines, the
# standalone builder in tools/ can produce identical control scripts, and the
# whole thing can be re-run by hand if a crontab is ever wiped:
#     /usr/libexec/temp-history/setup.sh install
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/usr/libexec/temp-history/setup.sh install
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/usr/libexec/temp-history/setup.sh remove
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
