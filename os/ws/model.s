; =============================================================================
; model.s: what the window server shows (the renderers' only input)
; =============================================================================
;
; Every renderer (lattice, tile frames, palette, splash) reads this model and
; nothing else. A *data source* keeps it up to date: in the real `ws` that
; is the kernel's STATS / proc's PS and INFO, the clients' CREATE / DAMAGE /
; TITLE requests and the keyboard; in the bare-metal demo it is fake.s. When
; the source changes something it also says what changed (dmg_add, or the
; helpers below) so that only that part of the screen is drawn again.
;
; The screen
;   m_scr      the screen surface (a gfx.s descriptor address)
;   m_w, m_h   its size
;
; Cores (the lattice): m_ncores records of CO_SIZE bytes at m_cores
;   CO_PID    process running there (0: idle)
;   CO_FLAGS  CF_SYS the system core, CF_SRV a server runs there
;   CO_PULSE  0..PULSE_MAX: set on a context switch, fades by one per frame
;
; Processes: m_nproc records of PR_SIZE bytes at m_procs
;   PR_PID, PR_NAME (8 bytes, NUL-padded), PR_HUE (its colour), PR_CORE,
;   PR_KIB10 (tenths of KiB moved by its context switches), PR_FLAGS (PF_SRV)
;
; System figures (the right end of the strip): m_clock (seconds since
; midnight), m_uptime (seconds), m_swps (context switches per second),
; m_slice (the scheduler's time slice, microseconds).
;
; Windows (tiles): m_nwin records of WN_SIZE bytes at m_wins, in tile order;
; m_focus is the focused one's index.
;   WN_KIND   WK_TERM / WK_GFX          WN_PID, WN_CORE   its process
;   WN_NAME   8 bytes: TERM, WMANDEL ... WN_SURF the client's surface (48 B)
;   WN_CUR    x, y, w, h now (moves while sliding)
;   WN_FROM   where a slide started     WN_TO   where it ends (layout.s)
;   WN_ANIM   frames into the slide (0: still)
;   WN_FADE   0..256 how far a new tile has faded in
;   WN_TAG / WN_TAGN, WN_KIBS / WN_KIBN   its HUD texts (frame.s makes them)
;   WN_EVT    events for its client (WE_RESIZE when a slide has ended)
;
; Command palette: m_pal_open, the input m_pal_buf / m_pal_len, m_pal_sel.
;
; Pointer: m_ptr_on (over the screen: the cursor is drawn), m_ptr_x, m_ptr_y,
; m_ptr_btn (buttons held). Help: m_help (the key help is shown).

MAXCORE   = 16                          ; cores the lattice can show
MAXPROC   = 32                          ; processes
MAXWIN    = 4                           ; tiles
PULSE_MAX = 10                          ; frames a pulse lasts

CO_PID    = 0                           ; core record: running process
CO_FLAGS  = 8                           ; flags
CO_PULSE  = 16                          ; pulse level
CO_SIZE   = 32                          ; bytes per core record
CF_SYS    = 1                           ; the system core (kernel)
CF_SRV    = 2                           ; a server's core

PR_PID    = 0                           ; process record: pid
PR_NAME   = 8                           ; name (8 bytes)
PR_HUE    = 16                          ; colour
PR_CORE   = 24                          ; core
PR_KIB10  = 32                          ; tenths of KiB moved by switches
PR_FLAGS  = 40                          ; flags
PR_SIZE   = 48                          ; bytes per process record
PF_SRV    = 1                           ; a server

WK_TERM   = 1                           ; a terminal tile
WK_GFX    = 2                           ; a graphics client's tile
WN_KIND   = 0                           ; window record: kind
WN_PID    = 8                           ; process
WN_CORE   = 16                          ; its core
WN_NAME   = 24                          ; name (8 bytes)
WN_SURF   = 32                          ; surface descriptor (S_SIZE = 48)
WN_CUR    = 80                          ; x, y, w, h now
WN_FROM   = 112                         ; slide start
WN_TO     = 144                         ; slide end
WN_ANIM   = 176                         ; frames into the slide
WN_FADE   = 184                         ; fade-in, 0..256
WN_TAGN   = 192                         ; tag length
WN_KIBN   = 200                         ; readout length
WN_TAG    = 208                         ; tag text (48 bytes)
WN_KIBS   = 256                         ; readout text (24 bytes)
WN_EVT    = 280                         ; events for the client: WE_RESIZE ...
WN_CLIENT = 288                         ; the client's state (demo: renderer state)
WN_SIZE   = 296                         ; bytes per window record
WE_RESIZE = 1                           ; the tile has its new size: draw again

        .data                           ; D-LS
        .align 8                        ; dwords
m_scr:    .dword 0                      ; the screen surface
m_w:      .dword 0                      ; its width
m_h:      .dword 0                      ; its height
m_ncores: .dword 0                      ; cores
m_nproc:  .dword 0                      ; processes
m_nwin:   .dword 0                      ; windows
m_focus:  .dword 0                      ; focused window
m_clock:  .dword 0                      ; seconds since midnight
m_uptime: .dword 0                      ; seconds since boot
m_swps:   .dword 0                      ; context switches per second
m_slice:  .dword 0                      ; the time slice in microseconds (0: not shown)
m_pal_open: .dword 0                    ; palette shown?
m_pal_len: .dword 0                     ; characters typed
m_pal_sel: .dword 0                     ; selected completion
m_splash: .dword 0                      ; splash frame (0: no splash)
m_help:   .dword 0                      ; the key help is shown
m_ptr_on: .dword 0                      ; the pointer is over the screen
m_ptr_x:  .dword 0                      ; where (pixels)
m_ptr_y:  .dword 0                      ; ...
m_ptr_btn: .dword 0                     ; buttons held
m_pal_buf: .space 32                    ; what was typed
m_cores:  .space MAXCORE * CO_SIZE      ; core records
m_procs:  .space MAXPROC * PR_SIZE      ; process records
m_wins:   .space MAXWIN * WN_SIZE       ; window records
        .text                           ; code

; m_win(a0 = index) -> a0 = window record
m_win:                                  ; routine entry
        li    t0, WN_SIZE               ; record size
        mul   a0, a0, t0                ; offset
        la    t0, m_wins                ; table
        add   a0, a0, t0                ; record
        ret                             ; done

; m_proc_by_pid(a0 = pid) -> a0 = process record or 0
m_proc_by_pid:                          ; routine entry
        la    t0, m_procs               ; first record
        la    t1, m_nproc               ; how many
        ld    t1, 0(t1)                 ; ...
mp_l:   beqz  t1, mp_none               ; not found
        ld    t2, PR_PID(t0)            ; its pid
        beq   t2, a0, mp_yes            ; this one
        addi  t0, t0, PR_SIZE           ; next
        addi  t1, t1, -1                ; one fewer
        j     mp_l                      ; continue
mp_yes: mv    a0, t0                    ; found
        ret                             ; done
mp_none:
        li    a0, 0                     ; none
        ret                             ; done
