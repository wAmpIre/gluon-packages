include $(TOPDIR)/rules.mk

PKG_NAME:=ffol-configurator
PKG_VERSION:=1
PKG_RELEASE:=1

PKG_BUILD_DIR := $(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/ffol-configurator
  SECTION:=daemon
  CATEGORY:=Freifunk Oldenburg
  TITLE:=Registers node on netmon
endef

define Package/ffol-configurator/description
	Registers node on netmon
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/ffol-configurator/install
	$(INSTALL_DIR) $(1)/lib/gluon/cron/
	$(INSTALL_DATA) files/lib/gluon/cron/configurator $(1)/usr/lib/micron.d/configurator
	$(INSTALL_DIR) $(1)/lib/ffol/configurator/
	$(INSTALL_BIN) files/lib/ffol/configurator/configurator.sh $(1)/lib/ffol/configurator/
	$(INSTALL_DIR) $(1)/etc/config/
	$(INSTALL_CONF) files/configurator.config $(1)/etc/config/configurator
endef

$(eval $(call BuildPackage,ffol-configurator))
