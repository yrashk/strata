#!/usr/bin/env python3
"""Writes atoms.s: Stralog's predefined atoms as records in the image's far
section. Each atom's cell is its record's arena offset + 3, so code names an
atom by its label (li a0, at_nil + T_ATM) and the assembler knows the value.

Record (lang/prolog/stralog.s, "atom record"):
  0 next record in its hash chain   8 length   16 predicates   24 operators
  32 (spare)   40 the name, padded to 8 bytes
Operators: prefix | infix << 16 | postfix << 32, each priority | type << 12
(types: xfx 1, xfy 2, yfx 3, fy 4, fx 5, xf 6, yf 7).

  python3 mkatoms.py OUT.s
"""
import sys

T = {'xfx': 1, 'xfy': 2, 'yfx': 3, 'fy': 4, 'fx': 5, 'xf': 6, 'yf': 7}

# (label, name, [(priority, type), ...])
ATOMS = [
    ('nil', '[]', []), ('dot', '.', []), ('curly', '{}', []),
    ('comma', ',', [(1000, 'xfy')]), ('semi', ';', [(1100, 'xfy')]),
    ('bar', '|', [(1100, 'xfy')]),
    ('arrow', '->', [(1050, 'xfy')]), ('sarrow', '*->', [(1050, 'xfy')]),
    ('not_prov', '\\+', [(900, 'fy')]), ('cut', '!', []),
    ('true', 'true', []), ('fail', 'fail', []), ('false', 'false', []),
    ('call', 'call', []), ('catch', 'catch', []), ('throw', 'throw', []),
    ('findall', 'findall', []), ('not', 'not', []), ('halt', 'halt', []),
    ('neck', ':-', [(1200, 'xfx'), (1200, 'fx')]), ('dcg', '-->', [(1200, 'xfx')]),
    ('query', '?-', [(1200, 'fx')]),
    ('dynamic', 'dynamic', [(1150, 'fx')]),
    ('discontiguous', 'discontiguous', [(1150, 'fx')]),
    ('initialization', 'initialization', [(1150, 'fx')]),
    ('eq', '=', [(700, 'xfx')]), ('neq', '\\=', [(700, 'xfx')]),
    ('eqeq', '==', [(700, 'xfx')]), ('neqeq', '\\==', [(700, 'xfx')]),
    ('tlt', '@<', [(700, 'xfx')]), ('tgt', '@>', [(700, 'xfx')]),
    ('tle', '@=<', [(700, 'xfx')]), ('tge', '@>=', [(700, 'xfx')]),
    ('univ', '=..', [(700, 'xfx')]), ('is', 'is', [(700, 'xfx')]),
    ('aeq', '=:=', [(700, 'xfx')]), ('ane', '=\\=', [(700, 'xfx')]),
    ('lt', '<', [(700, 'xfx')]), ('gt', '>', [(700, 'xfx')]),
    ('le', '=<', [(700, 'xfx')]), ('ge', '>=', [(700, 'xfx')]),
    ('colon', ':', [(200, 'xfy')]),
    ('plus', '+', [(500, 'yfx'), (200, 'fy')]), ('minus', '-', [(500, 'yfx'), (200, 'fy')]),
    ('star', '*', [(400, 'yfx')]), ('slash', '/', [(400, 'yfx')]),
    ('idiv', '//', [(400, 'yfx')]), ('mod', 'mod', [(400, 'yfx')]),
    ('rem', 'rem', [(400, 'yfx')]), ('div', 'div', [(400, 'yfx')]),
    ('band', '/\\', [(500, 'yfx')]), ('bor', '\\/', [(500, 'yfx')]),
    ('xor', 'xor', [(500, 'yfx')]), ('bnot', '\\', [(200, 'fy')]),
    ('shl', '<<', [(400, 'yfx')]), ('shr', '>>', [(400, 'yfx')]),
    ('pow', '**', [(200, 'xfx')]), ('caret', '^', [(200, 'xfy')]),
    ('min', 'min', []), ('max', 'max', []), ('abs', 'abs', []),
    ('sign', 'sign', []), ('gcd', 'gcd', []), ('msb', 'msb', []),
    ('dollar_cont', '$cont', []), ('dollar_cut', '$cut', []),
    ('dollar_exitc', '$exit_catch', []), ('dollar_softcut', '$softcut', []),
    ('dollar_faadd', '$fa_add', []), ('dollar_var', '$VAR', []),
    ('dollar_stream', '$stream', []), ('dollar_start', '$start', []),
    ('error', 'error', []), ('inst_err', 'instantiation_error', []),
    ('type_err', 'type_error', []), ('dom_err', 'domain_error', []),
    ('exist_err', 'existence_error', []), ('perm_err', 'permission_error', []),
    ('repr_err', 'representation_error', []), ('eval_err', 'evaluation_error', []),
    ('res_err', 'resource_error', []), ('syn_err', 'syntax_error', []),
    ('callable', 'callable', []), ('atom', 'atom', []), ('atomic', 'atomic', []),
    ('integer', 'integer', []), ('number', 'number', []), ('list', 'list', []),
    ('compound', 'compound', []), ('variable', 'variable', []),
    ('character', 'character', []), ('character_code', 'character_code', []),
    ('evaluable', 'evaluable', []), ('procedure', 'procedure', []),
    ('zero_div', 'zero_divisor', []), ('int_ovf', 'int_overflow', []),
    ('memory', 'memory', []), ('eof', 'end_of_file', []),
    ('not_less', 'not_less_than_zero', []), ('modify', 'modify', []),
    ('static_proc', 'static_procedure', []), ('access', 'access', []),
    ('private_proc', 'private_procedure', []), ('op_spec', 'operator_specifier', []),
    ('op_prio', 'operator_priority', []), ('operator', 'operator', []),
    ('max_arity', 'max_arity', []), ('stream', 'stream', []),
    ('source_sink', 'source_sink', []), ('open', 'open', []),
    ('input', 'input', []), ('output', 'output', []),
    ('io_mode', 'io_mode', []), ('read', 'read', []), ('write', 'write', []),
    ('append', 'append', []), ('user', 'user', []),
    ('user_input', 'user_input', []), ('user_output', 'user_output', []),
    ('user_error', 'user_error', []), ('create', 'create', []),
    ('stack', 'stack', []), ('term_depth', 'term_depth', []),
    ('atom_length', 'atom_length', []), ('clauses', 'clauses', []),
    ('atoms', 'atoms', []),
    ('xfx', 'xfx', []), ('xfy', 'xfy', []), ('yfx', 'yfx', []),
    ('fy', 'fy', []), ('fx', 'fx', []), ('xf', 'xf', []), ('yf', 'yf', []),
    ('variable_names', 'variable_names', []), ('quoted', 'quoted', []),
    ('ignore_ops', 'ignore_ops', []), ('numbervars', 'numbervars', []),
    ('on', 'on', []), ('off', 'off', []), ('eof_code', 'eof_code', []),
    ('consult', 'consult', []), ('arith_div', 'undefined', []),
    ('lparen', '(', []), ('rparen', ')', []), ('lbrack', '[', []),
    ('rbrack', ']', []), ('rcurly', '}', []), ('lcurly', '{', []),
    ('end_clause', 'end of clause expected', []),
    ('bad_term', 'term expected', []), ('bad_op', 'operator expected', []),
    ('bad_args', ', or ) expected', []), ('bad_list', ', | or ] expected', []),
    ('bad_curly', '} expected', []), ('bad_paren', ') expected', []),
    ('bad_quote', 'unterminated quoted text', []),
    ('bad_escape', 'bad escape sequence', []), ('bad_char', 'illegal character', []),
    ('bad_number', 'bad number', []), ('too_long', 'name too long', []),
    ('too_many_vars', 'too many variables', []),
    ('op_clash', 'operator priority clash', []),
    ('dollar_clause', '$clause', []), ('dollar_ref', '$ref', []),
    ('dollar_toplevel', '$toplevel', []),
    ('chars', 'chars', []), ('codes', 'codes', []),
    ('runtime', 'runtime', []), ('inferences', 'inferences', []),
    ('dollar_dcg', '$dcg', []), ('static', 'static', []),
    # builtins' names
    ('p_var', 'var', []), ('p_nonvar', 'nonvar', []), ('p_compare', 'compare', []),
    ('p_functor', 'functor', []), ('p_arg', 'arg', []), ('p_copy_term', 'copy_term', []),
    ('p_term_variables', 'term_variables', []), ('p_atom_codes', 'atom_codes', []),
    ('p_atom_chars', 'atom_chars', []), ('p_char_code', 'char_code', []),
    ('p_number_codes', 'number_codes', []), ('p_number_chars', 'number_chars', []),
    ('print', 'print', []), ('writeq', 'writeq', []), ('wcanon', 'write_canonical', []),
    ('p_write_term', 'write_term', []), ('p_nl', 'nl', []), ('p_put_char', 'put_char', []),
    ('p_get_char', 'get_char', []), ('p_peek_char', 'peek_char', []),
    ('p_read_term', 'read_term', []), ('p_close', 'close', []),
    ('p_set_input', 'set_input', []), ('p_set_output', 'set_output', []),
    ('p_current_input', 'current_input', []), ('p_current_output', 'current_output', []),
    ('p_flush_output', 'flush_output', []), ('p_line', '$line', []), ('p_argv', '$argv', []),
    ('p_assert', 'assert', []), ('p_asserta', 'asserta', []), ('p_assertz', 'assertz', []),
    ('p_add_clause', '$add_clause', []), ('p_new_consult', '$new_consult', []),
    ('p_clauses', '$clauses', []), ('p_erase', '$erase', []), ('p_dynamic', '$dynamic', []),
    ('p_op', '$op', []), ('p_op_atoms', '$op_atoms', []), ('p_op_defs', '$op_defs', []),
    ('p_preds', '$preds', []), ('p_stats', '$stats', []), ('p_now', '$now', []),
    ('p_choice', '$choice', []), ('p_is_builtin', '$is_builtin', []),
    ('p_atom_stream', '$atom_stream', []),
]


def enc(ops):
    pre = inf = post = 0
    for p, t in ops:
        v = p | T[t] << 12
        if t in ('fy', 'fx'):
            pre = v
        elif t in ('xf', 'yf'):
            post = v
        else:
            inf = v
    return pre | inf << 16 | post << 32


def asc(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def main():
    out = open(sys.argv[1], 'w')
    w = out.write
    w('; atoms.s: generated by lang/prolog/mkatoms.py (do not edit)\n')
    w('        .far                            ; the image\'s far section: the arena\n')
    w('        .align 8                        ; records are 8-byte aligned\n')
    w('at_first:                               ; the first predefined atom\n')
    seen, names = set(), set()
    for lab, name, ops in ATOMS:
        assert lab not in seen, lab
        assert name not in names, name
        seen.add(lab)
        names.add(name)
        n = len(name.encode())
        w(f'at_{lab}:\n')
        w(f'        .dword 0, {n}, 0, {enc(ops):#x}, 0 ; next, length, predicates, operators, spare\n')
        w(f'        .ascii {asc(name)}'.ljust(40) + f'; the name {name}\n')
        w('        .align 8                        ; next record\n')
    w('at_last:                                ; one past the last predefined atom\n')
    out.close()


main()
