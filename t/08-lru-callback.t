# vim:set ts=4 sts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(2);

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  cache_shm 1m;

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

=== TEST 1: lru_callback is called on cache misses
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                lru_callback = function(s)
                    return string.format("deserialize(%q)", s)
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:get("key", nil, function() return "foo" end)
            if not data then
                ngx.say(err)
            end
            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body
deserialize("foo")
--- no_error_log
[error]



=== TEST 2: lru_callback is not called on L1 hits
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local calls = 0
            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                lru_callback = function(s)
                    calls = calls + 1
                    return string.format("deserialize(%q)", s)
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            for i=1, 3 do
                local data, err = cache:get("key", nil, function() return "foo" end)
                if not data then
                    ngx.say(err)
                end
                ngx.say(data)
            end
            ngx.say("calls: ", calls)
        }
    }
--- request
GET /t
--- response_body
deserialize("foo")
deserialize("foo")
deserialize("foo")
calls: 1
--- no_error_log
[error]



=== TEST 3: lru_callback is called on L2 hits
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local calls = 0
            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                lru_callback = function(s)
                    calls = calls + 1
                    return string.format("deserialize(%q)", s)
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            for i=1, 3 do
                local data, err = cache:get("key", nil, function() return "foo" end)
                if not data then
                    ngx.say(err)
                end
                ngx.say(data)
                cache.lru:delete("key")
            end
            ngx.say("calls: ", calls)
        }
    }
--- request
GET /t
--- response_body
deserialize("foo")
deserialize("foo")
deserialize("foo")
calls: 3
--- no_error_log
[error]



=== TEST 4: lru_callback is called in protected mode (L2 miss)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                lru_callback = function(s)
                    error("cannot deserialize")
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:get("key", nil, function() return "foo" end)
            if not data then
                ngx.say(err)
            end
            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body_like
lru_callback threw an error: .*?: cannot deserialize
--- no_error_log
[error]



=== TEST 5: lru_callback is called in protected mode (L2 hit)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local called = false
            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                lru_callback = function(s)
                    if called then error("cannot deserialize") end
                    called = true
                    return string.format("deserialize(%q)", s)
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            assert(cache:get("key", nil, function() return "foo" end))
            cache.lru:delete("key")

            local data, err = cache:get("key", nil, function() return "foo" end)
            if not data then
                ngx.say(err)
            end
            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body_like
lru_callback threw an error: .*?: cannot deserialize
--- no_error_log
[error]

