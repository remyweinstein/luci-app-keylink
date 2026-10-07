include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI: KeyLink - proxy servers and routing
LUCI_DEPENDS:=+xray-core +ucode +ucode-mod-uci +ucode-mod-fs +kmod-nft-tproxy +v2ray-geoip +v2ray-geosite +curl
LUCI_PKGARCH:=all
PKG_LICENSE:=MIT

include ../../luci.mk

# call BuildPackage - OpenWrt buildroot signature
