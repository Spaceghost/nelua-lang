#ifndef NULLABLE_H
#define NULLABLE_H
#include <stddef.h>

typedef struct nul_item { int id; } nul_item;
typedef nul_item *nul_item_ref;

nul_item *nul_find(int id);                 /* NULL when not found */
const char *nul_name(const nul_item *item); /* NULL for an anonymous item */
nul_item_ref nul_first(void);               /* a typedef'd pointer return is a pointer too */
int nul_count(void);                        /* matched by the regex but not a pointer: bound as is */
nul_item *nul_lookup(const char *fmt, ...); /* variadic: cannot be wrapped, bound as is */
nul_item *nul_make(int id);                 /* not matched: stays `*nul_item` */
int (*nul_callback(void))(int);             /* unnamed function pointer: the return type is named before `?` */
#endif
