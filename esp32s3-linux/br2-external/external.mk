# Buildroot external tree – BigTreeTech PandaTouch
#
# Custom packages (if any) would be included here:
#   include $(sort $(wildcard $(BR2_EXTERNAL_PANDATOUCH_PATH)/package/*/*.mk))

# ── BusyBox MMU fix ──────────────────────────────────────────────────────────
#
# Root cause
# ----------
# In the jcmvbkbc xtensa-fdpic Buildroot fork, BR2_USE_MMU is never propagated
# from the Kconfig auto.conf into GNU Make.  The fork's Config.in defines
# BR2_XTENSA_USE_MMU, but the BR2_XTENSA_USE_MMU → BR2_USE_MMU select chain is
# broken: BR2_USE_MMU remains empty in Make even for the ESP32-S3 (which has a
# real hardware MMU and runs full Linux).
#
# With BR2_USE_MMU empty, busybox.mk's ifeq ($(BR2_USE_MMU),y) block takes the
# else-branch and executes BUSYBOX_SET_MMU with NOMMU semantics:
#
#     $(call KCONFIG_ENABLE_OPT,CONFIG_NOMMU)   ← sets CONFIG_NOMMU=y
#     $(call KCONFIG_DISABLE_OPT,CONFIG_ASH)    ← disables ash
#     $(call KCONFIG_ENABLE_OPT,CONFIG_HUSH)    ← enables hush instead
#     ...
#
# CONFIG_NOMMU=y in BusyBox's .config causes include/platform.h to set:
#
#     #define BB_MMU 0   (because ENABLE_NOMMU == 1)
#
# ash.c line 308 then fires the fatal error:
#
#     #if !BB_MMU
#     # error "Do not even bother, ash will not run on NOMMU machine"
#     #endif
#
# Why the previous "sed" fix failed
# ----------------------------------
# Earlier build-script attempts used:
#
#     sed -i '/KCONFIG_DISABLE_OPT.*CONFIG_MMU/d' buildroot/package/busybox/busybox.mk
#
# That pattern does NOT exist in the jcmvbkbc fork's busybox.mk (the fork
# handles MMU via CONFIG_NOMMU, not CONFIG_MMU).  The sed was a no-op, and the
# root BUSYBOX_SET_MMU problem remained.
#
# The fix
# -------
# Buildroot's main Makefile includes external.mk files AFTER all package/*.mk
# files (line in Makefile: "include $(BR2_EXTERNAL_MKS)" comes after
# "include $(sort $(wildcard package/*/*.mk))").
# Re-defining BUSYBOX_SET_MMU here therefore REPLACES the fork's definition
# before any recipe uses it.  The replacement unconditionally uses the MMU
# path: disable CONFIG_NOMMU so that BB_MMU = 1 and ash compiles cleanly.
#
define BUSYBOX_SET_MMU
	$(call KCONFIG_DISABLE_OPT,CONFIG_NOMMU)
endef
