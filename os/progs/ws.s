; =============================================================================
; ws.s: the window server (the program on the StrataOS disk)
; =============================================================================
;
; `ws` typed at a shell starts the window server: proc makes a program of
; this name its core's server. The server itself, its renderers and its
; kernel interface are in os/ws/ (ws.s is the main loop and the protocol;
; os/ws/README.md has the module map).

        .include "../ws/ws.s"           ; the whole server
