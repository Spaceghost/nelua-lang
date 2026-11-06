#include "nullable.h"
#include <stdarg.h>
#include <stdlib.h>
static nul_item items[3] = {{1}, {2}, {3}};
nul_item *nul_find(int id) { return (id >= 1 && id <= 3) ? &items[id - 1] : NULL; }
const char *nul_name(const nul_item *item) { return (item && item->id == 1) ? "one" : NULL; }
nul_item_ref nul_first(void) { return &items[0]; }
int nul_count(void) { return 3; }
nul_item *nul_lookup(const char *fmt, ...) { va_list ap; va_start(ap, fmt); int id = va_arg(ap, int); va_end(ap); (void)fmt; return nul_find(id); }
nul_item *nul_make(int id) { nul_item *i = malloc(sizeof *i); i->id = id; return i; }
