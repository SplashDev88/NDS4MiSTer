obj-m := nds_mem_wc.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)
ARCH ?= arm
CROSS_COMPILE ?= arm-none-linux-gnueabihf-

.PHONY: all clean

all:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) clean
