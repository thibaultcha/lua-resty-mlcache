package = "lua-resty-mlcache"
version = "2.0.1-1"
source = {
  url = "git://github.com/thibaultcha/lua-resty-mlcache",
  tag = "2.0.1"
}
description = {
  summary  = "Multi-level caching library for OpenResty",
  detailed = [[
    This library combines the power of lua_shared_dict memory zones,
    lua-resty-lrucache, and lua-resty-lock in a single, easy-to-use module.

    A get() function acts as a "get or set" method, and can cache a value
    from any I/O operation (like a database read). Your I/O operations will be
    invoked from a single worker via lua-resty-lock, and will prevent your
    database from undergoing a dogpile effect.

    Cached values will be stored in a lua_shared_dict memory zone of your
    choice, and the most frequently accessed values will be kept in the Lua VM,
    under a lua-resty-lrucache instance to optimize your hot code paths.

    Additionally, this module supports:

    - Negative caching
    - TTLs and negative TTLs
    - Custom LRU implementations (like resty.lrucache.pureffi)
    - A key/value API with set()/peek()/delete() (provided a few minor drawbacks)
  ]],
  homepage = "https://github.com/thibaultcha/lua-resty-mlcache",
  license  = "MIT"
}
build = {
  type    = "builtin",
  modules = {
    ["resty.ipc"]     = "lib/resty/mlcache/ipc.lua",
    ["resty.mlcache"] = "lib/resty/mlcache.lua"
  }
}
