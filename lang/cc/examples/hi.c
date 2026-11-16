/* hi.c: the first C program for Strata.
   In StrataOS:  cc /src/hi.c   and then   hi  */
#include <stdio.h>

int main(int argc, char **argv)
{
    printf("Hello from C on Strata");
    if (argc > 1)
        printf(", %s", argv[1]);
    printf("!\n");
    return 0;
}
