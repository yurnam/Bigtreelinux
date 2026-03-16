# Buildroot external tree – BigTreeTech PandaTouch
#
# Custom packages (if any) would be included here:
#   include $(sort $(wildcard $(BR2_EXTERNAL_PANDATOUCH_PATH)/package/*/*.mk))

# ── BusyBox MMU fix (part 1 of 2) ───────────────────────────────────────────
#
# Problem
# -------
# ash.c:308: #error "Do not even bother, ash will not run on NOMMU machine"
#
# This error fires when BB_MMU == 0.  BusyBox's include/platform.h sets BB_MMU:
#
#   #if ENABLE_NOMMU || \
#       (defined __UCLIBC__ && \
#        UCLIBC_VERSION > KERNEL_VERSION(0, 9, 28) && \
#        !defined __ARCH_USE_MMU__)
#   # define BB_MMU 0
#
# Two conditions can independently trigger BB_MMU=0:
#   A. ENABLE_NOMMU == 1    (from CONFIG_NOMMU=y in BusyBox .config)
#   B. uClibc AND !__ARCH_USE_MMU__ in toolchain headers
#
# Condition A: caused by jcmvbkbc fork's busybox.mk
# --------------------------------------------------
# In the jcmvbkbc xtensa-fdpic fork, BR2_USE_MMU is never propagated from
# Kconfig auto.conf into GNU Make (BR2_XTENSA_USE_MMU → BR2_USE_MMU select
# chain is broken).  The ifeq ($(BR2_USE_MMU),y) guard in busybox.mk always
# takes the ELSE branch:
#   $(call KCONFIG_ENABLE_OPT,CONFIG_NOMMU)  ← sets ENABLE_NOMMU=1 → BB_MMU=0
#   $(call KCONFIG_DISABLE_OPT,CONFIG_ASH)   ← disables ash
#   ...
#
# Condition B: caused by the uClibcFDPIC toolchain
# -------------------------------------------------
# The xtensa-esp32s3-linux-uclibcfdpic toolchain's uClibc-ng headers do NOT
# define __ARCH_USE_MMU__.  So even when CONFIG_NOMMU is unset (ENABLE_NOMMU=0),
# the second condition in platform.h evaluates TRUE → BB_MMU=0 → ash #error.
#
# Fix (this file – condition A)
# -----------------------------
# Redefine BUSYBOX_SET_MMU unconditionally to disable CONFIG_NOMMU.
# Buildroot includes $(BR2_EXTERNAL_MKS) AFTER all package/*/*.mk files, so
# this definition replaces the fork's ifeq/else version.
#
# Fix (this file – condition B, primary)
# ----------------------------------------
# BUSYBOX_CFLAGS is defined in busybox.mk with deferred assignment (=), so
# appending here (external.mk is included AFTER all package/*.mk files) adds
# -D__ARCH_USE_MMU__ to the CFLAGS that Buildroot passes on the make command
# line when building BusyBox.  This is more reliable than the CONFIG_EXTRA_CFLAGS
# Kconfig fragment approach because it bypasses Kconfig/syncconfig entirely.
# Result: __ARCH_USE_MMU__ is defined for all BusyBox compilation units →
# platform.h second condition evaluates FALSE → BB_MMU=1 → ash compiles.
#
# Fix (busybox-mmu.config – condition B, belt-and-suspenders)
# -------------------------------------------------------------
# busybox-mmu.config also sets CONFIG_EXTRA_CFLAGS="-D__ARCH_USE_MMU__".
# BusyBox's Makefile.flags appends CONFIG_EXTRA_CFLAGS to CFLAGS at build time.
# This provides a secondary path in case BUSYBOX_CFLAGS += ever stops applying.
#
define BUSYBOX_SET_MMU
	$(call KCONFIG_DISABLE_OPT,CONFIG_NOMMU)
endef

BUSYBOX_CFLAGS += -D__ARCH_USE_MMU__
