#!/usr/bin/env python3
"""Syntax-checks every .lua file in PokerTimer/ and PokerProbe/ using the
real Lua interpreter (loadfile only -- does not execute anything, just
parses). This is the same check used throughout this project's development
history before every build.

Usage: python3 harness/syntax_check.py   (run from the project root)
"""
import ctypes
import ctypes.util
import glob
import os
import sys


def find_lua_lib():
    for name in ("lua5.4", "lua5.3", "lua"):
        path = ctypes.util.find_library(name)
        if path:
            return path
    # Common Debian/Ubuntu package name, not always found by find_library
    for candidate in ("liblua5.4.so.0", "liblua5.4.so", "liblua5.3.so.0"):
        try:
            ctypes.CDLL(candidate)
            return candidate
        except OSError:
            continue
    return None


def check_file(lib, path):
    lib.luaL_newstate.restype = ctypes.c_void_p
    lib.luaL_loadfilex.restype = ctypes.c_int
    lib.luaL_loadfilex.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.lua_tolstring.restype = ctypes.c_char_p
    lib.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    L = lib.luaL_newstate()
    rc = lib.luaL_loadfilex(L, path.encode(), None)
    if rc == 0:
        return None
    msg = lib.lua_tolstring(L, -1, None)
    return msg.decode(errors="replace") if msg else f"error code {rc}"


def main():
    lib_path = find_lua_lib()
    if not lib_path:
        print("No Lua library found on this system (tried lua5.4, lua5.3, lua).")
        print("Install one (e.g. `apt install lua5.4`) to run this check, or")
        print("syntax-check manually with `luac -p <file>` if that's available.")
        sys.exit(2)

    lib = ctypes.CDLL(lib_path)

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    targets = sorted(
        glob.glob(os.path.join(root, "PokerTimer", "*.lua"))
        + glob.glob(os.path.join(root, "PokerProbe", "*.lua"))
    )
    if not targets:
        print("No .lua files found under PokerTimer/ or PokerProbe/ -- "
              "run this from the project root.")
        sys.exit(2)

    failed = False
    for path in targets:
        err = check_file(lib, path)
        rel = os.path.relpath(path, root)
        if err is None:
            print(f"OK    {rel}")
        else:
            print(f"FAIL  {rel}\n      {err}")
            failed = True

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
