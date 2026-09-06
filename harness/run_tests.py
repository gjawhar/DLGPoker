#!/usr/bin/env python3
"""Runs harness/test.lua against the real Lua interpreter and reports
pass/fail. Remember: harness/core.lua is a SEPARATE COPY from
PokerTimer/core.lua -- sync it first, or you'll be testing stale code.

Usage:
    cp PokerTimer/core.lua harness/core.lua   # do this first, every time
    python3 harness/run_tests.py
"""
import ctypes
import ctypes.util
import os
import sys


def find_lua_lib():
    for name in ("lua5.4", "lua5.3", "lua"):
        path = ctypes.util.find_library(name)
        if path:
            return path
    for candidate in ("liblua5.4.so.0", "liblua5.4.so", "liblua5.3.so.0"):
        try:
            ctypes.CDLL(candidate)
            return candidate
        except OSError:
            continue
    return None


def main():
    lib_path = find_lua_lib()
    if not lib_path:
        print("No Lua library found on this system (tried lua5.4, lua5.3, lua).")
        print("Install one (e.g. `apt install lua5.4`) to run the harness.")
        sys.exit(2)

    lib = ctypes.CDLL(lib_path)
    lib.luaL_newstate.restype = ctypes.c_void_p
    lib.luaL_openlibs.argtypes = [ctypes.c_void_p]
    lib.luaL_loadfilex.restype = ctypes.c_int
    lib.luaL_loadfilex.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.lua_pcallk.restype = ctypes.c_int
    lib.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                                ctypes.c_int, ctypes.c_longlong, ctypes.c_void_p]
    lib.lua_tolstring.restype = ctypes.c_char_p
    lib.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]

    harness_dir = os.path.dirname(os.path.abspath(__file__))
    test_path = os.path.join(harness_dir, "test.lua")
    core_copy = os.path.join(harness_dir, "core.lua")
    core_live = os.path.join(os.path.dirname(harness_dir), "PokerTimer", "core.lua")

    if os.path.exists(core_copy) and os.path.exists(core_live):
        if open(core_copy).read() != open(core_live).read():
            print("WARNING: harness/core.lua differs from PokerTimer/core.lua.")
            print("         You're testing a STALE copy. Run:")
            print("         cp PokerTimer/core.lua harness/core.lua")
            print()

    # test.lua uses relative paths (dofile / loadfile-style local requires),
    # so run it from within harness/, matching how it's always been run
    # throughout this project's development.
    os.chdir(harness_dir)

    L = lib.luaL_newstate()
    lib.luaL_openlibs(L)
    rc = lib.luaL_loadfilex(L, b"test.lua", None)
    if rc != 0:
        print("LOAD ERROR:", lib.lua_tolstring(L, -1, None).decode(errors="replace"))
        sys.exit(1)
    rc2 = lib.lua_pcallk(L, 0, -1, 0, 0, None)
    if rc2 != 0:
        msg = lib.lua_tolstring(L, -1, None)
        print("RUNTIME ERROR:", msg.decode(errors="replace") if msg else f"code {rc2}")
        sys.exit(1)


if __name__ == "__main__":
    main()
