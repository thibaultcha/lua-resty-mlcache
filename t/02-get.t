# vim:set ts=4 sts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(2);

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  cache 1m;
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



=== TEST 5: get() from callback returns number
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

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say(type(data))
            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body
number
123
--- no_error_log
[error]



=== TEST 6: get() from callback returns boolean
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

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say(type(data))
            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body
boolean
false
--- no_error_log
[error]



=== TEST 7: get() from callback returns nil
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

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say(type(data))
            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body
nil
nil
--- no_error_log
[error]



=== TEST 8: get() from callback returns string
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

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say(type(data))
            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body
string
hello world
--- no_error_log
[error]



=== TEST 9: get() from callback returns table
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

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            local str = ngx.shared.cache:get("key")
            ngx.say("in shm: ", str)

            local json = cjson.encode(data)
            ngx.say("returned table: ", json)
        }
    }
--- request
GET /t
--- response_body
in shm: {"subt":{"foo":"bar"},"hello":"world"}
returned table: {"subt":{"foo":"bar"},"hello":"world"}
--- no_error_log
[error]



=== TEST 10: get() calls callback with args
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



=== TEST 11: get() caches for 'ttl'
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache", {
                ttl = 1
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                ngx.say("in callback")
                return 123
            end

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            assert(data == 123)

            ngx.sleep(0.5)

            data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            assert(data == 123)

            ngx.sleep(0.5)

            print("after sleep")

            data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

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



=== TEST 12: get() caches miss (nil) for 'neg_ttl'
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache", {
                ttl     = 10,
                neg_ttl = 1
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local function cb()
                ngx.say("in callback")
                return nil
            end

            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            assert(data == nil)

            ngx.sleep(0.5)

            data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            assert(data == nil)

            ngx.sleep(0.5)

            data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

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



=== TEST 13: get() caches for 'opts.ttl'
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

            local data, err = cache:get("key", { ttl = 2 }, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            assert(data == 123)

            ngx.sleep(0.5)

            data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            assert(data == 123)

            ngx.sleep(0.5)

            print("after sleep")

            data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            assert(data == 123)
        }
    }
--- request
GET /t
--- response_body
in callback
--- no_error_log
[error]
