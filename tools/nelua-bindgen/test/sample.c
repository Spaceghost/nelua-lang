#include "sample.h"
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
struct sample_opaque { int fd; };
int sample_counter = 7;
sample_node sample_node_root = { 0, 1 };
int sample_add(int a, int b) { return a + b; }
size_t sample_strlen(const char *s) { return strlen(s); }
const char *sample_name(void) { return SAMPLE_NAME; }
void sample_fill(sample_point *out, int32_t x, int32_t y) { out->x = x; out->y = y; }
int32_t sample_area(const struct sample_rect *r) { return (r->max.x - r->min.x) * (r->max.y - r->min.y); }
double sample_sum(const double *values, size_t count) { double s = 0; for (size_t i = 0; i < count; i++) s += values[i]; return s; }
int sample_each(const sample_node *head, sample_callback cb, void *ctx) {
  int n = 0; for (const sample_node *it = head; it; it = it->next) { sample_point p = { it->value, n }; n += cb(ctx, &p); } return n; }
struct sample_opaque *sample_open(const char *path, int end) { struct sample_opaque *h = malloc(sizeof *h); h->fd = (int)strlen(path) + end; return h; }
void sample_close(struct sample_opaque *h) { free(h); }
int sample_printf(const char *fmt, ...) { va_list ap; va_start(ap, fmt); int n = vprintf(fmt, ap); va_end(ap); return n; }
void sample_copy(uint8_t dst[16], const uint8_t *src) { memcpy(dst, src, 16); }
int sample_run(const sample_ops *ops, sample_log_fn log, const sample_point *a, const sample_point *b) { if (log) log("run", ops); return ops->compare(a, b); }
sample_handle *sample_handle_open(int fd) { sample_handle *h = malloc(sizeof *h); h->fd = fd; return h; }
int sample_handle_fd(const sample_handle *h) { return h->fd; }
void sample_handle_close(struct sample_handle_s *h) { free(h); }
int sample_ctx_count(const sample_ctx *c, struct sample_ctx_s *out) { if (!c) return 0; if (out) out->n = c->n; return c->n; }
sample_node sample_node_make(int value) { sample_node n = { 0, value }; return n; }
int sample_node_value(sample_node n) { return n.value; }
int sample_bits_id(const sample_bits *b) { return b ? b->id : -1; }
