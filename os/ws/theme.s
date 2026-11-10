; =============================================================================
; theme.s: the window server's palette and metrics
; =============================================================================
;
; One place for every colour and size the renderers use (spec 2.8, "Look and
; feel"). Colours are 0x00RRGGBB (stored B, G, R, unused: XRGB8888).

; ---- palette -----------------------------------------------------------------
C_BG      = 0x070A12                    ; near-black blue background
C_GRID    = 0x0C1320                    ; the faint 16-pixel grid
C_GRIDX   = 0x16233A                    ; the small crosses every 64 pixels
C_PANEL   = 0x0A101C                    ; a tile's body (terminal background)
C_STRIP   = 0x090E18                    ; the status strip
C_EDGE    = 0x1F6F8B                    ; edges: deep teal
C_ACCENT  = 0x4DE1FF                    ; accent: cyan
C_FOCUS   = 0xFFB347                    ; focus: amber
C_TEXT    = 0xCFE8FF                    ; text: pale blue-white
C_DIM     = 0x5B7088                    ; dim text
C_FAINT   = 0x2A3A50                    ; fainter still (separators, idle cells)

; ---- metrics -----------------------------------------------------------------
M_STRIP   = 28                          ; height of the status strip (lattice)
M_GAP     = 6                           ; gap between tiles and around them
M_CHAMF   = 6                           ; corner cut of a tile
M_PADX    = 8                           ; tile edge to content, left and right
M_PADT    = 12                          ; top (room for the tag)
M_PADB    = 8                           ; bottom
