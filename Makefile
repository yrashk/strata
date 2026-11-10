# Strata prototype build.
#
#   make            assembler, emulator, RTL simulator
#   make examples   assemble every example
#   make test       run every example on the emulator and the RTL and compare
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

CC      ?= cc
CFLAGS  ?= -std=gnu11 -O2 -Wall -Wextra
NCORES  ?= 8

# SDL2 for the framebuffer window, when pkg-config finds it (else -DNO_SDL:
# no window, PRESENT only records frames for -F)
SDL_CFLAGS := $(shell pkg-config --cflags sdl2 2>/dev/null)
SDL_LIBS   := $(shell pkg-config --libs sdl2 2>/dev/null)
ifeq ($(SDL_LIBS),)
SDL_CFLAGS := -DNO_SDL
endif

BUILD   := build
RTL     := rtl/strata_pkg.sv rtl/strata_decode.sv rtl/strata_alu.sv rtl/strata_div.sv \
           rtl/strata_ram.sv rtl/strata_uart.sv rtl/strata_tu.sv rtl/strata_bus.sv \
           rtl/strata_mem.sv rtl/strata_dev.sv rtl/strata_core.sv rtl/strata_top.sv
EXAMPLES := $(wildcard examples/*.s)
IMAGES  := $(patsubst examples/%.s,$(BUILD)/examples/%.stx,$(EXAMPLES))
PROGS   := $(patsubst examples/%.s,$(BUILD)/prog/%,$(EXAMPLES))
EMU     := $(BUILD)/strata-emu -c $(NCORES)

.PHONY: all examples test clean lint run run-emu boot boot-ws boot-demo boot-rtl boot-rtl-demo os fpga-images manual

all: $(BUILD)/sasm $(BUILD)/strata-emu $(BUILD)/strata-rtl

$(BUILD)/sasm: asm/sasm.c asm/isa.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ asm/sasm.c

# the JIT (emu/jit/): each backend compiles to nothing on other hosts
JIT_SRC := emu/jit/jit.c emu/jit/jit_arm64.c emu/jit/jit_x86_64.c

$(BUILD)/strata-emu: emu/emu.c $(JIT_SRC) emu/jit/jit.h emu/jit/jit_be.h asm/isa.h common/stx.h common/platform.h common/display.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(SDL_CFLAGS) -o $@ emu/emu.c $(JIT_SRC) $(SDL_LIBS)

$(BUILD)/strata-rtl: $(RTL) sim/main.cpp common/stx.h common/platform.h common/display.h asm/isa.h
	@mkdir -p $(BUILD)
	verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial fast \
	  -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  -DSIMULATION -GNCORES=$(NCORES) --top-module strata_top \
	  -Mdir $(BUILD)/obj_dir -o strata-rtl \
	  -CFLAGS "-O2 -std=c++17 -DNCORES=$(NCORES) $(SDL_CFLAGS)" -LDFLAGS "$(SDL_LIBS)" $(RTL) sim/main.cpp
	rm -f $@ && cp $(BUILD)/obj_dir/strata-rtl $@

lint:
	verilator --lint-only -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -DSIMULATION --top-module strata_top $(RTL)
	verilator --lint-only -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM --top-module strata_top $(RTL)

$(BUILD)/examples/%.stx: examples/%.s $(BUILD)/sasm $(wildcard examples/lib/*.s)
	@mkdir -p $(BUILD)/examples
	$(BUILD)/sasm -o $@ $<

examples: $(IMAGES)

test: all examples os
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/compare.sh $(IMAGES)
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/compare-boot.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img os/demo.txt
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-break.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-sh.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img
	BUILD=$(BUILD) ./tools/test-ws.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-preempt.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-boot-jit.sh $(BUILD)/bootrom.stx $(BUILD)/disk.img os/demo.txt
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-fb.sh $(BUILD)/examples/gfx.stx
	BUILD=$(BUILD) NCORES=$(NCORES) ./tools/test-jit.sh
	BUILD=$(BUILD) NCORES=$(NCORES) ./conformance/run.sh
	@if command -v node >/dev/null 2>&1 && command -v $(EMCC) >/dev/null 2>&1; then $(MAKE) test-wasm; \
	else echo "test-wasm: skipped (needs node and $(EMCC))"; fi

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

# ---- firmware, OS and disk image -------------------------------------------
OS_FILES := $(wildcard os/files/*)

$(BUILD)/mkdisk: tools/mkdisk.c common/stx.h asm/isa.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ tools/mkdisk.c

$(BUILD)/bootrom.stx: firmware/bootrom.s firmware/fw.s $(BUILD)/sasm
	$(BUILD)/sasm -o $@ firmware/bootrom.s

$(BUILD)/kernel.stx: os/kernel.s $(wildcard os/kunits/*.s) firmware/fw.s $(BUILD)/sasm
	$(BUILD)/sasm -o $@ os/kernel.s

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
SERVERS := proc dev fs tty pipe
UTILS   := sh ls cat rm df ps free uptime devs hexdump cores sched seq grep wc upper spin tag tags
SPROGS  := $(patsubst %,$(BUILD)/prog/%,$(SERVERS))
UPROGS  := $(patsubst %,$(BUILD)/prog/%,$(UTILS))
USRCS   := $(patsubst %,$(BUILD)/src/%.s,$(UTILS))
EXSRCS  := $(patsubst %,$(BUILD)/src/%.s,$(OS_EXAMPLES))
SRCS    := $(EXSRCS) $(BUILD)/src/as.s $(BUILD)/src/units.s

$(BUILD)/prog/%: examples/%.s $(BUILD)/sasm $(wildcard examples/lib/*.s)
	@mkdir -p $(BUILD)/prog
	$(BUILD)/sasm -T 0x8000 -o $@ $<

$(SPROGS): $(BUILD)/prog/%: os/servers/%.s os/lib/sys.s os/lib/srv.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/prog
	$(BUILD)/sasm -T 0x8000 -o $@ $<

$(UPROGS): $(BUILD)/prog/%: os/progs/%.s os/lib/sys.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/prog
	$(BUILD)/sasm -T 0x8000 -o $@ $<

# untag is tag under another name (it looks at the name it was started by)
$(BUILD)/prog/untag: $(BUILD)/prog/tag
	cp $< $@

# the window server and its clients (os/ws/, os/lib/gfx.s, os/lib/wsclient.s)
WSPROGS := $(patsubst %,$(BUILD)/prog/%,ws term wmandel wclock)
$(WSPROGS): $(BUILD)/prog/%: os/progs/%.s $(wildcard os/ws/*.s) os/lib/gfx.s os/lib/font/font.s os/lib/wsclient.s os/lib/sys.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/prog
	$(BUILD)/sasm -T 0x8000 -I os/ws -I os/lib -o $@ $<

$(BUILD)/prog/units: os/progs/units.s examples/lib/print.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/prog
	$(BUILD)/sasm -T 0x8000 -o $@ $<

$(BUILD)/prog/as: os/progs/as.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/prog
	$(BUILD)/sasm -T 0x8000 -o $@ $<

$(USRCS): $(BUILD)/src/%.s: os/progs/%.s os/lib/sys.s
	@mkdir -p $(BUILD)/src
	grep -v '^[[:space:]]*\.include' $< > $@
	cat os/lib/sys.s >> $@

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

DISK_FILES := $(OS_FILES) $(SPROGS) $(UPROGS) $(BUILD)/prog/untag $(WSPROGS) $(PROGS) $(BUILD)/prog/as \
              $(BUILD)/prog/units $(SRCS) $(USRCS) $(FORTH_DISK)

# The same files with their tags (mkdisk -t TAGS applies to the files after it).
# The file system has no directories: `ls /bin` lists the files tagged bin,
# `ls /src/demo` those tagged both src and demo.
DISK_ARGS := -t doc $(filter-out %/rc,$(OS_FILES)) -t etc $(filter %/rc,$(OS_FILES)) \
             -t sys $(SPROGS) -t bin $(UPROGS) $(BUILD)/prog/untag -t bin,ws $(WSPROGS) \
             -t demo $(PROGS) -t bin $(BUILD)/prog/as $(BUILD)/prog/units \
             -t src,demo $(EXSRCS) -t src $(BUILD)/src/as.s $(BUILD)/src/units.s $(USRCS) \
             -t bin,forth $(BUILD)/prog/forth -t forth lang/forth/core.fs lang/forth/tools.fs lang/forth/see.fs \
             -t forth,demo $(wildcard lang/forth/demos/*.fs)

$(BUILD)/disk.img: $(BUILD)/kernel.stx $(BUILD)/mkdisk $(DISK_FILES)
	$(BUILD)/mkdisk -o $@ -k $(BUILD)/kernel.stx $(DISK_ARGS)

os: $(BUILD)/bootrom.stx $(BUILD)/disk.img

# the same disk with an rc that starts the window server (make boot-ws)
DISK_WS_ARGS := $(subst os/files/rc,os/files-ws/rc,$(DISK_ARGS))

$(BUILD)/disk-ws.img: $(BUILD)/kernel.stx $(BUILD)/mkdisk $(DISK_FILES) os/files-ws/rc
	$(BUILD)/mkdisk -o $@ -k $(BUILD)/kernel.stx $(DISK_WS_ARGS)

# the emulator boots StrataOS with 12 cores; the RTL with NCORES
BOOT_EMU := $(BUILD)/strata-emu -c 12

boot: $(BUILD)/strata-emu os
	@cp $(BUILD)/disk.img $(BUILD)/disk-run.img
	@$(BOOT_EMU) -d $(BUILD)/disk-run.img $(BUILD)/bootrom.stx

boot-ws: $(BUILD)/strata-emu $(BUILD)/bootrom.stx $(BUILD)/disk-ws.img
	@cp $(BUILD)/disk-ws.img $(BUILD)/disk-run.img
	@$(BOOT_EMU) -d $(BUILD)/disk-run.img $(BUILD)/bootrom.stx

boot-demo: $(BUILD)/strata-emu os
	@cp $(BUILD)/disk.img $(BUILD)/disk-run.img
	@$(BOOT_EMU) -g none -d $(BUILD)/disk-run.img -i os/demo.txt $(BUILD)/bootrom.stx

boot-rtl: $(BUILD)/strata-rtl os
	@cp $(BUILD)/disk.img $(BUILD)/disk-run.img
	@$(BUILD)/strata-rtl -d $(BUILD)/disk-run.img $(BUILD)/bootrom.stx

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
	$(BUILD)/mkhex plat 2 256 $(FPGA)/plat.hex

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
	$(BUILD)/sasm -I lang/forth/bare -I $(BUILD)/forth -o $@ lang/forth/forth.s

# the StrataOS program (lang/forth/os/: the platform layer on messages)
$(BUILD)/forth-os/corefs.s: $(FORTH_OS_FS)
	@mkdir -p $(BUILD)/forth-os
	$(FORTH_EMBED) $(FORTH_OS_FS) > $@

$(BUILD)/prog/forth: $(FORTH_OS_SRC) $(BUILD)/forth-os/corefs.s $(BUILD)/sasm
	@mkdir -p $(BUILD)/prog
	$(BUILD)/sasm -T 0x8000 -I lang/forth/os -I $(BUILD)/forth-os -o $@ lang/forth/forth.s

# the disk of `make test-forth`: the standard one plus the test files
$(BUILD)/forth-test/disk.img: $(BUILD)/kernel.stx $(BUILD)/mkdisk $(DISK_FILES) $(wildcard lang/forth/tests/*.fs)
	@mkdir -p $(BUILD)/forth-test
	$(BUILD)/mkdisk -o $@ -k $(BUILD)/kernel.stx $(DISK_ARGS) -t forth,test $(wildcard lang/forth/tests/*.fs)

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
$(WEB)/strata-emu.js: web/web.c emu/emu.c emu/jit/jit_wasm.c emu/jit/jit.h emu/jit/jit_be.h asm/isa.h common/stx.h common/platform.h common/display.h
	@mkdir -p $(WEB)
	$(EMCC) -std=gnu11 -O3 -Wall -DNO_SDL -o $@ web/web.c emu/jit/jit_wasm.c \
	  -sMODULARIZE=1 -sEXPORT_NAME=createStrata -sENVIRONMENT=worker,node -sINVOKE_RUN=0 -sEXIT_RUNTIME=0 \
	  -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=192MB -sALLOW_TABLE_GROWTH=1 \
	  -sEXPORTED_FUNCTIONS=_main,_web_run,_web_paint,_web_input,_web_break,_web_pointer,_web_pointer_used,_web_stop,_web_finish,_web_stat,_jit_wasm_stat,_jit_wasm_set_hot,_malloc,_free \
	  -sEXPORTED_RUNTIME_METHODS=callMain,FS,HEAPU8,wasmMemory,wasmTable

wasm: $(WEB)/strata-emu.js web-assets
	@mkdir -p $(WEB)/images $(WEB)/demos
	cp $(WEB_IMAGES) $(WEB)/images/
	cp lang/forth/demos/*.fs $(WEB)/demos/
	ls lang/forth/demos | sed -n 's/\.fs$$//p' > $(WEB)/demos/index.txt

web-code:
	rm -rf $(BUILD)/web-code
	mkdir -p $(BUILD)/web-code
	python3 tools/web-code.py $(BUILD)/web-code

web-site: wasm web-code
	rm -rf $(BUILD)/web-site
	mkdir -p $(BUILD)/web-site
	cp -r site/. $(BUILD)/web-site/
	cp -r $(WEB)/. $(BUILD)/web-site/play/
	cp -r $(BUILD)/web-code/. $(BUILD)/web-site/code/

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
