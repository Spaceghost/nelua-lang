#include "host.h"
#include <stdio.h>
#include <string.h>

/* The host supplies both the program entrypoint and all output storage. */
int main(void) {
  unsigned char storage[128];
  host_buffer buffer = {storage, 0, sizeof(storage)};
  unsigned char sample[] = {'"', '\\', '\n', 0, 31, 0xc3, 0xa9};
  static const unsigned char expected[] = "\"\\\"\\\\\\u000a\\u0000\\u001f\xc3\xa9\"";

  if (!host_json_string(&buffer, sample, sizeof(sample)) ||
      buffer.length != sizeof(expected) - 1 ||
      memcmp(storage, expected, sizeof(expected) - 1) != 0) return 1;
  buffer.length = 0;
  if (!host_json_string(&buffer, NULL, 0) || buffer.length != 2 ||
      memcmp(storage, "\"\"", 2) != 0) return 2;
  if (host_json_string(&buffer, NULL, 1)) return 3;

  buffer.length = 0;
  if (!host_decimal_i64(&buffer, INT64_MIN) || buffer.length != 20 ||
      memcmp(storage, "-9223372036854775808", 20) != 0) return 4;
  buffer.length = 0;
  if (!host_decimal_i64(&buffer, INT64_MAX) || buffer.length != 19 ||
      memcmp(storage, "9223372036854775807", 19) != 0) return 5;
  buffer.length = 0;
  if (!host_decimal_i64(&buffer, 0) || buffer.length != 1 || storage[0] != '0') return 6;

  buffer.length = 0;
  buffer.capacity = 1;
  storage[1] = 0xa5;
  if (host_json_string(&buffer, sample, sizeof(sample)) ||
      buffer.length > buffer.capacity || storage[1] != 0xa5) return 7;
  buffer.length = 2;
  if (host_decimal_i64(&buffer, 1)) return 8;
  if (host_decimal_i64(NULL, 1)) return 9;

  puts("runtime-free C host: pass");
  return 0;
}
