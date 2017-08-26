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

    init_by_lua_block {
        -- local verbose = true
        local verbose = false
        local outfile = "$Test::Nginx::Util::ErrLogFile"
        -- local outfile = "/tmp/v.log"
        if verbose then
            local dump = require "jit.dump"
            dump.on(nil, outfile)
        else
            local v = require "jit.v"
            v.on(outfile)
        end

        require "resty.core"
        -- jit.opt.start("hotloop=1")
        -- jit.opt.start("loopunroll=1000000")
        -- jit.off()
    }
};

run_tests();

__DATA__

=== TEST 1: multiple instances with the same name have same lua-resty-lru instance
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache_1 = assert(mlcache.new("my_mlcache", "cache_shm"))
            local cache_2 = assert(mlcache.new("my_mlcache", "cache_shm"))

            ngx.say("lua-resty-lru instances are the same: ",
                    cache_1.lru == cache_2.lru)
        }
    }
--- request
GET /t
--- response_body
lua-resty-lru instances are the same: true
--- no_error_log
[error]



=== TEST 2: multiple instances with different names have different lua-resty-lru instances
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache_1 = assert(mlcache.new("my_mlcache_1", "cache_shm"))
            local cache_2 = assert(mlcache.new("my_mlcache_2", "cache_shm"))

            ngx.say("lua-resty-lru instances are the same: ",
                    cache_1.lru == cache_2.lru)
        }
    }
--- request
GET /t
--- response_body
lua-resty-lru instances are the same: false
--- no_error_log
[error]



=== TEST 3: garbage-collected instances also GC their lru instance
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            collectgarbage("collect")
            local cache_1 = assert(mlcache.new("my_mlcache", "cache_shm"))
            local cache_2 = assert(mlcache.new("my_mlcache", "cache_shm"))

            cache_1.lru:set("key", 123)

            cache_1 = nil
            collectgarbage("collect")

            ngx.say(cache_2.lru:get("key"))

            cache_2 = nil
            collectgarbage("collect")

            cache_1 = assert(mlcache.new("my_mlcache", "cache_shm"))
            cache_2 = assert(mlcache.new("my_mlcache", "cache_shm"))

            ngx.say(cache_2.lru:get("key"))
        }
    }
--- request
GET /t
--- response_body
123
nil
--- no_error_log
[error]



=== TEST 4: multiple instances with different names get() of the same key is isolated
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            -- create 2 mlcache

            local cache_1 = assert(mlcache.new("my_mlcache_1", "cache_shm"))
            local cache_2 = assert(mlcache.new("my_mlcache_2", "cache_shm"))

            -- set 2 values in both mlcaches

            local data_1 = assert(cache_1:get("my_key", nil, function() return "value A" end))
            local data_2 = assert(cache_2:get("my_key", nil, function() return "value B" end))

            -- get values from LRU

            local lru_1_value = cache_1.lru:get("my_key")
            local lru_2_value = cache_2.lru:get("my_key")

            ngx.say("cache_1 lru has: ", lru_1_value)
            ngx.say("cache_2 lru has: ", lru_2_value)

            -- delete values from LRU

            cache_1.lru:delete("my_key")
            cache_2.lru:delete("my_key")

            -- get values from shm

            local shm_1_value = assert(cache_1:get("my_key", nil, function() end))
            local shm_2_value = assert(cache_2:get("my_key", nil, function() end))

            ngx.say("cache_1 shm has: ", shm_1_value)
            ngx.say("cache_2 shm has: ", shm_2_value)
        }
    }
--- request
GET /t
--- response_body
cache_1 lru has: value A
cache_2 lru has: value B
cache_1 shm has: value A
cache_2 shm has: value B
--- no_error_log
[error]



=== TEST 5: multiple instances delete() of the same key is isolated
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            -- create 2 mlcache

            local cache_1 = assert(mlcache.new("my_mlcache_1", "cache_shm", { ipc_shm = "ipc_shm" }))
            local cache_2 = assert(mlcache.new("my_mlcache_2", "cache_shm", { ipc_shm = "ipc_shm" }))

            -- set 2 values in both mlcaches

            local data_1 = assert(cache_1:get("my_key", nil, function() return "value A" end))
            local data_2 = assert(cache_2:get("my_key", nil, function() return "value B" end))

            -- test if value is set from shm (safer to check due to the key)

            local shm_v = ngx.shared.cache_shm:get(cache_1.name .. "my_key")
            ngx.say("cache_1 shm has a value: ", shm_v ~= nil)

            -- delete value from mlcache 1

            ngx.say("delete from cache_1")
            assert(cache_1:delete("my_key"))

            -- ensure cache 1 key is deleted from LRU

            local lru_v = cache_1.lru:get("my_key")
            ngx.say("cache_1 lru has: ", lru_v)

            -- ensure cache 1 key is deleted from shm

            local shm_v = ngx.shared.cache_shm:get(cache_1.name .. "my_key")
            ngx.say("cache_1 shm has a value: ", shm_v ~= nil)
        }
    }
--- request
GET /t
--- response_body
cache_1 shm has a value: true
delete from cache_1
cache_1 lru has: nil
cache_1 shm has a value: false
--- no_error_log
[error]



=== TEST 6: multiple instances broadcasts is isolated
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            -- create 2 mlcache

            local cache_1 = assert(mlcache.new("my_mlcache_1", "cache_shm", {
                ipc_shm = "ipc_shm",
                debug   = true, -- allows same worker to receive its own published events
            }))
            local cache_2 = assert(mlcache.new("my_mlcache_2", "cache_shm", {
                ipc_shm = "ipc_shm",
                debug   = true, -- allows same worker to receive its own published events
            }))

            cache_1.ipc:subscribe("mlcache:invalidations:" .. cache_1.name, function(data)
                ngx.log(ngx.NOTICE, "received event from cache_1 invalidations: ", data)
            end)

            cache_2.ipc:subscribe("mlcache:invalidations:" .. cache_2.name, function(data)
                ngx.log(ngx.NOTICE, "received event from cache_2 invalidations: ", data)
            end)

            assert(cache_1:delete("my_key"))

            assert(cache_1:update())
            assert(cache_2:update())
        }
    }
--- request
GET /t
--- response_body

--- error_log
received event from cache_1 invalidations: my_key



=== TEST 7: multiple instances peek() of the same key is isolated
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            -- create 2 mlcache

            local cache_1 = assert(mlcache.new("my_mlcache_1", "cache_shm", { ipc_shm = "ipc_shm" }))
            local cache_2 = assert(mlcache.new("my_mlcache_2", "cache_shm", { ipc_shm = "ipc_shm" }))

            -- set 2 values in both mlcaches

            local data_1 = assert(cache_1:get("my_key", { ttl = 1 }, function() return "value A" end))
            local data_2 = assert(cache_2:get("my_key", { ttl = 2 }, function() return "value B" end))

            -- peek cache 1

            local ttl, err, val = assert(cache_1:peek("my_key"))

            ngx.say("cache_1 ttl: ", ttl)
            ngx.say("cache_1 value: ", val)

            -- peek cache 2

            local ttl, err, val = assert(cache_2:peek("my_key"))

            ngx.say("cache_2 ttl: ", ttl)
            ngx.say("cache_2 value: ", val)
        }
    }
--- request
GET /t
--- response_body
cache_1 ttl: 1
cache_1 value: value A
cache_2 ttl: 2
cache_2 value: value B
--- no_error_log
[error]
