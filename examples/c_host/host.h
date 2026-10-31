#ifndef NELUA_C_HOST_H
#define NELUA_C_HOST_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct host_buffer {
  unsigned char *data;
  size_t length;
  size_t capacity;
} host_buffer;

/* Input/output must not overlap. Output may be partial on failure;
 * reset length before retrying. The host guarantees valid UTF8 input. */
bool host_json_string(host_buffer *buffer, unsigned char *data, size_t length);
bool host_decimal_i64(host_buffer *buffer, int64_t value);
#endif
