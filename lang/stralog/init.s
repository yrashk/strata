; =============================================================================
; init.s: start-up (a code unit)
; =============================================================================
;
; pl_init: the streams; the predefined atoms (atoms.s) into the hash; a
; predicate record for every builtin (bi_tab: functor, then a control id or
; the routine's far address); boot.pl, consulted from the far section.

        .far                            ; code units
        .align 4096                     ; ---- unit: start-up ----
u_init:

pl_init:
        jalr  t6, gp, ent2-R            ; s1 cursor, s2 end
        la    t6, io_init               ; the streams
        xcall ra, c0, t6                ; ...
        li    s1, at_first              ; the predefined atoms
        li    s2, at_last               ; ...
pi_atoms:
        bgeu  s1, s2, pi_bis            ; ...
        mv    a0, s1                    ; ...
        la    t6, atom_hashin           ; ...
        xcall ra, c0, t6                ; ...
        addi  a0, s1, AT_LEN            ; the next record
        jalr  ra, gp, mrd-R             ; ...
        addi  a0, a0, 7                 ; ...
        srli  a0, a0, 3                 ; ...
        slli  a0, a0, 3                 ; ...
        add   s1, s1, a0                ; ...
        addi  s1, s1, AT_NAME           ; ...
        j     pi_atoms                  ; ...
pi_bis:
        la    s1, bi_tab                ; the builtins
        la    s2, bi_tab_end            ; ...
pi_bi:
        bgeu  s1, s2, pi_boot           ; ...
        mv    a0, s1                    ; the functor
        jalr  ra, gp, mrd-R             ; ...
        la    t6, pred_get              ; ...
        xcall ra, c0, t6                ; ...
        sd    a0, v_tmp+24(zero)        ; ...
        addi  a0, s1, 8                 ; what it is
        jalr  ra, gp, mrd-R             ; ...
        mv    a1, a0                    ; ...
        ld    a0, v_tmp+24(zero)        ; ...
        addi  a0, a0, PR_BI             ; ...
        jalr  ra, gp, mwr-R             ; ...
        addi  s1, s1, 16                ; ...
        j     pi_bi                     ; ...
pi_boot:
        li    t0, 1                     ; boot.pl is consult 1
        sd    t0, v_cons(zero)          ; ...
        la    a0, boot_pl               ; a stream over its text
        la    a1, boot_pl_end           ; ...
        la    t6, io_text               ; ...
        xcall ra, c0, t6                ; ...
        mv    s1, a0                    ; ...
pi_clause:
        ld    t0, v_H(zero)             ; (each clause's term is garbage once it is compiled)
        sd    t0, v_tmp+16(zero)        ; ...
        mv    a0, s1                    ; ...
        la    t6, read_term             ; ...
        xcall ra, c0, t6                ; ...
        li    t0, at_eof + T_ATM        ; the end
        beq   a0, t0, pi_done           ; ...
        li    a1, 0                     ; ...
        li    a2, 1                     ; ...
        la    t6, add_clause            ; ...
        xcall ra, c0, t6                ; ...
        ld    t0, v_tmp+16(zero)        ; ...
        sd    t0, v_H(zero)             ; ...
        j     pi_clause                 ; ...
pi_done:
        mv    a0, s1                    ; ...
        la    t6, io_close              ; ...
        xcall ra, c0, t6                ; ...
        li    t0, A_HEAP                ; an empty heap
        sd    t0, v_H(zero)             ; ...
        jalr  zero, gp, lv2-R           ; ...

        .align 8                        ; ...
bi_tab:                                 ; functor cell, control id or routine
        .dword ((at_true >> 3) << 16) | (0 << 3) | T_FUN, C_TRUE               ; true/0
        .dword ((at_fail >> 3) << 16) | (0 << 3) | T_FUN, C_FAIL               ; fail/0
        .dword ((at_false >> 3) << 16) | (0 << 3) | T_FUN, C_FAIL              ; false/0
        .dword ((at_comma >> 3) << 16) | (2 << 3) | T_FUN, C_CONJ              ; comma/2
        .dword ((at_cut >> 3) << 16) | (0 << 3) | T_FUN, C_CUT                 ; cut/0
        .dword ((at_semi >> 3) << 16) | (2 << 3) | T_FUN, C_OR                 ; semi/2
        .dword ((at_bar >> 3) << 16) | (2 << 3) | T_FUN, C_OR                  ; bar/2
        .dword ((at_arrow >> 3) << 16) | (2 << 3) | T_FUN, C_ITE               ; arrow/2
        .dword ((at_sarrow >> 3) << 16) | (2 << 3) | T_FUN, C_SOFT             ; sarrow/2
        .dword ((at_not_prov >> 3) << 16) | (1 << 3) | T_FUN, C_NOT            ; not_prov/1
        .dword ((at_not >> 3) << 16) | (1 << 3) | T_FUN, C_NOT                 ; not/1
        .dword ((at_call >> 3) << 16) | (1 << 3) | T_FUN, C_CALL               ; call/1
        .dword ((at_call >> 3) << 16) | (2 << 3) | T_FUN, C_CALL               ; call/2
        .dword ((at_call >> 3) << 16) | (3 << 3) | T_FUN, C_CALL               ; call/3
        .dword ((at_call >> 3) << 16) | (4 << 3) | T_FUN, C_CALL               ; call/4
        .dword ((at_call >> 3) << 16) | (5 << 3) | T_FUN, C_CALL               ; call/5
        .dword ((at_call >> 3) << 16) | (6 << 3) | T_FUN, C_CALL               ; call/6
        .dword ((at_call >> 3) << 16) | (7 << 3) | T_FUN, C_CALL               ; call/7
        .dword ((at_call >> 3) << 16) | (8 << 3) | T_FUN, C_CALL               ; call/8
        .dword ((at_catch >> 3) << 16) | (3 << 3) | T_FUN, C_CATCH             ; catch/3
        .dword ((at_throw >> 3) << 16) | (1 << 3) | T_FUN, C_THROW             ; throw/1
        .dword ((at_findall >> 3) << 16) | (3 << 3) | T_FUN, C_FINDALL         ; findall/3
        .dword ((at_dollar_faadd >> 3) << 16) | (1 << 3) | T_FUN, C_FAADD      ; dollar_faadd/1
        .dword ((at_dollar_cut >> 3) << 16) | (1 << 3) | T_FUN, C_DCUT         ; dollar_cut/1
        .dword ((at_dollar_exitc >> 3) << 16) | (1 << 3) | T_FUN, C_EXITC      ; dollar_exitc/1
        .dword ((at_dollar_softcut >> 3) << 16) | (1 << 3) | T_FUN, C_SOFTCUT  ; dollar_softcut/1
        .dword ((at_p_choice >> 3) << 16) | (1 << 3) | T_FUN, C_CHOICE         ; p_choice/1
        .dword ((at_halt >> 3) << 16) | (0 << 3) | T_FUN, C_HALT               ; halt/0
        .dword ((at_halt >> 3) << 16) | (1 << 3) | T_FUN, C_HALT               ; halt/1
        .dword ((at_p_var >> 3) << 16) | (1 << 3) | T_FUN, bi_var              ; p_var/1
        .dword ((at_p_nonvar >> 3) << 16) | (1 << 3) | T_FUN, bi_nonvar        ; p_nonvar/1
        .dword ((at_atom >> 3) << 16) | (1 << 3) | T_FUN, bi_atom              ; atom/1
        .dword ((at_number >> 3) << 16) | (1 << 3) | T_FUN, bi_integer         ; number/1
        .dword ((at_integer >> 3) << 16) | (1 << 3) | T_FUN, bi_integer        ; integer/1
        .dword ((at_atomic >> 3) << 16) | (1 << 3) | T_FUN, bi_atomic          ; atomic/1
        .dword ((at_compound >> 3) << 16) | (1 << 3) | T_FUN, bi_compound      ; compound/1
        .dword ((at_callable >> 3) << 16) | (1 << 3) | T_FUN, bi_callable      ; callable/1
        .dword ((at_eq >> 3) << 16) | (2 << 3) | T_FUN, bi_unify               ; eq/2
        .dword ((at_neq >> 3) << 16) | (2 << 3) | T_FUN, bi_nunify             ; neq/2
        .dword ((at_eqeq >> 3) << 16) | (2 << 3) | T_FUN, bi_tcmp              ; eqeq/2
        .dword ((at_neqeq >> 3) << 16) | (2 << 3) | T_FUN, bi_tcmp             ; neqeq/2
        .dword ((at_tlt >> 3) << 16) | (2 << 3) | T_FUN, bi_tcmp               ; tlt/2
        .dword ((at_tgt >> 3) << 16) | (2 << 3) | T_FUN, bi_tcmp               ; tgt/2
        .dword ((at_tle >> 3) << 16) | (2 << 3) | T_FUN, bi_tcmp               ; tle/2
        .dword ((at_tge >> 3) << 16) | (2 << 3) | T_FUN, bi_tcmp               ; tge/2
        .dword ((at_p_compare >> 3) << 16) | (3 << 3) | T_FUN, bi_compare      ; p_compare/3
        .dword ((at_p_functor >> 3) << 16) | (3 << 3) | T_FUN, bi_functor      ; p_functor/3
        .dword ((at_p_arg >> 3) << 16) | (3 << 3) | T_FUN, bi_arg              ; p_arg/3
        .dword ((at_univ >> 3) << 16) | (2 << 3) | T_FUN, bi_univ              ; univ/2
        .dword ((at_p_copy_term >> 3) << 16) | (2 << 3) | T_FUN, bi_copy       ; p_copy_term/2
        .dword ((at_p_term_variables >> 3) << 16) | (2 << 3) | T_FUN, bi_tvars ; p_term_variables/2
        .dword ((at_is >> 3) << 16) | (2 << 3) | T_FUN, bi_is                  ; is/2
        .dword ((at_aeq >> 3) << 16) | (2 << 3) | T_FUN, bi_acmp               ; aeq/2
        .dword ((at_ane >> 3) << 16) | (2 << 3) | T_FUN, bi_acmp               ; ane/2
        .dword ((at_lt >> 3) << 16) | (2 << 3) | T_FUN, bi_acmp                ; lt/2
        .dword ((at_gt >> 3) << 16) | (2 << 3) | T_FUN, bi_acmp                ; gt/2
        .dword ((at_le >> 3) << 16) | (2 << 3) | T_FUN, bi_acmp                ; le/2
        .dword ((at_ge >> 3) << 16) | (2 << 3) | T_FUN, bi_acmp                ; ge/2
        .dword ((at_p_atom_codes >> 3) << 16) | (2 << 3) | T_FUN, bi_atom_codes ; p_atom_codes/2
        .dword ((at_p_atom_chars >> 3) << 16) | (2 << 3) | T_FUN, bi_atom_chars ; p_atom_chars/2
        .dword ((at_p_char_code >> 3) << 16) | (2 << 3) | T_FUN, bi_char_code  ; p_char_code/2
        .dword ((at_atom_length >> 3) << 16) | (2 << 3) | T_FUN, bi_atom_length ; atom_length/2
        .dword ((at_p_number_codes >> 3) << 16) | (2 << 3) | T_FUN, bi_number_codes ; p_number_codes/2
        .dword ((at_p_number_chars >> 3) << 16) | (2 << 3) | T_FUN, bi_number_chars ; p_number_chars/2
        .dword ((at_write >> 3) << 16) | (1 << 3) | T_FUN, bi_write            ; write/1
        .dword ((at_write >> 3) << 16) | (2 << 3) | T_FUN, bi_write            ; write/2
        .dword ((at_print >> 3) << 16) | (1 << 3) | T_FUN, bi_write            ; print/1
        .dword ((at_print >> 3) << 16) | (2 << 3) | T_FUN, bi_write            ; print/2
        .dword ((at_writeq >> 3) << 16) | (1 << 3) | T_FUN, bi_write           ; writeq/1
        .dword ((at_writeq >> 3) << 16) | (2 << 3) | T_FUN, bi_write           ; writeq/2
        .dword ((at_wcanon >> 3) << 16) | (1 << 3) | T_FUN, bi_write           ; wcanon/1
        .dword ((at_wcanon >> 3) << 16) | (2 << 3) | T_FUN, bi_write           ; wcanon/2
        .dword ((at_p_write_term >> 3) << 16) | (2 << 3) | T_FUN, bi_write_term ; p_write_term/2
        .dword ((at_p_write_term >> 3) << 16) | (3 << 3) | T_FUN, bi_write_term ; p_write_term/3
        .dword ((at_p_nl >> 3) << 16) | (0 << 3) | T_FUN, bi_nl                ; p_nl/0
        .dword ((at_p_nl >> 3) << 16) | (1 << 3) | T_FUN, bi_nl                ; p_nl/1
        .dword ((at_p_put_char >> 3) << 16) | (1 << 3) | T_FUN, bi_put_char    ; p_put_char/1
        .dword ((at_p_put_char >> 3) << 16) | (2 << 3) | T_FUN, bi_put_char    ; p_put_char/2
        .dword ((at_p_get_char >> 3) << 16) | (1 << 3) | T_FUN, bi_get_char    ; p_get_char/1
        .dword ((at_p_get_char >> 3) << 16) | (2 << 3) | T_FUN, bi_get_char    ; p_get_char/2
        .dword ((at_p_peek_char >> 3) << 16) | (1 << 3) | T_FUN, bi_peek_char  ; p_peek_char/1
        .dword ((at_p_peek_char >> 3) << 16) | (2 << 3) | T_FUN, bi_peek_char  ; p_peek_char/2
        .dword ((at_read >> 3) << 16) | (1 << 3) | T_FUN, bi_read              ; read/1
        .dword ((at_read >> 3) << 16) | (2 << 3) | T_FUN, bi_read              ; read/2
        .dword ((at_p_read_term >> 3) << 16) | (2 << 3) | T_FUN, bi_read       ; p_read_term/2
        .dword ((at_p_read_term >> 3) << 16) | (3 << 3) | T_FUN, bi_read       ; p_read_term/3
        .dword ((at_open >> 3) << 16) | (3 << 3) | T_FUN, bi_open              ; open/3
        .dword ((at_open >> 3) << 16) | (4 << 3) | T_FUN, bi_open              ; open/4
        .dword ((at_p_close >> 3) << 16) | (1 << 3) | T_FUN, bi_close          ; p_close/1
        .dword ((at_p_set_input >> 3) << 16) | (1 << 3) | T_FUN, bi_set_input  ; p_set_input/1
        .dword ((at_p_set_output >> 3) << 16) | (1 << 3) | T_FUN, bi_set_output ; p_set_output/1
        .dword ((at_p_current_input >> 3) << 16) | (1 << 3) | T_FUN, bi_current_input ; p_current_input/1
        .dword ((at_p_current_output >> 3) << 16) | (1 << 3) | T_FUN, bi_current_output ; p_current_output/1
        .dword ((at_p_flush_output >> 3) << 16) | (0 << 3) | T_FUN, bi_flush   ; p_flush_output/0
        .dword ((at_p_flush_output >> 3) << 16) | (1 << 3) | T_FUN, bi_flush   ; p_flush_output/1
        .dword ((at_p_line >> 3) << 16) | (2 << 3) | T_FUN, bi_line            ; p_line/2
        .dword ((at_p_argv >> 3) << 16) | (1 << 3) | T_FUN, bi_argv            ; p_argv/1
        .dword ((at_p_assert >> 3) << 16) | (1 << 3) | T_FUN, bi_assert        ; p_assert/1
        .dword ((at_p_asserta >> 3) << 16) | (1 << 3) | T_FUN, bi_assert       ; p_asserta/1
        .dword ((at_p_assertz >> 3) << 16) | (1 << 3) | T_FUN, bi_assert       ; p_assertz/1
        .dword ((at_p_add_clause >> 3) << 16) | (1 << 3) | T_FUN, bi_add_clause ; p_add_clause/1
        .dword ((at_p_new_consult >> 3) << 16) | (0 << 3) | T_FUN, bi_new_consult ; p_new_consult/0
        .dword ((at_p_clauses >> 3) << 16) | (2 << 3) | T_FUN, bi_clauses      ; p_clauses/2
        .dword ((at_dollar_clause >> 3) << 16) | (3 << 3) | T_FUN, bi_clause   ; dollar_clause/3
        .dword ((at_p_erase >> 3) << 16) | (1 << 3) | T_FUN, bi_erase          ; p_erase/1
        .dword ((at_p_dynamic >> 3) << 16) | (2 << 3) | T_FUN, bi_dynamic      ; p_dynamic/2
        .dword ((at_p_op >> 3) << 16) | (3 << 3) | T_FUN, bi_op                ; p_op/3
        .dword ((at_p_op_atoms >> 3) << 16) | (1 << 3) | T_FUN, bi_op_atoms    ; p_op_atoms/1
        .dword ((at_p_op_defs >> 3) << 16) | (2 << 3) | T_FUN, bi_op_defs      ; p_op_defs/2
        .dword ((at_p_preds >> 3) << 16) | (1 << 3) | T_FUN, bi_preds          ; p_preds/1
        .dword ((at_p_stats >> 3) << 16) | (1 << 3) | T_FUN, bi_stats          ; p_stats/1
        .dword ((at_p_now >> 3) << 16) | (1 << 3) | T_FUN, bi_now              ; p_now/1
        .dword ((at_p_is_builtin >> 3) << 16) | (1 << 3) | T_FUN, bi_is_builtin ; p_is_builtin/1
        .dword ((at_p_atom_stream >> 3) << 16) | (2 << 3) | T_FUN, bi_atom_stream ; '$atom_stream'/2
bi_tab_end:                             ; ...
u_init_end:
