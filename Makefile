# Strata prototype build.
#
#   make            assembler, emulator, RTL simulator
#   make examples   assemble every example
#   make test       run every example on the emulator and the RTL and compare
#   make test-small the same (examples, StrataOS boot) with 8 overlay map entries
#                   (NXMAP=8, the FPGA configuration; part of make test)
#   make test-ls    the examples, lssize.s and StrataOS's refusal with smaller Local
#                   Stores (32/32, 16/4, 4/32 KiB D-LS/I-LS; part of make test)
#   make run        run every example on the RTL simulator, showing its output
#   make run-emu    the same on the C emulator
#   make run-NAME   run one example on the RTL, e.g. make run-mandel
#   make show-NAME  run one example on the emulator and keep its window open
#                   after it halts, e.g. make show-gfx (show-rtl-NAME: the RTL)
#   make boot       boot StrataOS on the emulator and type at its shell
#   make boot-ws    the same, with the window server started at boot (os/files-ws/rc)
#   make boot-demo  boot StrataOS on the emulator with a scripted session
#   make boot-rtl   boot StrataOS on the Verilog simulator (interactive)
#   make boot-rtl-demo  the scripted session on the Verilog simulator
#   make manual     rebuild doc/Strata-Architecture-Reference-Manual.pdf
#   make test-jit   the JIT against the interpreter on every example and Forth
#   make bench      interpreter vs JIT wall time (mandel, gfx, Forth gfx demo)
#   make conformance  the architectural conformance suite on interpreter, JIT and RTL
#   make fuzz       3-way differential fuzzer (SEEDS=N, FIRST=seed)
#   make wasm       the emulator as WebAssembly for the site's play page (emcc)
#   make test-wasm  that build under node against the native interpreter (node, emcc)
#   make wasm-rtl   the RTL simulator for the browser: build/web/strata-rtl.js (verilator, em++)
#   make test-wasm-rtl  that build under node against the native simulator
#   make web-docs   the manual's instruction set and architecture outline as web pages
#   make dbg        strata-dbg, the text debugger (part of `make all`)
#   make debug-NAME debug an example with strata-dbg, e.g. make debug-pipeline
#   make debug-os   boot StrataOS under strata-dbg (StrataOS-aware: info processes, break process NAME)
#   make debug-web  the web debugger against the desktop engine: http://localhost:4444/debug/
#                   (one program per engine: DEBUG_WEB=NAME, default pipeline)
#   make debug-web-os  the same with StrataOS booting (the page's Run menu types at its shell)

CC      ?= cc
CFLAGS  ?= -std=gnu11 -O2 -Wall -Wextra
NCORES  ?= 8
NXMAP   ?= 16
DLS_KIB ?= 64
ILS_KIB ?= 64

# SDL2 for the framebuffer window, when pkg-config finds it (else -DNO_SDL:
# no window, PRESENT only records frames for -F)
SDL_CFLAGS := $(shell pkg-config --cflags sdl2 2>/dev/null)
SDL_LIBS   := $(shell pkg-config --libs sdl2 2>/dev/null)
ifeq ($(SDL_LIBS),)
SDL_CFLAGS := -DNO_SDL
endif

BUILD   := build
RTL     := rtl/strata_pkg.sv rtl/strata_decode.sv rtl/strata_alu.sv rtl/strata_div.sv rtl/strata_mul.sv \
           rtl/strata_ram.sv rtl/strata_uart.sv rtl/strata_tu.sv rtl/strata_bus.sv \
           rtl/strata_mem.sv rtl/strata_dev.sv rtl/strata_core.sv rtl/strata_top.sv
EXAMPLES := $(wildcard examples/*.s)
IMAGES  := $(patsubst examples/%.s,$(BUILD)/examples/%.stx,$(EXAMPLES))
PROGS   := $(patsubst examples/%.s,$(BUILD)/prog/%,$(EXAMPLES))
EMU     := $(BUILD)/strata-emu -c $(NCORES)

.PHONY: all examples test test-small test-ls clean lint run run-emu boot boot-net boot-ws boot-demo boot-rtl boot-rtl-demo os fpga-images manual

all: $(BUILD)/sasm $(BUILD)/strata-emu $(BUILD)/strata-rtl $(BUILD)/netrelay $(BUILD)/strata-dbg

# the browser's relay to the real network (the play page's "relay" mode): the
# simulators' user-mode NAT behind a small WebSocket server
$(BUILD)/netrelay: tools/netrelay.c common/netnat.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ tools/netrelay.c

# the text debugger (dbg/): a front-end of strata-emu's debug engine (emu/debug.c)
$(BUILD)/strata-dbg: dbg/strata-dbg.c common/json.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ dbg/strata-dbg.c

$(BUILD)/sasm: asm/sasm.c asm/isa.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ asm/sasm.c

# the JIT (emu/jit/): each backend compiles to nothing on other hosts
JIT_SRC := emu/jit/jit.c emu/jit/jit_arm64.c emu/jit/jit_x86_64.c
# the debug engine (--debug): included by emu/emu.c
DBG_ENGINE := emu/debug.h emu/debug.c emu/debug_sym.c emu/debug_tt.c emu/debug_io.c common/json.h

$(BUILD)/strata-emu: emu/emu.c $(JIT_SRC) $(DBG_ENGINE) emu/jit/jit.h emu/jit/jit_be.h asm/isa.h common/stx.h common/platform.h common/display.h common/net.h common/netnat.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(SDL_CFLAGS) -o $@ emu/emu.c $(JIT_SRC) $(SDL_LIBS)

$(BUILD)/strata-rtl: $(RTL) sim/main.cpp common/stx.h common/platform.h common/display.h common/net.h common/netnat.h asm/isa.h
	@mkdir -p $(BUILD)
	verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial fast \
	  -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  -DSIMULATION -GNCORES=$(NCORES) -GNXMAP=$(NXMAP) -GDLS_KIB=$(DLS_KIB) -GILS_KIB=$(ILS_KIB) --top-module strata_top \
	  -Mdir $(BUILD)/obj_dir -o strata-rtl \
	  -CFLAGS "-O2 -std=c++17 -DNCORES=$(NCORES) -DNXMAP=$(NXMAP) -DDLS_KIB=$(DLS_KIB) -DILS_KIB=$(ILS_KIB) $(SDL_CFLAGS)" \
	  -LDFLAGS "$(SDL_LIBS)" $(RTL) sim/main.cpp
	rm -f $@ && cp $(BUILD)/obj_dir/strata-rtl $@

lint:
	verilator --lint-only -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -DSIMULATION --top-module strata_top $(RTL)
	verilator --lint-only -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM --top-module strata_top $(RTL)
	verilator --lint-only -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -GDLS_KIB=8 -GILS_KIB=4 --top-module strata_top $(RTL)

$(BUILD)/examples/%.stx: examples/%.s $(BUILD)/sasm $(wildcard examples/lib/*.s)
	@mkdir -p $(BUILD)/examples
	$(BUILD)/sasm -g $(@:.stx=.map) -o $@ $<

examples: $(IMAGES)

test: all examples os
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/compare.sh $(IMAGES)
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/compare-boot.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img os/demo.txt
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/compare-boot.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img os/guest-demo.txt guests
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-break.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-sh.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-vi.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-vifs.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-fs-progs.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-net.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-http.sh $(BUILD)/bootrom.stx $(BUILD)/http-test/disk.img
	BUILD=$(BUILD) ./tools/test-ws.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-preempt.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-isolate.sh $(BUILD)/bootrom.stx $(BUILD)/isol-test/disk.img
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-guest.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img
	BUILD=$(BUILD) ./tools/test-procs.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-boot-jit.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img os/demo.txt
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-fb.sh $(BUILD)/examples/gfx.stx
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-jit.sh
	BUILD=$(BUILD) ./tools/test-dbg.sh
	BUILD=$(BUILD) NCORES=$(NCORES) ./conformance/run.sh
	$(MAKE) test-small
	$(MAKE) test-ls
	@if command -v node >/dev/null 2>&1 && command -v $(EMCC) >/dev/null 2>&1; then $(MAKE) test-wasm; \
	else echo "test-wasm: skipped (needs node and $(EMCC))"; fi
	@if command -v node >/dev/null 2>&1 && command -v $(EMXX) >/dev/null 2>&1 && [ "$(NCORES)" = "$(WEB_RTL_CORES)" ]; then $(MAKE) test-wasm-rtl; \
	else echo "test-wasm-rtl: skipped (needs node and $(EMXX), and NCORES = WEB_RTL_CORES)"; fi

# the small (FPGA) configuration: 8 overlay map entries instead of 16. The
# RTL is built with NXMAP=8 in its own directory and compared with the
# emulator's -X 8 on the examples and a full StrataOS boot and session.
SMALL := $(BUILD)/small
test-small:
	$(MAKE) BUILD=$(SMALL) NXMAP=8 all examples os
	BUILD=$(SMALL) NCORES=$(NCORES) EMU_ARGS="-X 8" ./tools/compare.sh $(patsubst $(BUILD)/%,$(SMALL)/%,$(IMAGES))
	BUILD=$(SMALL) NCORES=$(NCORES) EMU_ARGS="-X 8" ./tools/compare-boot.sh $(SMALL)/bootrom.stx $(SMALL)/disk.img os/demo.txt

# smaller Local Stores (DLS_KIB / ILS_KIB, the emulator's -L): RTLs built
# with 32/32, 16/4 and 4/32 KiB (D-LS/I-LS) in their own directories,
# compared with the emulator on every example that fits (32/32: all of them;
# 16/4 and 4/32: those whose data and stack, and code, fit), on
# conformance/tests/lssize.s (which needs a 16 KiB D-LS: the harness's
# signature buffer), and on StrataOS refusing the machine (it needs 64 KiB of
# each; 64/32, which the kernel itself refuses, on the emulator only).
LSA := $(BUILD)/ls32
LSB := $(BUILD)/ls16-4
LSC := $(BUILD)/ls4-32
LSB_EXAMPLES := clock faults hello mandel pipeline race
LSC_EXAMPLES := clock faults hello mandel overlay race
test-ls: os
	$(MAKE) BUILD=$(LSA) DLS_KIB=32 ILS_KIB=32 all examples
	BUILD=$(LSA) NCORES=$(NCORES) EMU_ARGS="-L 32" ./tools/compare.sh $(patsubst $(BUILD)/%,$(LSA)/%,$(IMAGES))
	BUILD=$(LSA) NCORES=$(NCORES) EMU_ARGS="-L 32" ./conformance/run.sh lssize
	BUILD=$(LSA) NCORES=$(NCORES) EMU_ARGS="-L 32" ./tools/test-ls-boot.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img
	$(MAKE) BUILD=$(LSB) DLS_KIB=16 ILS_KIB=4 all examples
	BUILD=$(LSB) NCORES=$(NCORES) EMU_ARGS="-L 16,4" ./tools/compare.sh $(patsubst %,$(LSB)/examples/%.stx,$(LSB_EXAMPLES))
	BUILD=$(LSB) NCORES=$(NCORES) EMU_ARGS="-L 16,4" ./conformance/run.sh lssize
	$(MAKE) BUILD=$(LSC) DLS_KIB=4 ILS_KIB=32 all examples
	BUILD=$(LSC) NCORES=$(NCORES) EMU_ARGS="-L 4,32" ./tools/compare.sh $(patsubst %,$(LSC)/examples/%.stx,$(LSC_EXAMPLES))
	BUILD=$(LSC) NCORES=$(NCORES) EMU_ARGS="-L 4,32" ./tools/test-ls-boot.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img
	BUILD=$(BUILD) NCORES=$(NCORES) EMU_ARGS="-L 64,32" RTL=none ./tools/test-ls-boot.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img

run: all examples
	@for img in $(IMAGES); do \
	  printf '\n==== %s (RTL) ====\n' $$(basename $$img .stx); \
	  $(BUILD)/strata-rtl $$img 2>&1; \
	done

run-emu: all examples
	@for img in $(IMAGES); do \
	  printf '\n==== %s (emulator) ====\n' $$(basename $$img .stx); \
	  $(EMU) $$img 2>&1; \
	done

run-%: $(BUILD)/strata-rtl $(BUILD)/examples/%.stx
	@$(BUILD)/strata-rtl $(BUILD)/examples/$*.stx

# show-rtl-% comes first: older makes take the first pattern that matches
show-rtl-%: $(BUILD)/strata-rtl $(BUILD)/examples/%.stx
	@$(BUILD)/strata-rtl -H $(BUILD)/examples/$*.stx

show-%: $(BUILD)/strata-emu $(BUILD)/examples/%.stx
	@$(EMU) -T real -H $(BUILD)/examples/$*.stx

# ---- the debuggers (emu/debug.c, dbg/, site/debug/) --------------------------
# Deterministic runs (-T virtual) keep a history for time travel; -J is for
# fast continues (ff), which catch up unrecorded. The OS targets open the
# window when the guest draws (ws).
.PHONY: dbg debug-os debug-web debug-web-os test-dbg
dbg: $(BUILD)/strata-dbg $(BUILD)/strata-emu

debug-%: $(BUILD)/strata-dbg $(BUILD)/strata-emu $(BUILD)/examples/%.stx
	@$(BUILD)/strata-dbg -c $(NCORES) -J -T virtual $(BUILD)/examples/$*.stx

debug-os: $(BUILD)/strata-dbg $(BUILD)/strata-emu os
	@cp $(BUILD)/disk.img $(BUILD)/disk-run.img
	@$(BUILD)/strata-dbg -c 8 -J -T virtual -d $(BUILD)/disk-run.img --os $(BUILD) $(BUILD)/bootrom.stx

debug-web-os: $(BUILD)/strata-emu os
	@cp $(BUILD)/disk.img $(BUILD)/disk-run.img
	@$(BUILD)/strata-emu -c 8 -J -T virtual -d $(BUILD)/disk-run.img --os $(BUILD) --debug 4444 --www site $(BUILD)/bootrom.stx

DEBUG_WEB ?= pipeline
debug-web: $(BUILD)/strata-emu $(BUILD)/examples/$(DEBUG_WEB).stx
	@$(BUILD)/strata-emu -c 4 -J -T virtual -g none --debug 4444 --www site $(BUILD)/examples/$(DEBUG_WEB).stx

test-dbg: $(BUILD)/strata-dbg $(BUILD)/strata-emu examples os
	BUILD=$(BUILD) ./tools/test-dbg.sh

# ---- firmware, OS and disk image -------------------------------------------
OS_FILES := $(wildcard os/files/*)

$(BUILD)/mkdisk: tools/mkdisk.c common/stx.h asm/isa.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ tools/mkdisk.c

$(BUILD)/bootrom.stx: firmware/bootrom.s firmware/fw.s $(BUILD)/sasm
	$(BUILD)/sasm -g $(BUILD)/bootrom.map -o $@ firmware/bootrom.s

$(BUILD)/kernel.stx: os/kernel.s $(wildcard os/kunits/*.s) firmware/fw.s $(BUILD)/sasm
	$(BUILD)/sasm -g $(BUILD)/kernel.map -o $@ os/kernel.s

# StrataOS 0.1 disk contents:
#   servers (os/servers/*.s): proc dev fs tty pipe
#   programs written against os/lib/sys.s (os/progs/*.s, except as and units)
#   the examples, assembled to run as bare-metal programs (code at
#   I-LS 0x8000); clock and gfx are left out: they need the device root
#   capability, which only the dev server holds
#   as and units, and sources for the assembler inside StrataOS (programs
#   have no .include, so includes are expanded here)
OS_EXCLUDE := clock gfx
OS_EXAMPLES := $(filter-out $(OS_EXCLUDE),$(patsubst examples/%.s,%,$(EXAMPLES)))
PROGS   := $(patsubst %,$(BUILD)/prog/%,$(OS_EXAMPLES))
SERVERS := proc dev fs tty pipe net
UTILS   := sh ls cat rm df ps free uptime devs hexdump cores sched seq grep wc upper spin tag tags cp mv touch guest
SPROGS  := $(patsubst %,$(BUILD)/prog/%,$(SERVERS))
UPROGS  := $(patsubst %,$(BUILD)/prog/%,$(UTILS))
# the network programs (os/servers/net.s is the server): no sources on the disk
NETUTILS := ping nc tcpecho ifconfig netstat host httpd
NPROGS  := $(patsubst %,$(BUILD)/prog/%,$(NETUTILS))
USRCS   := $(patsubst %,$(BUILD)/src/%.s,$(filter-out guest,$(UTILS)))  # guest: binary on the disk, source kept off /src (unchanged listing)
EXSRCS  := $(patsubst %,$(BUILD)/src/%.s,$(OS_EXAMPLES))
SRCS    := $(EXSRCS) $(BUILD)/src/as.s $(BUILD)/src/units.s

# (every program also gets a debug map, PROG.map next to it: strata-dbg --os)
$(BUILD)/prog/%: examples/%.s $(BUILD)/sasm $(wildcard examples/lib/*.s)
	@mkdir -p $(BUILD)/prog
	$(BUILD)/sasm -T 0x8000 -g $@.map -o $@ $<

$(SPROGS): $(BUILD)/prog/%: os/servers/%.s os/lib/sys.s os/lib/srv.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/prog
	$(BUILD)/sasm -T 0x8000 -g $@.map -o $@ $<

$(UPROGS) $(NPROGS): $(BUILD)/prog/%: os/progs/%.s os/lib/sys.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/prog
	$(BUILD)/sasm -T 0x8000 -g $@.map -o $@ $<

# guest OS images: bare STX (no "SYS2", no system library), booted as a guest
GUESTS  := gdemo ghostile
GUESTIMG := $(patsubst %,$(BUILD)/guest/%,$(GUESTS))
$(GUESTIMG): $(BUILD)/guest/%: os/guests/%.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/guest
	$(BUILD)/sasm -g $@.map -o $@ $<
# the bare-metal Forth as a guest (lang/forth/guest/ over lang/forth/bare/):
# the disk file forth.g, tagged guest and forth, which `guest forth` finds (the
# name forth is the StrataOS program's)
FORTH_GUEST_SRC := lang/forth/forth.s $(wildcard lang/forth/bare/*.s) $(wildcard lang/forth/guest/*.s)
FORTH_GUEST_FS  := lang/forth/core.fs lang/forth/tools.fs lang/forth/see.fs lang/forth/guest/start.fs
$(BUILD)/forth-guest/corefs.s: $(FORTH_GUEST_FS)
	@mkdir -p $(BUILD)/forth-guest
	$(FORTH_EMBED) $(FORTH_GUEST_FS) > $@
$(BUILD)/guest/forth.g: $(FORTH_GUEST_SRC) $(BUILD)/forth-guest/corefs.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/guest
	$(BUILD)/sasm -I lang/forth/guest -I lang/forth/bare -I $(BUILD)/forth-guest -g $(BUILD)/guest/forth.map -o $@ lang/forth/forth.s
FORTH_GUEST := $(BUILD)/guest/forth.g

# untag is tag under another name (it looks at the name it was started by)
$(BUILD)/prog/untag: $(BUILD)/prog/tag
	cp $< $@
	cp $<.map $@.map

# retag too (it replaces a file's tags)
$(BUILD)/prog/retag: $(BUILD)/prog/tag
	cp $< $@
	cp $<.map $@.map

# the window server and its clients (os/ws/, os/lib/gfx.s, os/lib/wsclient.s)
WSPROGS := $(patsubst %,$(BUILD)/prog/%,ws term wmandel wclock)
$(WSPROGS): $(BUILD)/prog/%: os/progs/%.s $(wildcard os/ws/*.s) os/lib/gfx.s os/lib/font/font.s os/lib/wsclient.s os/lib/sys.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/prog
	$(BUILD)/sasm -T 0x8000 -I os/ws -I os/lib -g $@.map -o $@ $<

# vi, the editor: its keyword tables come from the assembler, the Forth README
# and the site's highlighter (tools/vi-syntax.py writes them as an include)
$(BUILD)/vi-syntax.s: tools/vi-syntax.py tools/web-code.py asm/sasm.c lang/forth/README.md site/hl.js
	@mkdir -p $(BUILD)
	python3 tools/vi-syntax.py $@

# the same tables for the Forth port, lang/forth/vi.fs, as Forth source (a disk file next to it)
$(BUILD)/forth-os/vi-syntax.fs: tools/vi-syntax.py tools/web-code.py asm/sasm.c lang/forth/README.md site/hl.js os/progs/vi.s
	@mkdir -p $(BUILD)/forth-os
	python3 tools/vi-syntax.py $@

# the Forth ports of os/progs (lang/forth/progs/*.fs) and their library, packed into
# one disk file (the directory has room for 128 files) behind a loader, lang/forth/progs.fs
FORTH_PROGS := lang/forth/sys.fs $(sort $(wildcard lang/forth/progs/*.fs))
$(BUILD)/forth-os/progs.pk: tools/forth-pack.py lang/forth/progs.fs $(FORTH_PROGS)
	@mkdir -p $(BUILD)/forth-os
	python3 tools/forth-pack.py -o $@ lang/forth/progs.fs $(FORTH_PROGS) untag.fs=tag.fs retag.fs=tag.fs

$(BUILD)/prog/vi: os/progs/vi.s os/lib/sys.s $(BUILD)/vi-syntax.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/prog
	$(BUILD)/sasm -T 0x8000 -I $(BUILD) -o $@ $<

$(BUILD)/prog/units: os/progs/units.s examples/lib/print.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/prog
	$(BUILD)/sasm -T 0x8000 -g $@.map -o $@ $<

$(BUILD)/prog/as: os/progs/as.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/prog
	$(BUILD)/sasm -T 0x8000 -g $@.map -o $@ $<

# the C compiler (lang/cc/, DESIGN.md section 6):
#   cc.lib      what compiled programs are made with: the run-time library
#               (assembled at fixed addresses), the table of its exported names
#               and the headers (lang/cc/lib/mklib.py packs them)
#   strata-cc   cc.c, the compiler, built for this machine (lang/cc/host/): the
#               cross compiler
#   prog/cc     cc.c compiled by strata-cc: the compiler inside StrataOS. It is
#               larger than an image may be, so its code units are a second
#               file, cc.u, which its start-up code loads
#   prog/cc0    cc.s, the bootstrap compiler in Strata assembly, and cc0.lib,
#               cc.lib plus cc0's own code units. make test-cc-boot compiles
#               cc.c with it inside StrataOS and checks that the result,
#               compiling cc.c again, gives prog/cc byte for byte
CC_SRC  := $(wildcard lang/cc/*.s) lang/cc/lib/rt.s
CC_HDRS := $(sort $(wildcard lang/cc/lib/include/*.h))
CC_LIBIN := $(BUILD)/cc/libc.stx $(BUILD)/cc/libc.map lang/cc/lib/libc.s $(CC_HDRS) $(BUILD)/cc/asm.tab
# the instruction table of asm("..."), made from the assembler itself
$(BUILD)/cc/asm.tab: lang/cc/lib/mkasm.py asm/sasm.c $(BUILD)/sasm
	@mkdir -p $(BUILD)/cc
	python3 lang/cc/lib/mkasm.py $(BUILD)/sasm asm/sasm.c $@
$(BUILD)/cc/libc.stx: lang/cc/lib/libc.s lang/cc/lib/rt.s lang/cc/lib/fp.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/cc
	$(BUILD)/sasm -T 0x8000 -I lang/cc/lib -g $(BUILD)/cc/libc.map -o $@ lang/cc/lib/libc.s
$(BUILD)/cc/cc.lib: $(BUILD)/cc/libc.stx lang/cc/lib/mklib.py $(CC_HDRS) $(BUILD)/cc/asm.tab
	python3 lang/cc/lib/mklib.py $@ $(CC_LIBIN)
$(BUILD)/strata-cc: lang/cc/cc.c lang/cc/host/host.c lang/cc/host/strata.h
	@mkdir -p $(BUILD)
	$(CC) -O2 -w -Ilang/cc/host -o $@ lang/cc/cc.c lang/cc/host/host.c
$(BUILD)/prog/cc: $(BUILD)/strata-cc $(BUILD)/cc/cc.lib lang/cc/cc.c
	@mkdir -p $(BUILD)/prog
	CC_LIB=$(BUILD)/cc/cc.lib $(BUILD)/strata-cc -p -h 0 -o $@ lang/cc/cc.c
	@test -f $@.u
$(BUILD)/prog/cc.u: $(BUILD)/prog/cc
	@touch $@
# on the standard disk cc.lib rides behind the compiler's units in cc.u (the
# start-up code loads the whole file; cc looks there when /bin/cc.lib is not
# a file): the disk's directory has 128 entries and its tests need the rest
$(BUILD)/cc/bin/cc.u: $(BUILD)/prog/cc.u $(BUILD)/cc/cc.lib
	@mkdir -p $(BUILD)/cc/bin
	cat $(BUILD)/prog/cc.u $(BUILD)/cc/cc.lib > $@
# sasm assembles the whole bootstrap compiler into one image; mklib.py splits
# it: the program cc0 keeps the Local Store sections, its code units go into
# cc0.lib
$(BUILD)/cc/cc-full.stx: $(CC_SRC) $(BUILD)/sasm lang/cc/tests/check-units.py
	@mkdir -p $(BUILD)/cc $(BUILD)/prog
	$(BUILD)/sasm -T 0x8000 -I lang/cc -g $(BUILD)/prog/cc0.map -o $@ lang/cc/cc.s
	python3 lang/cc/tests/check-units.py $@
$(BUILD)/prog/cc0: $(BUILD)/cc/cc0.lib
	@touch $@
$(BUILD)/cc/cc0.lib: $(BUILD)/cc/cc-full.stx $(BUILD)/cc/libc.stx lang/cc/lib/mklib.py $(CC_HDRS) $(BUILD)/cc/asm.tab
	python3 lang/cc/lib/mklib.py --cc $(BUILD)/cc/cc-full.stx $(BUILD)/prog/cc0 $@ $(CC_LIBIN)

# Every source on the disk carries a copy of the library after the program.
$(USRCS): $(BUILD)/src/%.s: os/progs/%.s os/lib/sys.s
	@mkdir -p $(BUILD)/src
	grep -v '^[[:space:]]*\.include' $< > $@
	cat os/lib/sys.s >> $@

# vi's source: its two includes (at the top: their labels come first) in place
$(BUILD)/src/vi.s: os/progs/vi.s os/lib/sys.s $(BUILD)/vi-syntax.s
	@mkdir -p $(BUILD)/src
	awk '/^[[:space:]]*\.include "\.\.\/lib\/sys\.s"/ { system("cat os/lib/sys.s"); next } \
	     /^[[:space:]]*\.include "vi-syntax\.s"/ { system("cat $(BUILD)/vi-syntax.s"); next } { print }' $< > $@

$(BUILD)/src/units.s: os/progs/units.s examples/lib/print.s
	@mkdir -p $(BUILD)/src
	grep -v '^[[:space:]]*\.include' $< > $@
	cat examples/lib/print.s >> $@

$(BUILD)/src/%.s: examples/%.s examples/lib/print.s
	@mkdir -p $(BUILD)/src
	grep -v '^[[:space:]]*\.include' $< > $@
	cat examples/lib/print.s >> $@

$(BUILD)/src/as.s: os/progs/as.s
	@mkdir -p $(BUILD)/src
	cp $< $@

# Strata Forth as a StrataOS program (its rules are in the Forth section below):
# `forth`, the files it loads on demand (tools.fs, see.fs), core.fs to read, the demos
FORTH_DISK := $(BUILD)/prog/forth lang/forth/core.fs lang/forth/tools.fs lang/forth/see.fs \
              $(wildcard lang/forth/demos/*.fs)
# the network words (loaded on demand, like tools.fs) and the web server built on them
FORTH_DISK += lang/forth/net.fs lang/forth/udp.fs lang/forth/httpd.fs lang/forth/httpd-ps.fs
# the editor, with its keyword tables
FORTH_DISK += lang/forth/vi.fs lang/forth/vi-text.fs lang/forth/vi-edit.fs $(BUILD)/forth-os/vi-syntax.fs
# the ports of os/progs, with their library and loader: one file
FORTH_DISK += $(BUILD)/forth-os/progs.pk

# the C compiler, its library file and two C programs to try it on
CC_DISK := $(BUILD)/prog/cc $(BUILD)/cc/bin/cc.u lang/cc/examples/hi.c
DISK_FILES := $(OS_FILES) $(SPROGS) $(UPROGS) $(NPROGS) $(BUILD)/prog/untag $(BUILD)/prog/retag $(WSPROGS) $(PROGS) $(BUILD)/prog/as $(CC_DISK) \
              $(BUILD)/prog/units $(BUILD)/prog/vi $(SRCS) $(USRCS) $(BUILD)/src/vi.s $(FORTH_DISK)

# The same files with their tags (mkdisk -t TAGS applies to the files after it).
# The file system has no directories: `ls /bin` lists the files tagged bin,
# `ls /src/demo` those tagged both src and demo.
DISK_ARGS := -t doc $(filter-out %/rc %/resolv,$(OS_FILES)) -t etc $(filter %/rc %/resolv,$(OS_FILES)) \
             -t sys $(SPROGS) -t bin $(UPROGS) $(BUILD)/prog/untag $(BUILD)/prog/retag -t bin,net $(NPROGS) -t bin,ws $(WSPROGS) \
             -t demo $(PROGS) -t bin $(BUILD)/prog/as $(BUILD)/prog/units $(BUILD)/prog/vi \
             -t src,demo $(EXSRCS) -t src $(BUILD)/src/as.s $(BUILD)/src/units.s $(USRCS) $(BUILD)/src/vi.s \
             -t bin,forth $(BUILD)/prog/forth -t forth lang/forth/core.fs lang/forth/tools.fs lang/forth/see.fs \
             lang/forth/vi.fs lang/forth/vi-text.fs lang/forth/vi-edit.fs $(BUILD)/forth-os/vi-syntax.fs \
             $(BUILD)/forth-os/progs.pk \
             -t forth,demo $(wildcard lang/forth/demos/*.fs) \
             -t forth,net lang/forth/net.fs lang/forth/udp.fs lang/forth/httpd-ps.fs -t forth,net,demo lang/forth/httpd.fs
# the web site httpd serves (index.html at /, the stylesheet of every page)
WWW_FILES  := $(wildcard os/www/*)
DISK_FILES += $(WWW_FILES)
DISK_ARGS  += -t www $(WWW_FILES)
# The directory has 128 entries and the tests that create many files (HTTP,
# isolation, Forth) fill it: their disks are built without the C compiler.
DISK_ARGS_NOCC := $(DISK_ARGS)
DISK_ARGS  += -t bin $(BUILD)/prog/cc $(BUILD)/cc/bin/cc.u -t src lang/cc/examples/hi.c

$(BUILD)/disk.img: $(BUILD)/kernel.stx $(BUILD)/mkdisk $(DISK_FILES) $(GUESTIMG) $(FORTH_GUEST)
	$(BUILD)/mkdisk -o $@ -k $(BUILD)/kernel.stx $(DISK_ARGS) -t guest $(GUESTIMG) -t guest,forth $(FORTH_GUEST)

os: $(BUILD)/bootrom.stx $(BUILD)/disk.img

# the same disk with an rc that starts the window server (make boot-ws)
DISK_WS_ARGS := $(subst os/files/rc,os/files-ws/rc,$(DISK_ARGS))

$(BUILD)/disk-ws.img: $(BUILD)/kernel.stx $(BUILD)/mkdisk $(DISK_FILES) os/files-ws/rc
	$(BUILD)/mkdisk -o $@ -k $(BUILD)/kernel.stx $(DISK_WS_ARGS)

# the emulator boots StrataOS with 12 cores; the RTL with NCORES
BOOT_EMU := $(BUILD)/strata-emu -c 12
# the network of the interactive boots: the real one through the emulator's
# user-mode NAT (common/netnat.h), with the guest's web servers reachable
# from the host: http://localhost:8080/ (httpd, port 80) and :8000 (Forth's
# httpd.fs). A busy host port is reported and skipped. `make boot
# BOOT_NET="-N peer"` for the offline test peer instead.
BOOT_NET ?= -N nat,fwd=8080:80,fwd=8000:8000

# the disk make boot starts: the standard one and the C compiler's bootstrap:
# cc0 (the compiler in assembly), cc.c, and cc.lib as a file for the
# compilers made from it:   cc0 -p -h 0 -o cc1 /src/cc.c   (lang/cc/DESIGN.md).
# The tests keep the standard disk: some of them need its free directory entries.
$(BUILD)/disk-boot.img: $(BUILD)/disk.img $(BUILD)/prog/cc0 $(BUILD)/cc/cc0.lib $(BUILD)/cc/cc.lib lang/cc/cc.c
	$(BUILD)/mkdisk -o $@ -k $(BUILD)/kernel.stx $(DISK_ARGS) -t bin $(BUILD)/prog/cc0 $(BUILD)/cc/cc0.lib $(BUILD)/cc/cc.lib -t src lang/cc/cc.c

boot: $(BUILD)/strata-emu os $(BUILD)/disk-boot.img
	@cp $(BUILD)/disk-boot.img $(BUILD)/disk-run.img
	@$(BOOT_EMU) $(BOOT_NET) -d $(BUILD)/disk-run.img $(BUILD)/bootrom.stx

boot-net: boot

boot-ws: $(BUILD)/strata-emu $(BUILD)/bootrom.stx $(BUILD)/disk-ws.img
	@cp $(BUILD)/disk-ws.img $(BUILD)/disk-run.img
	@$(BOOT_EMU) $(BOOT_NET) -d $(BUILD)/disk-run.img $(BUILD)/bootrom.stx

boot-demo: $(BUILD)/strata-emu os
	@cp $(BUILD)/disk.img $(BUILD)/disk-run.img
	@$(BOOT_EMU) -g none -d $(BUILD)/disk-run.img -i os/demo.txt $(BUILD)/bootrom.stx

boot-rtl: $(BUILD)/strata-rtl os
	@cp $(BUILD)/disk.img $(BUILD)/disk-run.img
	@$(BUILD)/strata-rtl $(BOOT_NET) -d $(BUILD)/disk-run.img $(BUILD)/bootrom.stx

boot-rtl-demo: $(BUILD)/strata-rtl os
	@cp $(BUILD)/disk.img $(BUILD)/disk-run.img
	@$(BUILD)/strata-rtl -g none -d $(BUILD)/disk-run.img -i os/demo.txt $(BUILD)/bootrom.stx

# ---- FPGA block-RAM images (Arty A7: 2 cores, 128 KiB disk) -------------------
FPGA := fpga/build/images

$(BUILD)/mkhex: tools/mkhex.c common/stx.h common/platform.h asm/isa.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ tools/mkhex.c

fpga-images: $(BUILD)/mkhex $(BUILD)/bootrom.stx $(BUILD)/kernel.stx $(BUILD)/mkdisk $(BUILD)/prog/hello $(BUILD)/prog/mandel
	@mkdir -p $(FPGA)
	$(BUILD)/mkdisk -b 256 -o $(FPGA)/disk.img -k $(BUILD)/kernel.stx os/files/motd os/files/rc $(BUILD)/prog/hello $(BUILD)/prog/mandel
	$(BUILD)/mkhex ils $(BUILD)/bootrom.stx $(FPGA)/bootrom_ils.hex
	$(BUILD)/mkhex dls $(BUILD)/bootrom.stx $(FPGA)/bootrom_dls.hex
	$(BUILD)/mkhex disk $(FPGA)/disk.img 16384 $(FPGA)/disk.hex
	$(BUILD)/mkhex plat 2 256 $(FPGA)/plat.hex 16 65536

# ---- Strata Forth (lang/forth): make forth, forth-rtl, test-forth ------------
.PHONY: forth forth-rtl test-forth
FORTH_EMBED = awk '{gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); printf "        .ascii \"%s\\n\"\n", $$0}'
FORTH_SRC := lang/forth/forth.s $(wildcard lang/forth/bare/*.s)
FORTH_FS  := lang/forth/core.fs lang/forth/tools.fs lang/forth/see.fs lang/forth/bare/start.fs
FORTH_OS_SRC := lang/forth/forth.s $(wildcard lang/forth/os/*.s)
FORTH_OS_FS  := lang/forth/core.fs lang/forth/os/os.fs

# the Forth source is embedded in the image's far section as .ascii lines:
# bare metal gets everything; the StrataOS program loads the tools from disk
$(BUILD)/forth/corefs.s: $(FORTH_FS)
	@mkdir -p $(BUILD)/forth
	$(FORTH_EMBED) $(FORTH_FS) > $@

$(BUILD)/forth.stx: $(FORTH_SRC) $(BUILD)/forth/corefs.s $(BUILD)/sasm
	$(BUILD)/sasm -I lang/forth/bare -I $(BUILD)/forth -g $(BUILD)/forth.map -o $@ lang/forth/forth.s

# the StrataOS program (lang/forth/os/: the platform layer on messages)
$(BUILD)/forth-os/corefs.s: $(FORTH_OS_FS)
	@mkdir -p $(BUILD)/forth-os
	$(FORTH_EMBED) $(FORTH_OS_FS) > $@

$(BUILD)/prog/forth: $(FORTH_OS_SRC) $(BUILD)/forth-os/corefs.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/prog
	$(BUILD)/sasm -T 0x8000 -I lang/forth/os -I $(BUILD)/forth-os -g $@.map -o $@ lang/forth/forth.s

# the C compiler's tests (lang/cc/tests/README.md):
#   test-cc       the whole ladder of C test programs, compiled and run inside StrataOS
#   test-cc-fast  a few tests of every rung, and the two example programs (part of make test)
#   test-cc-boot  the bootstrap: cc0 compiles cc.c, which reproduces itself (part of make test)
#   test-cc0      the whole ladder with the bootstrap compiler
#   test-cc-host  the whole ladder compiled by build/strata-cc, only run inside StrataOS
CC_TEST_DEPS := $(BUILD)/strata-emu $(BUILD)/mkdisk $(BUILD)/bootrom.stx $(BUILD)/kernel.stx $(SPROGS) $(BUILD)/prog/sh $(BUILD)/prog/rm \
                $(BUILD)/prog/cc $(BUILD)/prog/cc.u $(BUILD)/cc/cc.lib
CC_BOOT := -t bin $(BUILD)/prog/cc0 $(BUILD)/cc/cc0.lib -t src lang/cc/cc.c lang/cc/tests/cmp.c
.PHONY: test-cc test-cc-fast test-cc-boot test-cc0 test-cc-host
test-cc: $(CC_TEST_DEPS)
	BUILD=$(BUILD) lang/cc/tests/run.sh
test-cc0: $(CC_TEST_DEPS) $(BUILD)/prog/cc0
	BUILD=$(BUILD) CC_NAME=cc0 lang/cc/tests/run.sh
test-cc-host: $(CC_TEST_DEPS) $(BUILD)/strata-cc
	BUILD=$(BUILD) CC_HOST=$(BUILD)/strata-cc lang/cc/tests/run.sh
# the disk of tools/test-cc.sh: the standard one plus the other examples
$(BUILD)/cc-test/disk.img: $(BUILD)/kernel.stx $(BUILD)/mkdisk $(DISK_FILES) lang/cc/examples/calc.c lang/cc/examples/asm.c
	@mkdir -p $(BUILD)/cc-test
	$(BUILD)/mkdisk -o $@ -k $(BUILD)/kernel.stx $(DISK_ARGS) -t src lang/cc/examples/calc.c lang/cc/examples/asm.c
# the disk of tools/test-cc-boot.sh: the system, both compilers, cc.c
$(BUILD)/cc-boot/disk.img: $(CC_TEST_DEPS) $(BUILD)/prog/cc0 lang/cc/cc.c lang/cc/tests/cmp.c
	@mkdir -p $(BUILD)/cc-boot
	$(BUILD)/mkdisk -o $@ -k $(BUILD)/kernel.stx -t sys $(SPROGS) -t bin $(BUILD)/prog/sh $(BUILD)/prog/rm \
	    $(BUILD)/prog/cc $(BUILD)/prog/cc.u $(BUILD)/cc/cc.lib $(CC_BOOT)
test-cc-fast: $(CC_TEST_DEPS) $(BUILD)/cc-test/disk.img
	BUILD=$(BUILD) lang/cc/tests/run.sh -f lang/cc/tests/ladder/FAST.txt
	BUILD=$(BUILD) ./tools/test-cc.sh $(BUILD)/bootrom.stx $(BUILD)/cc-test/disk.img
test-cc-boot: $(CC_TEST_DEPS) $(BUILD)/cc-boot/disk.img
	BUILD=$(BUILD) ./tools/test-cc-boot.sh $(BUILD)/bootrom.stx $(BUILD)/cc-boot/disk.img
test: test-cc-boot
test: test-cc-fast

# the disk of tools/test-http.sh: the standard one plus two requests as a
# browser sends them (CR LF; a 3 KB Cookie header), which the console cannot type
$(BUILD)/http-test/disk.img: $(BUILD)/kernel.stx $(BUILD)/mkdisk $(DISK_FILES)
	@mkdir -p $(BUILD)/http-test
	printf 'GET /www/style.css HTTP/1.1\r\nHost: localhost:8080\r\nUser-Agent: Mozilla/5.0 (test)\r\nAccept: text/css,*/*;q=0.1\r\nAccept-Language: en\r\nConnection: keep-alive\r\n\r\n' >$(BUILD)/http-test/browser.req
	{ printf 'GET /doc/about?x=1 HTTP/1.1\r\nHost: localhost:8080\r\nCookie: '; for i in $$(seq 1 80); do printf 'c%s=0123456789abcdef0123456789abcdef; ' $$i; done; \
	  printf '\r\nAccept: */*\r\n\r\n'; } >$(BUILD)/http-test/cookie.req
	$(BUILD)/mkdisk -o $@ -k $(BUILD)/kernel.stx $(DISK_ARGS_NOCC) -t test $(BUILD)/http-test/browser.req $(BUILD)/http-test/cookie.req
test: $(BUILD)/http-test/disk.img

# the disk of tools/test-isolate.sh: the standard one plus dlsgap (tools/dlsgap.s),
# which checks that no process sees what another left in its core's D-LS
$(BUILD)/isol-test/dlsgap: tools/dlsgap.s os/lib/sys.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/isol-test
	$(BUILD)/sasm -T 0x8000 -o $@ $<
$(BUILD)/isol-test/disk.img: $(BUILD)/kernel.stx $(BUILD)/mkdisk $(DISK_FILES) $(BUILD)/isol-test/dlsgap
	$(BUILD)/mkdisk -o $@ -k $(BUILD)/kernel.stx $(DISK_ARGS_NOCC) -t bin,test $(BUILD)/isol-test/dlsgap
test: $(BUILD)/isol-test/disk.img

# the disk of `make test-forth`: the standard one plus the test files
$(BUILD)/forth-test/disk.img: $(BUILD)/kernel.stx $(BUILD)/mkdisk $(DISK_FILES) $(wildcard lang/forth/tests/*.fs) \
                              $(wildcard lang/forth/tests/http/*)
	@mkdir -p $(BUILD)/forth-test
	$(BUILD)/mkdisk -o $@ -k $(BUILD)/kernel.stx $(DISK_ARGS_NOCC) -t forth,test $(wildcard lang/forth/tests/*.fs) \
	  -t httptest $(wildcard lang/forth/tests/http/*)

forth: $(BUILD)/strata-emu $(BUILD)/forth.stx
	@$(EMU) $(BUILD)/forth.stx

forth-rtl: $(BUILD)/strata-rtl $(BUILD)/forth.stx
	@$(BUILD)/strata-rtl $(BUILD)/forth.stx

# the demos: `make forth-demo-NAME` (NAME = tiers, multicore, gfx) runs
# lang/forth/demos/NAME.fs on the emulator; gfx keeps its window open (-H)
# until you close it. `make forth-demos` runs all three. The screen is
# FORTH_RES (default 640x400: Forth renders the 1280x800 default in ~20 s).
FORTH_RES ?= 640x400
FORTH_DEMOS := $(basename $(notdir $(wildcard lang/forth/demos/*.fs)))
.PHONY: forth-demos
forth-demo-%: $(BUILD)/strata-emu $(BUILD)/forth.stx lang/forth/demos/%.fs
	@$(EMU) -H -r $(FORTH_RES) -i lang/forth/demos/$*.fs $(BUILD)/forth.stx

forth-demos: $(BUILD)/strata-emu $(BUILD)/forth.stx
	@for d in $(FORTH_DEMOS); do \
	  printf '\n==== forth demo: %s ====\n' $$d; \
	  $(EMU) -H -r $(FORTH_RES) -i lang/forth/demos/$$d.fs $(BUILD)/forth.stx; \
	done

# test-forth: tests/test.fs bare metal on the emulator and the RTL, then as a
# StrataOS program (`forth -n 6`), and a preemption test (see tests/run-os.sh)
test-forth: $(BUILD)/strata-emu $(BUILD)/strata-rtl $(BUILD)/forth.stx $(BUILD)/bootrom.stx $(BUILD)/forth-test/disk.img
	BUILD=$(BUILD) NCORES=$(NCORES) lang/forth/tests/run.sh
	BUILD=$(BUILD) lang/forth/tests/run-os.sh

# ---- the conformance suite (conformance/): make conformance, make fuzz --------
# conformance  every conformance/tests/*.s on the interpreter, the JIT and the
#              RTL: self-checks and identical signatures (conformance/run.sh)
# fuzz         random programs on all three, compared (SEEDS=N, FIRST=seed)
.PHONY: conformance fuzz
SEEDS ?= 50
FIRST ?= 1
conformance: all
	BUILD=$(BUILD) NCORES=$(NCORES) ./conformance/run.sh

fuzz: all
	BUILD=$(BUILD) NCORES=$(NCORES) python3 conformance/fuzz/fuzz.py -n $(SEEDS) -s $(FIRST)

# ---- the JIT (emu/jit/): make test-jit, make bench ----------------------------
.PHONY: test-jit bench
test-jit: $(BUILD)/strata-emu examples $(BUILD)/forth.stx
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-jit.sh

bench: $(BUILD)/strata-emu examples $(BUILD)/forth.stx
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/bench-jit.sh

# ---- the emulator in the browser (web/web.c, site/play/) ----------------------
# web-assets  the images the play page runs (sasm and cc only, no Verilator)
# wasm        build/web/: strata-emu.js + .wasm (Emscripten; the JIT is
#             emu/jit/jit_wasm.c), images/ and the Forth demos/
# web-code    build/web-code/: the sources and manifest.json of the source
#             browser (site/code/), by tools/web-code.py
# web-docs    build/web-docs/: the manual on the web, isa/ (every instruction)
#             and arch/ (the architecture outline), by doc/manual/gen/genweb.py
#             from the manual's sources (the same data as make manual); and
#             forth/ (every Forth word with its source, and a playground that
#             runs the play page's worker), by doc/manual/gen/genforth.py
#             from lang/forth/
# web-site    build/web-site/: site/ with build/web/ under play/ and
#             build/web-code/ under code/; preview it with
#             python3 -m http.server --directory build/web-site
# test-wasm   the WebAssembly build under node against the native interpreter:
#             interpreted and with the WebAssembly JIT (tools/test-wasm.sh)
EMCC ?= emcc
WEB := $(BUILD)/web
WEB_IMAGES := $(BUILD)/bootrom.stx $(BUILD)/disk.img $(BUILD)/disk-ws.img $(BUILD)/forth.stx \
              $(BUILD)/examples/gfx.stx $(BUILD)/examples/hello.stx $(BUILD)/examples/mandel.stx \
              $(BUILD)/ws/wsdemo.stx
.PHONY: web-assets wasm web-code web-site test-wasm
web-assets: $(WEB_IMAGES)

test-wasm: $(WEB)/strata-emu.js $(BUILD)/strata-emu $(BUILD)/sasm examples $(BUILD)/forth.stx $(BUILD)/ws/wsdemo.stx
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-wasm.sh

# one build for the page's worker and for node (tools/wasm-run.js, the tests)
# (emu/jit/jit_wasm.c is the JIT: it generates WebAssembly at run time and
# installs it in the module's function table, hence ALLOW_TABLE_GROWTH)
$(WEB)/strata-emu.js: web/web.c emu/emu.c $(DBG_ENGINE) emu/jit/jit_wasm.c emu/jit/jit.h emu/jit/jit_be.h asm/isa.h common/stx.h common/platform.h common/display.h common/net.h common/netnat.h
	@mkdir -p $(WEB)
	$(EMCC) -std=gnu11 -O3 -Wall -DNO_SDL -o $@ web/web.c emu/jit/jit_wasm.c \
	  -sMODULARIZE=1 -sEXPORT_NAME=createStrata -sENVIRONMENT=worker,node -sINVOKE_RUN=0 -sEXIT_RUNTIME=0 \
	  -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=128MB -sALLOW_TABLE_GROWTH=1 \
	  -sEXPORTED_FUNCTIONS=_main,_web_run,_web_paint,_web_input,_web_break,_web_pointer,_web_pointer_used,_web_stop,_web_finish,_web_stat,_jit_wasm_stat,_jit_wasm_set_hot,_jit_wasm_set_budget,_web_dbg,_web_dbg_run,_web_dbg_events,_web_dbg_repaint,_malloc,_free \
	  -sEXPORTED_RUNTIME_METHODS=callMain,FS,HEAPU8,wasmMemory,wasmTable,UTF8ToString,stringToNewUTF8

# wasm-rtl: the RTL simulator for the browser: build/web/strata-rtl.js + .wasm.
# Verilator turns the SystemVerilog into C++ (no host compile), em++ builds
# it with web/web_rtl.cpp, which drives sim/main.cpp's harness through the
# same calls as the emulator's module, so the play page's worker can run
# either ("Machine: RTL simulator"). WEB_RTL_CORES cores (the RTL's NCORES is
# fixed when it is built). Needs verilator and em++; the site works without
# it (the page hides the choice when strata-rtl.wasm is not there).
EMXX ?= em++
WEB_RTL_CORES ?= 8
VERILATOR_ROOT ?= $(shell verilator --getenv VERILATOR_ROOT 2>/dev/null)
.PHONY: wasm-rtl test-wasm-rtl
wasm-rtl: $(WEB)/strata-rtl.js
# test-wasm-rtl: that build under node against the native simulator
# (tools/test-wasm-rtl.sh): same output, same cycle counts, same frame
test-wasm-rtl: $(WEB)/strata-rtl.js $(BUILD)/strata-rtl examples
	BUILD=$(BUILD) ./tools/test-wasm-rtl.sh
$(WEB)/strata-rtl.js: $(RTL) sim/main.cpp web/web_rtl.cpp web/web_rtl_stubs.c common/stx.h common/platform.h common/display.h common/net.h common/netnat.h asm/isa.h
	@mkdir -p $(WEB) $(BUILD)/web-rtl
	verilator --cc -O3 --x-assign fast --x-initial fast \
	  -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  -DSIMULATION -GNCORES=$(WEB_RTL_CORES) -GNXMAP=$(NXMAP) -GDLS_KIB=$(DLS_KIB) -GILS_KIB=$(ILS_KIB) --top-module strata_top \
	  -Mdir $(BUILD)/web-rtl/obj $(RTL)
	$(EMCC) -O2 -c -o $(BUILD)/web-rtl/stubs.o web/web_rtl_stubs.c
	$(EMXX) -std=c++17 -O2 -include cstdint -DNO_SDL -DVL_IGNORE_UNKNOWN_ARCH -DNCORES=$(WEB_RTL_CORES) -DNXMAP=$(NXMAP) -DDLS_KIB=$(DLS_KIB) -DILS_KIB=$(ILS_KIB) \
	  -I$(BUILD)/web-rtl/obj -I$(VERILATOR_ROOT)/include -I$(VERILATOR_ROOT)/include/vltstd \
	  -o $@ web/web_rtl.cpp $(BUILD)/web-rtl/stubs.o $(BUILD)/web-rtl/obj/Vstrata_top*.cpp \
	  $(VERILATOR_ROOT)/include/verilated.cpp $(VERILATOR_ROOT)/include/verilated_dpi.cpp $(VERILATOR_ROOT)/include/verilated_threads.cpp \
	  -sMODULARIZE=1 -sEXPORT_NAME=createStrataRtl -sENVIRONMENT=worker,node -sINVOKE_RUN=0 -sEXIT_RUNTIME=0 \
	  -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=256MB -sSTACK_SIZE=1MB \
	  -sEXPORTED_FUNCTIONS=_main,_web_run,_web_paint,_web_input,_web_break,_web_pointer,_web_pointer_used,_web_stop,_web_finish,_web_stat,_malloc,_free \
	  -sEXPORTED_RUNTIME_METHODS=callMain,FS,HEAPU8

# the web debugger's examples (site/debug/): images, their maps (sasm -g) and
# the sources the maps name, under build/web/debug/ (the site's play/debug/)
DEBUG_EXAMPLES := hello pipeline clock stream_sum parsum overlay swcache race
DEBUG_ASSETS := $(foreach e,$(DEBUG_EXAMPLES),$(BUILD)/examples/$(e).stx $(BUILD)/examples/$(e).map)

# (a map is written with its image; this rebuilds an image made before maps were)
$(BUILD)/examples/%.map: examples/%.s $(BUILD)/sasm $(wildcard examples/lib/*.s)
	@mkdir -p $(BUILD)/examples
	$(BUILD)/sasm -g $@ -o $(@:.map=.stx) $<

wasm: $(WEB)/strata-emu.js web-assets $(DEBUG_ASSETS)
	@mkdir -p $(WEB)/images $(WEB)/demos $(WEB)/debug/src/examples/lib
	cp $(WEB_IMAGES) $(WEB)/images/
	cp lang/forth/demos/*.fs $(WEB)/demos/
	ls lang/forth/demos | sed -n 's/\.fs$$//p' > $(WEB)/demos/index.txt
	cp $(DEBUG_ASSETS) $(WEB)/debug/
	cp $(patsubst %,examples/%.s,$(DEBUG_EXAMPLES)) $(WEB)/debug/src/examples/
	cp examples/lib/*.s $(WEB)/debug/src/examples/lib/
	echo $(DEBUG_EXAMPLES) | tr ' ' '\n' > $(WEB)/debug/index.txt
	@mkdir -p $(WEB)/debug/os/prog
	cp $(BUILD)/bootrom.map $(BUILD)/kernel.map $(WEB)/debug/os/
	cp $(BUILD)/prog/*.map $(WEB)/debug/os/prog/
	ls $(BUILD)/prog | sed -n 's/\.map$$//p' > $(WEB)/debug/os/prog.txt

web-code:
	rm -rf $(BUILD)/web-code
	mkdir -p $(BUILD)/web-code
	python3 tools/web-code.py $(BUILD)/web-code

.PHONY: web-docs
web-docs:
	rm -rf $(BUILD)/web-docs
	mkdir -p $(BUILD)/web-docs
	python3 doc/manual/gen/genweb.py $(BUILD)/web-docs

web-site: wasm web-code web-docs
	rm -rf $(BUILD)/web-site
	mkdir -p $(BUILD)/web-site
	cp -r site/. $(BUILD)/web-site/
	cp -r $(WEB)/. $(BUILD)/web-site/play/
	cp -r $(BUILD)/web-code/. $(BUILD)/web-site/code/
	cp -r $(BUILD)/web-docs/. $(BUILD)/web-site/
	tools/web-stamp.sh $(BUILD)/web-site $$(git rev-parse --short HEAD 2>/dev/null || date +%s)

# ---- the window server's renderers (os/ws/, os/lib/gfx.s): bare-metal demo -
# ws-demo   the demo in a window: splash, four tiles, palette (Alt+Space),
#           Alt+1..4 focus, Alt+Enter terminal, Alt+Q close, Alt+Shift+Q quit
# ws-shots  build/ws-shots/*.png: frames NAME:N of the scripted run
# ws-perf   instruction counts: full frame, terminal line, lattice pulse
# The demo is one file with two knobs (SHOT, PERF) set by a wrapper here.
.PHONY: ws-demo ws-shots ws-perf ws-check
WS_SRC   := $(wildcard os/ws/*.s) os/lib/gfx.s os/lib/font/font.s examples/lib/print.s
WS_SHOTS := splash:50 slide:249 desktop:450 focus:470 palette:525
WS_ASM    = printf 'SHOT = %s\nPERF = %s\n        .include "%s"\n' $(1) $(2) "$(CURDIR)/os/ws/wsdemo.s" > $(3).s && \
            $(BUILD)/sasm -I os/ws -I os/lib -o $(3).stx $(3).s

$(BUILD)/ws/wsdemo.stx: $(WS_SRC) $(BUILD)/sasm
	@mkdir -p $(BUILD)/ws
	@$(call WS_ASM,0,0,$(BUILD)/ws/wsdemo)

ws-demo: $(BUILD)/strata-emu $(BUILD)/ws/wsdemo.stx
	@$(BUILD)/strata-emu -c 1 -H $(BUILD)/ws/wsdemo.stx

ws-shots: $(BUILD)/strata-emu $(BUILD)/sasm $(WS_SRC)
	@mkdir -p $(BUILD)/ws-shots
	@for s in $(WS_SHOTS); do n=$${s%%:*}; f=$${s##*:}; \
	  $(call WS_ASM,$$f,0,$(BUILD)/ws-shots/$$n) && \
	  $(BUILD)/strata-emu -c 1 -g none -F $(BUILD)/ws-shots/$$n.ppm $(BUILD)/ws-shots/$$n.stx 2>/dev/null && \
	  { sips -s format png $(BUILD)/ws-shots/$$n.ppm --out $(BUILD)/ws-shots/$$n.png >/dev/null 2>&1 || true; } && \
	  echo "build/ws-shots/$$n (frame $$f)"; done

# ws-check: at each shot frame, the damage-driven picture equals a full redraw
ws-check: $(BUILD)/strata-emu $(BUILD)/sasm $(WS_SRC)
	@mkdir -p $(BUILD)/ws
	@for s in $(WS_SHOTS); do f=$${s##*:}; \
	  $(call WS_ASM,$$f,0,$(BUILD)/ws/chk-a) && $(call WS_ASM,$$f,2,$(BUILD)/ws/chk-b) && \
	  $(BUILD)/strata-emu -c 1 -g none -F $(BUILD)/ws/chk-a.ppm $(BUILD)/ws/chk-a.stx 2>/dev/null && \
	  $(BUILD)/strata-emu -c 1 -g none -F $(BUILD)/ws/chk-b.ppm $(BUILD)/ws/chk-b.stx 2>/dev/null && \
	  if cmp -s $(BUILD)/ws/chk-a.ppm $(BUILD)/ws/chk-b.ppm; then echo "frame $$f: ok"; \
	  else echo "frame $$f: DIFFERS"; exit 1; fi; done

ws-perf: $(BUILD)/strata-emu $(BUILD)/sasm $(WS_SRC)
	@mkdir -p $(BUILD)/ws
	@$(call WS_ASM,450,1,$(BUILD)/ws/perf)
	@$(BUILD)/strata-emu -c 1 -g none $(BUILD)/ws/perf.stx 2>/dev/null

# ---- the Architecture Reference Manual (needs tectonic: brew install tectonic)
manual:
	cd doc/manual && python3 gen/geninsns.py && tectonic main.tex
	cp doc/manual/main.pdf doc/Strata-Architecture-Reference-Manual.pdf

clean:
	rm -rf $(BUILD)
