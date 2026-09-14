// SPDX-License-Identifier: MIT
// Version-pinned native CodeGen bridge; no guest source substitution.
#include "lua.h"
#include "Luau/CodeGen.h"
#include "lstate.h"
#include <cstdint>
#include <cstring>
extern "C" int cg_create(lua_State* L) noexcept {
    try {
        if (!Luau::CodeGen::isSupported()) return -1;
        // Machine-code allocation is separate from the 2 MiB guest VM heap.
        Luau::CodeGen::create(L, 64 * 1024, 4 * 1024 * 1024, nullptr, nullptr);
        return Luau::CodeGen::isNativeExecutionEnabled(L) ? 0 : -2;
    } catch (...) { return -3; }
}
extern "C" int cg_compile(lua_State* L, int index, uint32_t* functions, size_t* bytes) noexcept {
    try {
        Luau::CodeGen::CompilationStats stats;
        const auto result = Luau::CodeGen::compile(L, index, 0u, &stats);
        *functions = stats.functionsCompiled;
        *bytes = stats.nativeCodeSizeBytes + stats.nativeDataSizeBytes + stats.nativeMetadataSizeBytes;
        return result.hasErrors() || stats.functionsCompiled == 0 ? -1 : 0;
    } catch (...) { return -2; }
}
// Only enabled in qualification processes. A compiled-code flag alone is not
// evidence that an application's instructions ran through the native path.
extern "C" int cg_in_application(lua_State* L) noexcept {
    auto* ci = L->ci;
    if (!ci || !(ci->flags & LUA_CALLINFO_NATIVE) || !isLua(ci)) return 0;
    // CallInfo::p is only maintained when the pinned LuauCIProto flag is on.
    // The closure's Proto is valid in either mode; do not read optional cache data.
    Proto* proto = clvalue(ci->func)->l.p;
    return proto && proto->source && std::strcmp(getstr(proto->source), "@app.lua") == 0;
}
extern "C" void cg_enable(lua_State* L, int enabled) noexcept {
    Luau::CodeGen::setNativeExecutionEnabled(L, enabled != 0);
}
