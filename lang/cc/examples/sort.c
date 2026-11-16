/* sort.c: qsort and bsearch, which the library has as C source: cc compiles
 * them with the program that calls them (lang/cc/lib/src).
 *
 * In StrataOS:   cc /src/sort.c
 *                sort pear apple fig      (or no arguments: its own list)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct city { const char *name; int people; };      /* thousands */

struct city cities[] = {
    { "Vancouver", 662 }, { "Lviv", 717 }, { "Oslo", 709 }, { "Porto", 232 },
    { "Kyoto", 1464 }, { "Quito", 1763 }, { "Graz", 291 }, { "Hobart", 247 },
};

int by_name(const void *a, const void *b)
{
    return strcmp(((const struct city *)a)->name, ((const struct city *)b)->name);
}

int by_people(const void *a, const void *b)
{
    return ((const struct city *)b)->people - ((const struct city *)a)->people;
}

int by_word(const void *a, const void *b)
{
    return strcmp(*(char *const *)a, *(char *const *)b);
}

int by_int(const void *a, const void *b)
{
    int x = *(const int *)a, y = *(const int *)b;
    return x < y ? -1 : x > y;
}

int main(int argc, char **argv)
{
    int n = sizeof cities / sizeof cities[0], i, v[500], bad = 0;
    struct city key, *c;

    if (argc > 1) {
        qsort(argv + 1, argc - 1, sizeof argv[0], by_word);
        for (i = 1; i < argc; i++) printf("%s\n", argv[i]);
        return 0;
    }
    qsort(cities, n, sizeof cities[0], by_people);
    for (i = 0; i < n; i++) printf("%-10s %5d\n", cities[i].name, cities[i].people);
    qsort(cities, n, sizeof cities[0], by_name);
    for (i = 0; i < n; i++) printf("%s%c", cities[i].name, i < n - 1 ? ' ' : '\n');
    key.name = "Oslo";
    c = bsearch(&key, cities, n, sizeof cities[0], by_name);
    printf("Oslo: %d\n", c ? c->people : -1);
    key.name = "Paris";
    printf("Paris: %s\n", bsearch(&key, cities, n, sizeof cities[0], by_name) ? "found" : "not there");

    srand(1);
    for (i = 0; i < 500; i++) v[i] = rand() % 1000;
    qsort(v, 500, sizeof v[0], by_int);
    for (i = 1; i < 500; i++) if (v[i - 1] > v[i]) bad++;
    for (i = 0; i < 500; i++) if (!bsearch(&v[i], v, 500, sizeof v[0], by_int)) bad++;
    printf("500 numbers sorted, each found again: %s\n", bad ? "no" : "yes");
    return bad != 0;
}
