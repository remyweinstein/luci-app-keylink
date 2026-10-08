KEYLINK_SOURCE_DIR:=$(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(TOPDIR)/rules.mk

KEYLINK_VERSION:=$(shell sed -n '1{s/^v//;p;}' "$(KEYLINK_SOURCE_DIR)VERSION" 2>/dev/null)
KEYLINK_REPO?=remyweinstein/luci-app-keylink
PKG_VERSION:=$(if $(KEYLINK_VERSION),$(KEYLINK_VERSION),0.0.0)
PKG_RELEASE:=1

LUCI_TITLE:=LuCI: KeyLink - proxy servers and routing
LUCI_DEPENDS:=+xray-core +ucode +ucode-mod-uci +ucode-mod-fs +curl
LUCI_PKGARCH:=all
PKG_LICENSE:=MIT

define Package/luci-app-keylink/conffiles
/etc/config/keylink
endef

define Package/luci-app-keylink/postinst
#!/bin/sh
set -e
[ -n "$${IPKG_INSTROOT}" ] || {
	mkdir -p /etc/keylink
	if [ -n '$(KEYLINK_VERSION)' ]; then
		printf '%s\n' 'v$(KEYLINK_VERSION)' > /etc/keylink/version
	else
		rm -f /etc/keylink/version
	fi
	printf '%s\n' '$(KEYLINK_REPO)' > /etc/keylink/repo
	printf '%s\n' 'native' > /etc/keylink/package
	/etc/init.d/rpcd reload
	/etc/init.d/keylink enable
	/etc/init.d/keylink restart
}
exit 0
endef

define Package/luci-app-keylink/prerm
#!/bin/sh
set -e
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/keylink stop
	/etc/init.d/keylink disable
	if grep -q 'keylink/sub-cron.sh' /etc/crontabs/root 2>/dev/null; then
		sed -i '\#/usr/libexec/keylink/sub-cron.sh#d' /etc/crontabs/root
		/etc/init.d/cron restart >/dev/null 2>&1
	fi
}
exit 0
endef

define Package/luci-app-keylink/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ "$$1" = remove ] || exit 0
rm -f /etc/keylink/version /etc/keylink/repo /etc/keylink/package
rmdir /etc/keylink 2>/dev/null || :
exit 0
endef

include ../../luci.mk

# call BuildPackage - OpenWrt buildroot signature
