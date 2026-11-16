/* calc.c: a larger example for cc: an expression evaluator.
 *
 * It reads expressions, one per line, from its arguments or from standard
 * input, parses them into a tree allocated with malloc, prints the tree in
 * postfix and its value. It uses most of what the compiler has: structures
 * and unions, enumerations, pointers to functions, recursion, switch,
 * variadic functions, string functions and the heap.
 *
 * In StrataOS:   cc /src/calc.c
 *                calc "1 + 2 * (3 - 4)"       or      echo 6 * 7 | calc
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <ctype.h>

enum kind { NUM, NEG, ADD, SUB, MUL, DIV, MOD };

struct node {
    enum kind kind;
    union {
        long value;                     /* NUM */
        struct { struct node *l, *r; } kids;   /* the operators (NEG: only l) */
    } u;
};

static const char *src;                 /* the text being parsed */
static int failed;                      /* an error was reported for this line */
static int nodes;                       /* nodes allocated for this line */

static void fail(const char *fmt, ...)
{
    va_list ap;

    if (failed)
        return;
    failed = 1;
    va_start(ap, fmt);
    printf("error: ");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
}

static struct node *node(enum kind kind, struct node *l, struct node *r)
{
    struct node *n = malloc(sizeof *n);

    if (!n) {
        fail("out of memory after %d nodes", nodes);
        exit(1);
    }
    nodes++;
    n->kind = kind;
    n->u.kids.l = l;
    n->u.kids.r = r;
    return n;
}

static int peek(void)
{
    while (isspace(*src))
        src++;
    return *src;
}

static struct node *sum(void);

static struct node *primary(void)
{
    struct node *n;
    int c = peek();

    if (isdigit(c)) {
        n = node(NUM, 0, 0);
        n->u.value = strtol(src, (char **)&src, 0);
        return n;
    }
    if (c == '-') {
        src++;
        return node(NEG, primary(), 0);
    }
    if (c == '(') {
        src++;
        n = sum();
        if (peek() != ')')
            fail("missing ) at \"%s\"", src);
        else
            src++;
        return n;
    }
    fail("unexpected \"%s\"", *src ? src : "end of line");
    return node(NUM, 0, 0);
}

static struct node *product(void)
{
    struct node *n = primary();

    for (;;) {
        switch (peek()) {
        case '*': src++; n = node(MUL, n, primary()); break;
        case '/': src++; n = node(DIV, n, primary()); break;
        case '%': src++; n = node(MOD, n, primary()); break;
        default: return n;
        }
    }
}

static struct node *sum(void)
{
    struct node *n = product();

    while (peek() == '+' || peek() == '-')
        n = node(*src++ == '+' ? ADD : SUB, n, product());
    return n;
}

static long add(long a, long b) { return a + b; }
static long sub(long a, long b) { return a - b; }
static long mul(long a, long b) { return a * b; }
static long quo(long a, long b) { if (!b) { fail("division by zero"); return 0; } return a / b; }
static long rem(long a, long b) { if (!b) { fail("division by zero"); return 0; } return a % b; }

static const struct { char name; long (*fn)(long, long); } ops[] = {
    [ADD] = { '+', add }, [SUB] = { '-', sub }, [MUL] = { '*', mul },
    [DIV] = { '/', quo }, [MOD] = { '%', rem },
};

static long eval(const struct node *n)
{
    switch (n->kind) {
    case NUM: return n->u.value;
    case NEG: return -eval(n->u.kids.l);
    default:  return ops[n->kind].fn(eval(n->u.kids.l), eval(n->u.kids.r));
    }
}

static void postfix(const struct node *n)
{
    if (n->kind == NUM) {
        printf("%ld ", n->u.value);
    } else if (n->kind == NEG) {
        postfix(n->u.kids.l);
        printf("neg ");
    } else {
        postfix(n->u.kids.l);
        postfix(n->u.kids.r);
        printf("%c ", ops[n->kind].name);
    }
}

static void release(struct node *n)
{
    if (n->kind != NUM) {
        release(n->u.kids.l);
        if (n->kind != NEG)
            release(n->u.kids.r);
    }
    free(n);
}

static void line(const char *text)
{
    struct node *n;
    long v;

    src = text;
    failed = 0;
    nodes = 0;
    if (!peek())
        return;
    n = sum();
    if (peek())
        fail("unexpected \"%s\"", src);
    v = eval(n);
    if (!failed) {
        postfix(n);
        printf("= %ld  (%d nodes)\n", v, nodes);
    }
    release(n);
}

int main(int argc, char **argv)
{
    char buf[128];
    int i;

    if (argc > 1) {
        buf[0] = 0;
        for (i = 1; i < argc; i++) {    /* the shell split the expression at its spaces */
            strcat(buf, argv[i]);
            strcat(buf, " ");
        }
        line(buf);
        return failed;
    }
    while (fgets(buf, sizeof buf, stdin))
        line(buf);
    return 0;
}
