# lua-resty-mlcache

Fast multi-level key/value cache for OpenResty.

- Can cache scalar Lua types and tables.
- Provides automatic caching level fallbacks: LRU > shm > callback.
- Can invalidate cached entities accross workers via a custom IPC
  (inter-process communication) module.

The cache level hierarchy is:
1. **LRU**: Least Recently Used Lua-land cache using [lua-resty-lrucache] for
   fast lookup, without exhausting the workers Lua VM memory.
2. **shm**: `lua_shared_dict` object to avoid running callback if another
   worker already did.
3. **callback**: a custom function that will only be run by a single worker
   to avoid the dogpile effect (via [lua-resty-lock]).

### Table of Contents

- [Synopsis](#synopsis)
- [Methods](#methods)
- [Installation](#installation)
- [License](#license)

### Synopsis

```
    # nginx.conf

    http {
        # you do not need to configure the following line when you
        # use LuaRocks or opm.
        lua_package_path "/path/to/lua-resty-mlcache/lib/?.lua;;";

        lua_shared_dict cache 1m;

        init_by_lua_block {
            local resty_mlcache = require "resty.mlcache"

            local mlcache, err = resty_mlcache.new("cache", {
                lru_size = 500,    -- size of the Lua land LRU cache
                ttl      = 3600,   -- 1h ttl for hits
                neg_ttl  = 30,     -- 30s ttl for misses
            })
            if err then
                -- ...
            end

            -- we put our instance in the global table for brivety in
            -- this example, prefer an upvalue to one of your modules
            -- as recommended by ngx_lua

            _G.mlcache = mlcache
        }

        server {
            listen 8080;

            location / {
                content_by_lua_block {
                    local function callback(username)
                        -- this only runs *once* until the key expires, so
                        -- do expansive operations like connecting to a remote
                        -- backend here. i.e: call a MySQL server in this callback

                        local user, err = db:get_user(username)

                        return user, err
                    end

                    -- this call triggers the callback
                    local user, err = mlcache:get("my_key", nil, callback, "John Doe")
                    if err then
                        ngx.log(ngx.ERR, "error in callback: ", err)
                        return
                    end

                    ngx.say(user.username) -- "John Doe"

                    -- this call *does not* trigger the callback, "my_key"
                    -- is already cached and contains our user
                    local user, err = mlcache:get("my_key", nil, callback, "John Doe")
                    if err then
                        ngx.log(ngx.ERR, "error in callback: ", err)
                        return
                    end

                    ngx.say(user.username) -- "John Doe"
                }
            }
        }
    }
```

[Back to TOC](#table-of-contents)

### Methods

TODO

[Back to TOC](#table-of-contents)

### Installation

TODO

[Back to TOC](#table-of-contents)

### License

Work licensed under the MIT License.

[Back to TOC](#table-of-contents)


[lua-resty-lock]: https://github.com/openresty/lua-resty-lock
[lua-resty-lrucache]: https://github.com/openresty/lua-resty-lrucache
