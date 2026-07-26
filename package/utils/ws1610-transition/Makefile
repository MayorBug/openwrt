include $(TOPDIR)/rules.mk

PKG_NAME:=ws1610-transition
PKG_RELEASE:=2
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Georg Seema <georgseema@gmail.com>

include $(INCLUDE_DIR)/package.mk

define Build/Compile
endef

define Package/ws1610-transition
	SECTION:=utils
	CATEGORY:=Utilities
	TITLE:=Huasifei WS1610 one-shot UBI converter
	DEPENDS:=+busybox +dtc +dumpimage +fit-check-sign +mtd +ubi-utils +uboot-mkimage
	PKGARCH:=all
endef

define Package/ws1610-transition/description
	Disposable vendor-layout to OpenWrt all-in-UBI conversion tooling.
endef

define Package/ws1610-transition/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/ws1610-transition $(1)/etc/init.d/
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/ws1610-transition-common.sh $(1)/usr/libexec/
	$(INSTALL_BIN) ./files/usr/libexec/ws1610-transition-convert $(1)/usr/libexec/
	$(INSTALL_BIN) ./files/usr/libexec/ws1610-transition-dispatch $(1)/usr/libexec/
	$(INSTALL_BIN) ./files/usr/libexec/ws1610-transition-stage $(1)/usr/libexec/
endef

define Package/ws1610-transition-setup
	SECTION:=utils
	CATEGORY:=Utilities
	TITLE:=Huasifei WS1610 temporary setup defaults
	DEPENDS:=+luci-ssl-openssl
	PKGARCH:=all
endef

define Package/ws1610-transition-setup/description
	Enables temporary open 2.4 GHz and 5 GHz setup networks.
endef

define Package/ws1610-transition-setup/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-ws1610-transition-wifi \
		$(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,ws1610-transition))
$(eval $(call BuildPackage,ws1610-transition-setup))
