# vim:set ts=4 sts=4 sw=4 et ft=:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);
use lib '.';
use t::Util;

no_long_string();

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  cache_shm      1m;
    lua_shared_dict  cache_shm_miss 1m;

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

=== TEST 1: new() validates 'opts.serve_stale' (boolean)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local pok, perr = pcall(mlcache.new, "my_mlcache", "cache_shm", {
                serve_stale = "",
            })
            if not pok then
                ngx.say(perr)
            end

            local pok, perr = pcall(mlcache.new, "my_mlcache", "cache_shm", {
                serve_stale = -1,
            })
            if not pok then
                ngx.say(perr)
            end
        }
    }
--- request
GET /t
--- response_body
opts.serve_stale must be a boolean
opts.serve_stale must be a boolean
--- no_error_log
[error]



=== TEST 2: get() validates 'opts.resurrect_ttl' (number && >= 0)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"
            local cache = assert(mlcache.new("my_mlcache", "cache_shm"))

            local function cb()
                -- nop
            end

            local pok, perr = pcall(cache.get, cache, "key", {
                serve_stale = "",
            }, cb)
            if not pok then
                ngx.say(perr)
            end

            local pok, perr = pcall(cache.get, cache, "key", {
                serve_stale = -1,
            }, cb)
            if not pok then
                ngx.say(perr)
            end
        }
    }
--- request
GET /t
--- response_body
opts.serve_stale must be a boolean
opts.serve_stale must be a boolean
--- no_error_log
[error]



=== TEST 3: get() with opts.serve_stale runs L3 callback in background (stale from L1)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm"))

            local opts = {
                serve_stale = true,
                ttl = 0.1,
            }

            local i = 0
            local function cb()
                i = i + 1
                if i == 1 then
                    return "hello world"
                end
                ngx.say("in callback")
                return "bye world"
            end

            local data, err, hit_lvl = cache:get("key", opts, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("first get: ", data, " (hit_lvl: ", hit_lvl, ")")

            ngx.sleep(0.2)

            -- item is stale

            local data, err, hit_lvl = cache:get("key", opts, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("second get: ", data, " (hit_lvl: ", hit_lvl, ")")

            ngx.sleep(0)

            -- item should have been refreshed

            local data, err, hit_lvl = cache:get("key", opts, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("third get: ", data, " (hit_lvl: ", hit_lvl, ")")
        }
    }
--- request
GET /t
--- response_body
first get: hello world (hit_lvl: 3)
in callback
second get: hello world (hit_lvl: 4)
third get: bye world (hit_lvl: 1)
--- no_error_log
[error]



=== TEST 4: get() with opts.serve_stale runs L3 callback in background (stale from L2)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm"))

            local opts = {
                serve_stale = true,
                ttl = 0.1,
            }

            local i = 0
            local function cb()
                i = i + 1
                if i == 1 then
                    return "hello world"
                end
                ngx.say("in callback")
                return "bye world"
            end

            local data, err, hit_lvl = cache:get("key", opts, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("first get: ", data, " (hit_lvl: ", hit_lvl, ")")

            ngx.sleep(0.2)

            -- item is stale

            -- delete from L1 to force stale serving from L2
            cache.lru:delete("key")

            local data, err, hit_lvl = cache:get("key", opts, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("second get: ", data, " (hit_lvl: ", hit_lvl, ")")

            ngx.sleep(0)

            -- item should have been refreshed

            local data, err, hit_lvl = cache:get("key", opts, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("third get: ", data, " (hit_lvl: ", hit_lvl, ")")
        }
    }
--- request
GET /t
--- response_body
first get: hello world (hit_lvl: 3)
in callback
second get: hello world (hit_lvl: 4)
third get: bye world (hit_lvl: 1)
--- no_error_log
[error]



=== TEST 5: get() with opts.serve_stale background callbacks respect the lock
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm"))

            local opts = {
                serve_stale = true,
                ttl = 0.1,
            }

            local i = 0
            local function cb(no_ret)
                i = i + 1
                if i == 1 then
                    return "hello world"
                end
                ngx.say("in callback before sleep")
                ngx.sleep(0.2)
                ngx.say("in callback after sleep")
                return "bye world"
            end

            local data, err, hit_lvl = cache:get("key", opts, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("first get: ", data, " (hit_lvl: ", hit_lvl, ")")

            ngx.sleep(0.11)

            -- item is stale
            -- now start several threads retrieving this stale value

            local threads = {}

            for i = 1, 3 do
                threads[i] = ngx.thread.spawn(function()
                    local data, err, hit_lvl = cache:get("key", opts, cb)
                    if err then
                        ngx.log(ngx.ERR, err)
                        return
                    end
                    ngx.say("get ", i, ": ", data, " (hit_lvl: ", hit_lvl, ")")
                end)
            end

            for i = 1, 3 do
                local ok, res = ngx.thread.wait(threads[i])
                if not ok then
                    ngx.log(ngx.ERR, res)
                end
            end

            ngx.sleep(0.21)

            local data, err, hit_lvl = cache:get("key", opts, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("last get: ", data, " (hit_lvl: ", hit_lvl, ")")
        }
    }
--- request
GET /t
--- response_body
first get: hello world (hit_lvl: 3)
in callback before sleep
get 1: hello world (hit_lvl: 4)
get 2: hello world (hit_lvl: 4)
get 3: hello world (hit_lvl: 4)
in callback after sleep
last get: bye world (hit_lvl: 1)
--- no_error_log
[error]
