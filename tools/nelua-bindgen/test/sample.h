#ifndef SAMPLE_H
#define SAMPLE_H
#include <stddef.h>
#include <stdint.h>

#define SAMPLE_VERSION 3
#define SAMPLE_FLAG_A 0x10u
#define SAMPLE_RATIO 1.5
#define SAMPLE_NAME "sample"
#define SAMPLE_ALIAS SAMPLE_VERSION
#define SAMPLE_SQUARE(x) ((x) * (x))
#define SAMPLE_COMPUTED (SAMPLE_VERSION + 1)
#define SAMPLE_GREETING "hi\n\"there\"\x41\101\t\\"
#define SAMPLE_PATH "a" "/" "b"
#define SAMPLE_WIDE L"wide"
#define SAMPLE_DEFAULT_COLOR SAMPLE_GREEN
#define SAMPLE_ANON_ALIAS SAMPLE_ANON_ONE
#define SAMPLE_MISSING_ALIAS SAMPLE_NOT_EMITTED
#define SAMPLE_CHAIN_A SAMPLE_CHAIN_B
#define SAMPLE_CHAIN_B SAMPLE_CHAIN_C
#define SAMPLE_CHAIN_C 9
#define SAMPLE_MISSING_CHAIN SAMPLE_MISSING_ALIAS

typedef enum sample_color { SAMPLE_RED = 0, SAMPLE_GREEN = 1, SAMPLE_BLUE = 2 } sample_color;
enum { SAMPLE_ANON_ONE = 1, SAMPLE_ANON_TWO = 2 };

struct sample_opaque;
typedef struct sample_point { int32_t x; int32_t y; } sample_point;
struct sample_rect { sample_point min; sample_point max; const char *label; };
typedef union sample_value { int32_t i; double d; uint8_t bytes[8]; } sample_value;
typedef struct { unsigned flags : 3; int id; } sample_bits;
typedef int (*sample_callback)(void *ctx, const sample_point *p);
typedef struct sample_node { struct sample_node *next; int value; } sample_node;
typedef struct sample_ops {
  int (*compare)(const sample_point *a, const sample_point *b);
  void (*describe)(const struct sample_rect *r, char *buf, size_t n);
  const char *const *names;
} sample_ops;
typedef void (*sample_log_fn)(const char *msg, const sample_ops *ops);
typedef struct sample_handle_s { int fd; } sample_handle;
struct sample_ctx_s { int n; };
typedef struct sample_ctx_s sample_ctx;

extern int sample_counter;
extern sample_node sample_node_root;

int sample_add(int a, int b);
size_t sample_strlen(const char *s);
const char *sample_name(void);
void sample_fill(sample_point *out, int32_t x, int32_t y);
int32_t sample_area(const struct sample_rect *r);
double sample_sum(const double *values, size_t count);
int sample_each(const sample_node *head, sample_callback cb, void *ctx);
struct sample_opaque *sample_open(const char *path, int end);
void sample_close(struct sample_opaque *h);
int sample_printf(const char *fmt, ...);
void sample_copy(uint8_t dst[16], const uint8_t *src);
int sample_run(const sample_ops *ops, sample_log_fn log, const sample_point *a, const sample_point *b);
sample_handle *sample_handle_open(int fd);
int sample_handle_fd(const sample_handle *h);
void sample_handle_close(struct sample_handle_s *h);
int sample_ctx_count(const sample_ctx *c, struct sample_ctx_s *out);
sample_node sample_node_make(int value);
int sample_node_value(sample_node n);
int sample_bits_id(const sample_bits *b);
#endif
