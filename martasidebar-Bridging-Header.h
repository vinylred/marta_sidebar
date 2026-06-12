#import "lauxlib.h"

// Swift cannot see Lua's #define macros, so re-expose the ones we need as
// real C constants. These mirror lua.h / lauxlib.h.

static const int LUA_REGISTRYINDEX_COMPAT = LUA_REGISTRYINDEX;
static const int LUA_NOREF_COMPAT         = LUA_NOREF;
static const int LUA_OK_COMPAT            = LUA_OK;

static const int LUA_TNIL_COMPAT           = LUA_TNIL;
static const int LUA_TFUNCTION_COMPAT      = LUA_TFUNCTION;
static const int LUA_TLIGHTUSERDATA_COMPAT = LUA_TLIGHTUSERDATA;
static const int LUA_TSTRING_COMPAT        = LUA_TSTRING;

// lua_pcall / lua_pop / lua_tostring are macros; wrap them so Swift can call
// them as real functions.

static inline int lua_pcall_compat(lua_State *L, int nargs, int nresults, int errfunc) {
    return lua_pcall(L, nargs, nresults, errfunc);
}

static inline void lua_pop_compat(lua_State *L, int n) {
    lua_pop(L, n);
}

static inline const char *lua_tostring_compat(lua_State *L, int idx) {
    return lua_tostring(L, idx);
}

static inline double lua_tonumber_compat(lua_State *L, int idx) {
    return (double)lua_tonumber(L, idx);
}

static inline int lua_isnumber_compat(lua_State *L, int idx) {
    return lua_isnumber(L, idx);
}
