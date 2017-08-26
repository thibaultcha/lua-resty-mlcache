# vim:set ts=4 sts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  cache_shm 1m;
    lua_shared_dict  ipc_shm   1m;
};

run_tests();

__DATA__

=== TEST 1: delete() errors if no ipc module
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm"))

            local ok, err = pcall(cache.set, cache, "foo")
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
no ipc to propagate update, specify ipc_shm
--- no_error_log
[error]



=== TEST 2: set() validates key
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            local ok, err = pcall(cache.set, cache)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
key must be a string
--- no_error_log
[error]



=== TEST 3: set() puts a value directly in shm
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            -- setting a value in shm

            assert(cache:set("my_key", nil, 123))

            -- declaring a callback that MUST NOT be called

            local function cb()
                ngx.log(ngx.ERR, "callback was called but should not have")
            end

            -- try to get()

            local value = assert(cache:get("my_key", nil, cb))

            ngx.say("value from get(): ", value)

            -- value MUST BE in lru

            local value_lru = cache.lru:get("my_key")

            ngx.say("cache lru value after get(): ", value_lru)
        }
    }
--- request
GET /t
--- response_body
value from get(): 123
cache lru value after get(): 123
--- no_error_log
[error]



=== TEST 4: set() puts a value directly in its own LRU
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            -- setting a value in shm

            assert(cache:set("my_key", nil, 123))

            -- value MUST BE be in lru

            local value_lru = cache.lru:get("my_key")

            ngx.say("cache lru value after set(): ", value_lru)
        }
    }
--- request
GET /t
--- response_body
cache lru value after set(): 123
--- no_error_log
[error]



=== TEST 5: set() respects 'ttl' for non-nil values
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            -- setting a non-nil value in shm

            assert(cache:set("my_key", {
                ttl     = 0.2,
                neg_ttl = 1,
            }, 123))

            -- declaring a callback that logs accesses

            local function cb()
                ngx.say("callback called")
                return 123
            end

            -- try to get() (callback MUST NOT be called)

            ngx.say("calling get()")
            local value = assert(cache:get("my_key", nil, cb))
            ngx.say("value from get(): ", value)

            -- wait until expiry

            ngx.say("waiting until expiry...")
            ngx.sleep(0.3)
            ngx.say("waited 0.3s")

            -- try to get() (callback MUST be called)

            ngx.say("calling get()")
            local value = assert(cache:get("my_key", nil, cb))
            ngx.say("value from get(): ", value)
        }
    }
--- request
GET /t
--- response_body
calling get()
value from get(): 123
waiting until expiry...
waited 0.3s
calling get()
callback called
value from get(): 123
--- no_error_log
[error]



=== TEST 6: set() respects 'neg_ttl' for nil values
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            }))

            -- setting a nil value in shm

            assert(cache:set("my_key", {
                ttl     = 1,
                neg_ttl = 0.2,
            }, nil))

            -- declaring a callback that logs accesses

            local function cb()
                ngx.say("callback called")
                return nil
            end

            -- try to get() (callback MUST NOT be called)

            ngx.say("calling get()")
            local value, err = cache:get("my_key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
            end
            ngx.say("value from get(): ", value)

            -- wait until expiry

            ngx.say("waiting until expiry...")
            ngx.sleep(0.3)
            ngx.say("waited 0.3s")

            -- try to get() (callback MUST be called)

            ngx.say("calling get()")
            local value, err = cache:get("my_key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
            end
            ngx.say("value from get(): ", value)
        }
    }
--- request
GET /t
--- response_body
calling get()
value from get(): nil
waiting until expiry...
waited 0.3s
calling get()
callback called
value from get(): nil
--- no_error_log
[error]



=== TEST 7: set() invalidates other workers' LRU cache
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
                debug   = true, -- allows same worker to receive its own published events
            }))

            cache.ipc:subscribe("mlcache:invalidations:" .. cache.name, function(data)
                ngx.say("received event from invalidations: ", data)
            end)

            assert(cache:set("my_key", nil, nil))

            assert(cache:update())
        }
    }
--- request
GET /t
--- response_body
received event from invalidations: my_key
--- no_error_log
[error]
