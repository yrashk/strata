/* JSON for the debug protocol (doc/debug-protocol.md): a small parser into
 * a tree and a writer into a growing buffer. Header-only, no dependencies;
 * used by the debug engine (emu/debug.c) and by strata-dbg (dbg/).
 *
 * The protocol keeps 64-bit values exact by sending them as strings of
 * hexadecimal ("0x..."): json_u64() reads either form. */
#ifndef STRATA_JSON_H
#define STRATA_JSON_H

#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------ the tree */

enum { J_NULL, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ };

typedef struct JVal JVal;
struct JVal {
  int t;
  double n;      /* J_NUM, J_BOOL (0 / 1) */
  char *s;       /* J_STR: NUL-terminated (and len bytes) */
  size_t len;
  char *key;     /* a member of an object: its name */
  JVal *kid;     /* J_ARR, J_OBJ: the first element */
  JVal *next;    /* the next element of the parent */
};

typedef struct { const char *p, *end; int bad; } JParse;

static inline void json_ws(JParse *q) {
  while (q->p < q->end && (*q->p == ' ' || *q->p == '\t' || *q->p == '\n' || *q->p == '\r')) q->p++;
}

static inline JVal *json_new(int t) {
  JVal *v = (JVal *)calloc(1, sizeof *v);
  if (!v) { perror("json"); exit(2); }
  v->t = t;
  return v;
}

static inline void json_free(JVal *v) {
  while (v) {
    JVal *n = v->next;
    json_free(v->kid);
    free(v->s);
    free(v->key);
    free(v);
    v = n;
  }
}

/* A string at q->p (after the opening quote): its bytes, \u escapes as UTF-8. */
static inline char *json_str_body(JParse *q, size_t *len) {
  size_t cap = 32, n = 0;
  char *s = (char *)malloc(cap);
  while (q->p < q->end && *q->p != '"') {
    unsigned c = (unsigned char)*q->p++;
    if (c == '\\' && q->p < q->end) {
      c = (unsigned char)*q->p++;
      switch (c) {
      case 'n': c = '\n'; break;
      case 't': c = '\t'; break;
      case 'r': c = '\r'; break;
      case 'b': c = '\b'; break;
      case 'f': c = '\f'; break;
      case 'u': {
        unsigned u = 0;
        for (int i = 0; i < 4 && q->p < q->end; i++) {
          char h = *q->p++;
          u = u << 4 | (unsigned)(h <= '9' ? h - '0' : (h | 32) - 'a' + 10);
        }
        if (n + 4 >= cap) s = (char *)realloc(s, cap *= 2);
        if (u < 0x80) s[n++] = (char)u;
        else if (u < 0x800) { s[n++] = (char)(0xc0 | u >> 6); s[n++] = (char)(0x80 | (u & 63)); }
        else { s[n++] = (char)(0xe0 | u >> 12); s[n++] = (char)(0x80 | (u >> 6 & 63)); s[n++] = (char)(0x80 | (u & 63)); }
        continue;
      }
      default: break; /* \" \\ \/ */
      }
    }
    if (n + 1 >= cap) s = (char *)realloc(s, cap *= 2);
    s[n++] = (char)c;
  }
  if (q->p < q->end) q->p++; else q->bad = 1;
  s[n] = 0;
  *len = n;
  return s;
}

static inline JVal *json_value(JParse *q, int depth) {
  json_ws(q);
  if (q->p >= q->end || depth > 64) { q->bad = 1; return NULL; }
  char c = *q->p;
  if (c == '{' || c == '[') {
    JVal *v = json_new(c == '{' ? J_OBJ : J_ARR), **tail = &v->kid;
    q->p++;
    json_ws(q);
    if (q->p < q->end && *q->p == (c == '{' ? '}' : ']')) { q->p++; return v; }
    for (;;) {
      char *key = NULL;
      if (c == '{') {
        json_ws(q);
        if (q->p >= q->end || *q->p != '"') { q->bad = 1; return v; }
        q->p++;
        size_t kl;
        key = json_str_body(q, &kl);
        json_ws(q);
        if (q->p >= q->end || *q->p != ':') { free(key); q->bad = 1; return v; }
        q->p++;
      }
      JVal *e = json_value(q, depth + 1);
      if (!e) { free(key); return v; }
      e->key = key;
      *tail = e;
      tail = &e->next;
      json_ws(q);
      if (q->p < q->end && *q->p == ',') { q->p++; continue; }
      if (q->p < q->end && *q->p == (c == '{' ? '}' : ']')) { q->p++; return v; }
      q->bad = 1;
      return v;
    }
  }
  if (c == '"') {
    JVal *v = json_new(J_STR);
    q->p++;
    v->s = json_str_body(q, &v->len);
    return v;
  }
  if (!strncmp(q->p, "true", 4)) { q->p += 4; JVal *v = json_new(J_BOOL); v->n = 1; return v; }
  if (!strncmp(q->p, "false", 5)) { q->p += 5; return json_new(J_BOOL); }
  if (!strncmp(q->p, "null", 4)) { q->p += 4; return json_new(J_NULL); }
  char *e;
  double d = strtod(q->p, &e);
  if (e == q->p) { q->bad = 1; return NULL; }
  q->p = e;
  JVal *v = json_new(J_NUM);
  v->n = d;
  return v;
}

/* Parses one JSON text; NULL if it is not one. Free with json_free(). */
static inline JVal *json_parse(const char *s, size_t n) {
  JParse q = {s, s + n, 0};
  JVal *v = json_value(&q, 0);
  if (q.bad) { json_free(v); return NULL; }
  return v;
}

static inline JVal *json_get(const JVal *o, const char *key) {
  if (!o || o->t != J_OBJ) return NULL;
  for (JVal *k = o->kid; k; k = k->next)
    if (k->key && !strcmp(k->key, key)) return k;
  return NULL;
}

static inline const char *json_str(const JVal *v, const char *def) { return v && v->t == J_STR ? v->s : def; }
static inline double json_num(const JVal *v, double def) {
  if (!v) return def;
  if (v->t == J_NUM || v->t == J_BOOL) return v->n;
  if (v->t == J_STR) return strtod(v->s, NULL);
  return def;
}
static inline bool json_bool(const JVal *v, bool def) {
  if (!v) return def;
  if (v->t == J_BOOL || v->t == J_NUM) return v->n != 0;
  return def;
}
/* a number, or a string of digits ("0x..." hexadecimal) */
static uint64_t json_u64(const JVal *v, uint64_t def) {
  if (!v) return def;
  if (v->t == J_NUM) return v->n < 0 ? (uint64_t)(int64_t)v->n : (uint64_t)v->n;
  if (v->t == J_STR && v->s[0]) return v->s[0] == '-' ? (uint64_t)strtoll(v->s, NULL, 0) : strtoull(v->s, NULL, 0);
  return def;
}
static inline int json_int(const JVal *v, int def) { return v ? (int)json_u64(v, (uint64_t)def) : def; }

/* ------------------------------------------------------------ the writer */

/* Output goes into a growing buffer. Members and elements are separated
 * automatically: jw_* calls with a key write a member, with NULL an
 * element of the array being written. */
typedef struct {
  char *p;
  size_t n, cap;
  int depth;
  unsigned char first[64]; /* nothing written yet at this depth */
} JW;

static inline void jw_raw(JW *w, const char *s, size_t n) {
  if (w->n + n + 1 > w->cap) {
    w->cap = (w->n + n + 1) * 2 + 256;
    w->p = (char *)realloc(w->p, w->cap);
    if (!w->p) { perror("json"); exit(2); }
  }
  memcpy(w->p + w->n, s, n);
  w->n += n;
  w->p[w->n] = 0;
}
static inline void jw_puts(JW *w, const char *s) { jw_raw(w, s, strlen(s)); }
static inline void jw_printf(JW *w, const char *fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  if (n < (int)sizeof buf) { jw_raw(w, buf, (size_t)n); return; }
  char *big = (char *)malloc((size_t)n + 1);
  va_start(ap, fmt);
  vsnprintf(big, (size_t)n + 1, fmt, ap);
  va_end(ap);
  jw_raw(w, big, (size_t)n);
  free(big);
}
static inline void jw_reset(JW *w) { w->n = 0; w->depth = 0; w->first[0] = 1; if (w->p) w->p[0] = 0; }

static inline void jw_esc(JW *w, const char *s, size_t n) {
  jw_raw(w, "\"", 1);
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)s[i];
    if (c == '"' || c == '\\') { char e[2] = {'\\', (char)c}; jw_raw(w, e, 2); }
    else if (c == '\n') jw_raw(w, "\\n", 2);
    else if (c == '\t') jw_raw(w, "\\t", 2);
    else if (c == '\r') jw_raw(w, "\\r", 2);
    else if (c < 0x20 || c >= 0x7f) jw_printf(w, "\\u%04x", c); /* bytes, not UTF-8: one escape each */
    else jw_raw(w, (const char *)&c, 1);
  }
  jw_raw(w, "\"", 1);
}

/* the separator and the key of the next member or element */
static inline void jw_key(JW *w, const char *key) {
  if (!w->first[w->depth]) jw_raw(w, ",", 1);
  w->first[w->depth] = 0;
  if (key) { jw_esc(w, key, strlen(key)); jw_raw(w, ":", 1); }
}
static inline void jw_open(JW *w, const char *key, char c) {
  jw_key(w, key);
  jw_raw(w, &c, 1);
  if (w->depth < 63) w->depth++;
  w->first[w->depth] = 1;
}
static inline void jw_obj(JW *w, const char *key) { jw_open(w, key, '{'); }
static inline void jw_arr(JW *w, const char *key) { jw_open(w, key, '['); }
static inline void jw_end(JW *w, char c) { jw_raw(w, &c, 1); if (w->depth) w->depth--; }
static inline void jw_oend(JW *w) { jw_end(w, '}'); }
static inline void jw_aend(JW *w) { jw_end(w, ']'); }
static inline void jw_int(JW *w, const char *key, long long v) { jw_key(w, key); jw_printf(w, "%lld", v); }
static inline void jw_uint(JW *w, const char *key, unsigned long long v) { jw_key(w, key); jw_printf(w, "%llu", v); }
static inline void jw_hex(JW *w, const char *key, uint64_t v) { jw_key(w, key); jw_printf(w, "\"0x%llx\"", (unsigned long long)v); }
static inline void jw_bool(JW *w, const char *key, bool v) { jw_key(w, key); jw_puts(w, v ? "true" : "false"); }
static inline void jw_null(JW *w, const char *key) { jw_key(w, key); jw_puts(w, "null"); }
static inline void jw_str(JW *w, const char *key, const char *s) { jw_key(w, key); jw_esc(w, s ? s : "", s ? strlen(s) : 0); }
static inline void jw_strn(JW *w, const char *key, const char *s, size_t n) { jw_key(w, key); jw_esc(w, s, n); }
/* a value already written as JSON */
static inline void jw_json(JW *w, const char *key, const char *json) { jw_key(w, key); jw_puts(w, json); }

#endif
