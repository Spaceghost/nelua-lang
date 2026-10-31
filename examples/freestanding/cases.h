#ifndef NELUA_FREESTANDING_CASES_H
#define NELUA_FREESTANDING_CASES_H
#include "kernel.h"
static int run_cases(void)
{
    uint32_t value = 7;
    if (!nelua_checked_add(20, 22, &value) || value != 42) return 1;
    if (!nelua_checked_add(UINT32_MAX, 0, &value) || value != UINT32_MAX) return 2;
    value = 7;
    if (nelua_checked_add(UINT32_MAX, 1, &value) || value != 7) return 3;
    if (nelua_checked_add(1, 2, (uint32_t *)0)) return 4;
    if (!nelua_checked_add(0, 0, &value) || value != 0) return 5;
    return 0;
}
#endif
