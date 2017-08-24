# vim:set ts=4 sts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(2);

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 3) + 5;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  cache 1m;

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

=== TEST 1: get() validates key
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = pcall(cache.get, cache)
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



=== TEST 2: get() validates callback
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = pcall(cache.get, cache, "key")
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
callback must be a function
--- no_error_log
[error]



=== TEST 3: get() validates opts
--- SKIP: no options yet
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = pcall(cache.get, cache, "key", function() end, 0)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
opts must be a table
--- no_error_log
[error]



=== TEST 4: get() calls callback in protected mode
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                error("oops")
            end

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body_like
callback threw an error: .*? oops
--- no_error_log
[error]



=== TEST 5: get() caches a number
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                return 123
            end

            -- from callback

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from callback: ", type(data), " ", data)

            -- from lru

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from lru: ", type(data), " ", data)

            -- from shm

            cache.lru:delete("key")

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from shm: ", type(data), " ", data)
        }
    }
--- request
GET /t
--- response_body
from callback: number 123
from lru: number 123
from shm: number 123
--- no_error_log
[error]



=== TEST 6: get() caches a boolean (true)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                return true
            end

            -- from callback

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from callback: ", type(data), " ", data)

            -- from lru

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from lru: ", type(data), " ", data)

            -- from shm

            cache.lru:delete("key")

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from shm: ", type(data), " ", data)
        }
    }
--- request
GET /t
--- response_body
from callback: boolean true
from lru: boolean true
from shm: boolean true
--- no_error_log
[error]



=== TEST 7: get() caches a boolean (false)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                return false
            end

            -- from callback

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from callback: ", type(data), " ", data)

            -- from lru

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from lru: ", type(data), " ", data)

            -- from shm

            cache.lru:delete("key")

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from shm: ", type(data), " ", data)
        }
    }
--- request
GET /t
--- response_body
from callback: boolean false
from lru: boolean false
from shm: boolean false
--- no_error_log
[error]



=== TEST 8: get() caches nil
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                return nil
            end

            -- from callback

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from callback: ", type(data), " ", data)

            -- from lru

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from lru: ", type(data), " ", data)

            -- from shm

            cache.lru:delete("key")

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from shm: ", type(data), " ", data)
        }
    }
--- request
GET /t
--- response_body
from callback: nil nil
from lru: nil nil
from shm: nil nil
--- no_error_log
[error]



=== TEST 9: get() caches a string
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                return "hello world"
            end

            -- from callback

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from callback: ", type(data), " ", data)

            -- from lru

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from lru: ", type(data), " ", data)

            -- from shm

            cache.lru:delete("key")

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from shm: ", type(data), " ", data)
        }
    }
--- request
GET /t
--- response_body
from callback: string hello world
from lru: string hello world
from shm: string hello world
--- no_error_log
[error]



=== TEST 10: get() caches a table
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local cjson = require "cjson"
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                return {
                    hello = "world",
                    subt  = { foo = "bar" }
                }
            end

            -- from callback

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from callback: ", type(data), " ", data.hello, " ", data.subt.foo)

            -- from lru

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from lru: ", type(data), " ", data.hello, " ", data.subt.foo)

            -- from shm

            cache.lru:delete("key")

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("from shm: ", type(data), " ", data.hello, " ", data.subt.foo)
        }
    }
--- request
GET /t
--- response_body
from callback: table world bar
from lru: table world bar
from shm: table world bar
--- no_error_log
[error]



=== TEST 11: get() errors when caching an unsupported type
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local cjson = require "cjson"
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                return ngx.null
            end

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
        }
    }
--- request
GET /t
--- error_code: 500
--- error_log eval
qr/\[error\] .*?mlcache\.lua:\d+: cannot cache value of type userdata/



=== TEST 12: get() calls callback with args
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb(a, b)
                return a + b
            end

            local data, err = cache:get("key", nil, cb, 1, 2)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body
3
--- no_error_log
[error]



=== TEST 13: get() caches hit for 'ttl' from LRU (in ms)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache", { ttl = 0.3 }))

            local function cb()
                ngx.say("in callback")
                return 123
            end

            local data = assert(cache:get("key", nil, cb))
            assert(data == 123)

            ngx.sleep(0.2)

            data = assert(cache:get("key", nil, cb))
            assert(data == 123)

            ngx.sleep(0.2)

            data = assert(cache:get("key", nil, cb))
            assert(data == 123)
        }
    }
--- request
GET /t
--- response_body
in callback
in callback
--- no_error_log
[error]



=== TEST 14: get() caches miss (nil) for 'neg_ttl' from LRU (in ms)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache", {
                ttl     = 10,
                neg_ttl = 0.3
            }))

            local function cb()
                ngx.say("in callback")
                return nil
            end

            local data, err = cache:get("key", nil, cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.2)

            data, err = cache:get("key", nil, cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.2)

            data, err = cache:get("key", nil, cb)
            assert(err == nil, err)
            assert(data == nil)
        }
    }
--- request
GET /t
--- response_body
in callback
in callback
--- no_error_log
[error]



=== TEST 15: get() caches for 'opts.ttl' from LRU (in ms)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache", { ttl = 10 }))

            local function cb()
                ngx.say("in callback")
                return 123
            end

            local data = assert(cache:get("key", { ttl = 0.3 }, cb))
            assert(data == 123)

            ngx.sleep(0.2)

            data = assert(cache:get("key", nil, cb))
            assert(data == 123)

            ngx.sleep(0.2)

            data = assert(cache:get("key", nil, cb))
            assert(data == 123)
        }
    }
--- request
GET /t
--- response_body
in callback
in callback
--- no_error_log
[error]



=== TEST 16: get() caches for 'opts.neg_ttl' from LRU (in ms)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache", { neg_ttl = 2 }))

            local function cb()
                ngx.say("in callback")
                return nil
            end

            local data, err = cache:get("key", { neg_ttl = 0.3 }, cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.2)

            data, err = cache:get("key", nil, cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.2)

            data, err = cache:get("key", nil, cb)
            assert(err == nil, err)
            assert(data == nil)
        }
    }
--- request
GET /t
--- response_body
in callback
in callback
--- no_error_log
[error]



=== TEST 17: get() with ttl of 0 means indefinite caching
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache", { ttl = 0.3 }))

            local function cb()
                ngx.say("in callback")
                return 123
            end

            local data = assert(cache:get("key", { ttl = 0 }, cb))
            assert(data == 123)

            ngx.sleep(0.4)

            -- still in LRU
            local data, stale = cache.lru:get("key")
            if stale then
                ngx.say("in LRU after 1.1s: stale")

            else
                ngx.say("in LRU after exp: ", data)
            end

            cache.lru:delete("key")

            -- still in shm
            data = assert(cache:get("key", nil, cb))

            ngx.say("in shm after exp: ", data)
        }
    }
--- request
GET /t
--- response_body
in callback
in LRU after exp: 123
in shm after exp: 123
--- no_error_log
[error]



=== TEST 18: get() with neg_ttl of 0 means indefinite caching for nil values
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = assert(mlcache.new("cache", { ttl = 0.3 }))

            local function cb()
                ngx.say("in callback")
                return nil
            end

            local data, err = cache:get("key", { neg_ttl = 0 }, cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.4)

            -- still in LRU
            local data, stale = cache.lru:get("key")
            if stale then
                ngx.say("in LRU after 0.4s: stale")

            else
                ngx.say("in LRU after exp: ", tostring(data))
            end

            cache.lru:delete("key")

            -- still in shm
            data, err = cache:get("key", nil, cb)
            assert(err == nil, err)

            ngx.say("in shm after exp: ", tostring(data))
        }
    }
--- request
GET /t
--- response_body_like
in callback
in LRU after exp: table: \S+
in shm after exp: nil
--- no_error_log
[error]



=== TEST 19: get() errors when ttl < 0
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                ngx.say("in callback")
                return 123
            end

            local ok, err = pcall(cache.get, cache, "key", { ttl = -1 }, cb)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
opts.ttl must be >= 0
--- no_error_log
[error]



=== TEST 20: get() errors when neg_ttl < 0
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                ngx.say("in callback")
                return 123
            end

            local ok, err = pcall(cache.get, cache, "key", { neg_ttl = -1 }, cb)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
opts.neg_ttl must be >= 0
--- no_error_log
[error]



=== TEST 21: get() shm -> LRU caches for 'opts.ttl - since' in ms
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache"))

            local function cb()
                return 123
            end

            local data = assert(cache:get("key", { ttl = 0.5 }, cb))
            assert(data == 123)

            ngx.sleep(0.2)

            -- delete from LRU
            cache.lru:delete("key")

            -- from shm, setting LRU with smaller ttl
            data, err = assert(cache:get("key", nil, cb))
            assert(data == 123)

            ngx.sleep(0.2)

            -- still in LRU
            local data, stale = cache.lru:get("key")
            if stale then
                ngx.say("is stale in LRU: ", stale)

            else
                ngx.say("is not expired in LRU: ", data)
            end

            ngx.sleep(0.1)

            -- expired in LRU
            local data, stale = cache.lru:get("key")
            if stale then
                ngx.say("is stale in LRU: ", stale)

            else
                ngx.say("is not expired in LRU: ", data)
            end
        }
    }
--- request
GET /t
--- response_body
is not expired in LRU: 123
is stale in LRU: 123
--- no_error_log
[error]



=== TEST 22: get() shm -> LRU caches non-nil for 'indefinite' if ttl is 0
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache"))

            local function cb()
                return 123
            end

            local data = assert(cache:get("key", { ttl = 0 }, cb))
            assert(data == 123)

            ngx.sleep(0.2)

            -- delete from LRU
            cache.lru:delete("key")

            -- from shm, setting LRU with indefinite ttl too
            data, err = assert(cache:get("key", nil, cb))
            assert(data == 123)

            -- still in LRU
            local data, stale = cache.lru:get("key")
            if stale then
                ngx.say("is stale in LRU: ", stale)

            else
                ngx.say("is not expired in LRU: ", data)
            end
        }
    }
--- request
GET /t
--- response_body
is not expired in LRU: 123
--- no_error_log
[error]



=== TEST 23: get() shm -> LRU caches for 'opts.neg_ttl - since' in ms
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache"))

            local function cb()
                return nil
            end

            local data, err = cache:get("key", { neg_ttl = 0.5 }, cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.2)

            -- delete from LRU
            cache.lru:delete("key")

            -- from shm, setting LRU with smaller ttl
            data, err = cache:get("key", nil, cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.2)

            -- still in LRU
            local data, stale = cache.lru:get("key")
            if stale then
                ngx.say("is stale in LRU: ", tostring(stale))

            else
                ngx.say("is not expired in LRU: ", tostring(data))
            end

            ngx.sleep(0.1)

            -- expired in LRU
            local data, stale = cache.lru:get("key")
            if stale then
                ngx.say("is stale in LRU: ", tostring(stale))

            else
                ngx.say("is not expired in LRU: ", tostring(data))
            end
        }
    }
--- request
GET /t
--- response_body_like
is not expired in LRU: table: \S+
is stale in LRU: table: \S+
--- no_error_log
[error]



=== TEST 24: get() shm -> LRU caches nil for 'indefinite' if neg_ttl is 0
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache"))

            local function cb()
                return nil
            end

            local data, err =cache:get("key", { neg_ttl = 0 }, cb)
            assert(err == nil)
            assert(data == nil)

            ngx.sleep(0.2)

            -- delete from LRU
            cache.lru:delete("key")

            -- from shm, setting LRU with indefinite ttl too
            data, err = cache:get("key", nil, cb)
            assert(err == nil)
            assert(data == nil)

            -- still in LRU
            local data, stale = cache.lru:get("key")
            ngx.say("is stale in LRU: ", stale)

            -- data is a table (nil sentinel value) so rely on stale instead
        }
    }
--- request
GET /t
--- response_body
is stale in LRU: nil
--- no_error_log
[error]



=== TEST 25: get() returns hit level
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache"))

            local function cb()
                return 123
            end

            local _, _, hit_lvl = assert(cache:get("key", nil, cb))
            ngx.say("hit level from callback: ", hit_lvl)

            _, _, hit_lvl = assert(cache:get("key", nil, cb))
            ngx.say("hit level from LRU: ", hit_lvl)

            -- delete from LRU

            cache.lru:delete("key")

            _, _, hit_lvl = assert(cache:get("key", nil, cb))
            ngx.say("hit level from shm: ", hit_lvl)
        }
    }
--- request
GET /t
--- response_body
hit level from callback: 3
hit level from LRU: 1
hit level from shm: 2
--- no_error_log
[error]



=== TEST 26: get() returns hit level for nil hits
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache"))

            local function cb()
                return nil
            end

            local _, _, hit_lvl = cache:get("key", nil, cb)
            ngx.say("hit level from callback: ", hit_lvl)

            _, _, hit_lvl = cache:get("key", nil, cb)
            ngx.say("hit level from LRU: ", hit_lvl)

            -- delete from LRU

            cache.lru:delete("key")

            _, _, hit_lvl = cache:get("key", nil, cb)
            ngx.say("hit level from shm: ", hit_lvl)
        }
    }
--- request
GET /t
--- response_body
hit level from callback: 3
hit level from LRU: 1
hit level from shm: 2
--- no_error_log
[error]



=== TEST 27: get() JITs when hit coming from LRU
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache"))

            local function cb()
                return 123456
            end

            for i = 1, 10e3 do
                local data = assert(cache:get("key", nil, cb))
                assert(data == 123456)
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log eval
qr/\[TRACE   \d+ content_by_lua\(nginx\.conf:\d+\):10 loop\]/
--- no_error_log
[error]



=== TEST 28: get() JITs when hit of scalar value coming from shm
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache"))

            local function cb_number()
                return 123456
            end

            local function cb_string()
                return "hello"
            end

            local function cb_bool()
                return false
            end

            for i = 1, 10e2 do
                local data = assert(cache:get("number", nil, cb_number))
                assert(data == 123456)

                cache.lru:delete("number")
            end

            for i = 1, 10e2 do
                local data = assert(cache:get("string", nil, cb_string))
                assert(data == "hello")

                cache.lru:delete("string")
            end

            for i = 1, 10e2 do
                local data, err = cache:get("bool", nil, cb_bool)
                assert(err == nil)
                assert(data == false)

                cache.lru:delete("bool")
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log eval
[
    qr/\[TRACE\s+\d+ content_by_lua\(nginx\.conf:\d+\):18 loop\]/,
    qr/\[TRACE\s+\d+ content_by_lua\(nginx\.conf:\d+\):25 loop\]/,
    qr/\[TRACE\s+\d+ content_by_lua\(nginx\.conf:\d+\):32 loop\]/,
]
--- no_error_log
[error]



=== TEST 29: get() JITs when hit of table value coming from shm
--- SKIP: blocked until custom table serializer
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache"))

            local function cb_table()
                return { hello = "world" }
            end

            for i = 1, 10e2 do
                local data = assert(cache:get("table", nil, cb_table))
                assert(type(data) == "table")
                assert(data.hello == "world")

                cache.lru:delete("table")
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log eval
qr/\[TRACE\s+\d+ content_by_lua\(nginx\.conf:\d+\):18 loop\]/
--- no_error_log
[error]



=== TEST 30: get() JITs when miss coming from LRU
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache"))

            local function cb()
                return nil
            end

            for i = 1, 10e3 do
                local data, err = cache:get("key", nil, cb)
                assert(err == nil)
                assert(data == nil)
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log eval
qr/\[TRACE   \d+ content_by_lua\(nginx\.conf:\d+\):10 loop\]/
--- no_error_log
[error]



=== TEST 31: get() JITs when miss coming from shm
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache"))

            local function cb()
                return nil
            end

            for i = 1, 10e3 do
                local data, err = cache:get("key", nil, cb)
                assert(err == nil)
                assert(data == nil)

                cache.lru:delete("key")
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log eval
qr/\[TRACE   \d+ content_by_lua\(nginx\.conf:\d+\):10 loop\]/
--- no_error_log
[error]



=== TEST 30: get() allows callback second return value overriding ttl
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local opts  = { ttl = 10 }
            local cache = assert(mlcache.new("cache", opts))

            local function cb()
                ngx.say("in callback 1")
                return 1, nil, 0.1
            end

            local function cb2()
                ngx.say("in callback 2")
                return 2
            end

            -- cache our value (runs cb)

            local data, err = cache:get("key", opts, cb)
            assert(err == nil, err)
            assert(data == 1)

            -- should not run cb2

            data, err = cache:get("key", opts, cb2)
            assert(err == nil, err)
            assert(data == 1)

            ngx.sleep(0.15)

            -- should run cb2 (value expired)

            data, err = cache:get("key", opts, cb2)
            assert(err == nil, err)
            assert(data == 2)
        }
    }
--- request
GET /t
--- response_body
in callback 1
in callback 2
--- no_error_log
[error]



=== TEST 31: get() allows callback second return value overriding neg_ttl
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local opts  = { ttl = 10, neg_ttl = 10 }
            local cache = assert(mlcache.new("cache", opts))

            local function cb()
                ngx.say("in callback 1")
                return nil, nil, 0.1
            end

            local function cb2()
                ngx.say("in callback 2")
                return 1
            end

            -- cache our value (runs cb)

            local data, err = cache:get("key", opts, cb)
            assert(err == nil, err)
            assert(data == nil)

            -- should not run cb2

            data, err = cache:get("key", opts, cb2)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.15)

            -- should run cb2 (value expired)

            data, err = cache:get("key", opts, cb2)
            assert(err == nil, err)
            assert(data == 1)
        }
    }
--- request
GET /t
--- response_body
in callback 1
in callback 2
--- no_error_log
[error]



=== TEST 32: get() ignores invalid callback second return value
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local opts  = { ttl = 0.1, neg_ttl = 0.1 }
            local cache = assert(mlcache.new("cache", opts))

            local function pos_cb()
                ngx.say("in positive callback")
                return 1, nil, "success"
            end

            local function neg_cb()
                ngx.say("in negative callback")
                return nil, nil, -1
            end

            ngx.say("Test A: string TTL return value is ignored")

            -- cache our value (runs pos_cb)

            local data, err = cache:get("pos_key", opts, pos_cb)
            assert(err == nil, err)
            assert(data == 1)

            -- neg_cb should not run

            data, err = cache:get("pos_key", opts, neg_cb)
            assert(err == nil, err)
            assert(data == 1)

            ngx.sleep(0.15)

            -- should run neg_cb

            data, err = cache:get("pos_key", opts, neg_cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.say("Test B: negative TTL return value is ignored")

            -- cache our value (runs neg_cb)

            data, err = cache:get("neg_key", opts, neg_cb)
            assert(err == nil, err)
            assert(data == nil)

            -- pos_cb should not run

            data, err = cache:get("neg_key", opts, pos_cb)
            assert(err == nil, err)
            assert(data == nil)

            ngx.sleep(0.15)

            -- should run pos_cb

            data, err = cache:get("neg_key", opts, pos_cb)
            assert(err == nil, err)
            assert(data == 1)
        }
    }
--- request
GET /t
--- response_body
Test A: string TTL return value is ignored
in positive callback
in negative callback
Test B: negative TTL return value is ignored
in negative callback
in positive callback
--- no_error_log
[error]
