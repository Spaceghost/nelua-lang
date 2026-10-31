#ifndef NELUA_FREESTANDING_KERNEL_H
#define NELUA_FREESTANDING_KERNEL_H
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Host supplies writable storage for one uint32_t. Failure leaves it intact. */
bool nelua_checked_add(uint32_t a, uint32_t b, uint32_t *out);
#ifdef __cplusplus
}
#endif
#endif
