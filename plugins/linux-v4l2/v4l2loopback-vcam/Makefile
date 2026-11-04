# vcamuvc Makefile shim (vendored v4l2loopback, identity patch).
# KBUILD_MODULES is set only when kbuild itself drives the build
# (make -C $KERNEL_DIR M=$PWD modules); plain `make` and dkms (which injects
# KERNELRELEASE=<kernelver> into the make invocation, so a KERNELRELEASE
# guard cannot be used) take the shim branch and forward into kbuild.
# Upstream v4l2loopback uses the same guard at this commit.
ifeq ($(KBUILD_MODULES),)

KERNELRELEASE ?= $(shell uname -r)
KERNEL_DIR ?= /lib/modules/$(KERNELRELEASE)/build
PWD := $(shell pwd)

.PHONY: all vcamuvc install clean

all: vcamuvc

vcamuvc:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) modules

install: vcamuvc
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) modules_install

# kbuild leaves dot-prefixed bookkeeping (.*.cmd, .module-common.o) that the
# non-dot globs miss; those embed absolute host paths, so clean them too.
clean:
	rm -f *.o *.ko *.ko.* *.mod *.mod.c *.cmd Module.symvers modules.order \
		.*.o .*.cmd

else

include Kbuild

endif
