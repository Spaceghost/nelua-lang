/* No CRT: Linux x86-64 supplies only process loading and the exit syscall.
 * SPDX-License-Identifier: MIT */
#include "cases.h"
__attribute__((noreturn, force_align_arg_pointer)) void _start(void)
{
    long status = run_cases();
    __asm__ volatile("syscall" : : "a"(60L), "D"(status) : "rcx", "r11", "memory");
    __builtin_unreachable();
}
