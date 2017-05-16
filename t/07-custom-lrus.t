#vim:set ts=4 sts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(2);

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  cache 1m;
    lua_shared_dict  events 1m;
};

run_tests();

__DATA__

=== TEST 1: add_lru() validates args
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

            local ok, err = pcall(cache.add_lru, cache)
            if not ok then
                ngx.say(err)
            end

            local ok, err = pcall(cache.add_lru, cache, "")
            if not ok then
                ngx.say(err)
            end

            local ok, err = pcall(cache.add_lru, cache, "my_lru", false)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
name must be a non-empty string
name must be a non-empty string
lru appears not to be a lua-resty-lrucache instance
--- no_error_log
[error]



=== TEST 2: add_lru() prevents overriding an already added lru
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

            local lrucache = require "resty.lrucache"

            local lru = lrucache.new(100)

            cache:add_lru("my_lru", lru)

            local ok, err = pcall(cache.add_lru, cache, "my_lru", lru)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
an lru named 'my_lru' has already been added
--- no_error_log
[error]



=== TEST 3: get() validates opts.lru
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

            local function cb() end

            local ok, err = pcall(cache.get, cache, "my_key", { lru = false }, cb)
            if not ok then
                ngx.say(err)
            end

            local ok, err = pcall(cache.get, cache, "my_key", { lru = "" }, cb)
            if not ok then
                ngx.say(err)
            end

            local ok, err = pcall(cache.get, cache, "my_key", { lru = "my_lru" }, cb)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
opts.lru must be a non-empty string
opts.lru must be a non-empty string
no lru named 'my_lru'
--- no_error_log
[error]



=== TEST 4: get() with custom lru avoids default lru
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"
            local lrucache = require "resty.lrucache"

            local lru = lrucache.new(100)

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            cache:add_lru("my_lru", lru)

            local function cb_number()
                return 123
            end

            local function cb_nil()
                return nil
            end

            local value, err = cache:get("my_key", { lru = "my_lru" }, cb_number)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("custom lru has: ", lru:get("my_key"))
            ngx.say("default lru has: ", cache.lru:get("my_key"))

            local value, err = cache:get("my_nil_key", { lru = "my_lru" }, cb_nil)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("custom lru has a nil sentinel: ", lru:get("my_nil_key") ~= nil)
        }
    }
--- request
GET /t
--- response_body
custom lru has: 123
default lru has: nil
custom lru has a nil sentinel: true
--- no_error_log
[error]



=== TEST 5: get() several lrus can store the same value
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"
            local lrucache = require "resty.lrucache"

            local lru = lrucache.new(100)

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            cache:add_lru("my_lru", lru)

            local function cb_number()
                return 123
            end

            local value, err = cache:get("my_key", nil, cb_number)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            local value, err = cache:get("my_key", { lru = "my_lru" }, cb_number)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("custom lru has: ", lru:get("my_key"))
            ngx.say("default lru has: ", cache.lru:get("my_key"))
        }
    }
--- request
GET /t
--- response_body
custom lru has: 123
default lru has: 123
--- no_error_log
[error]



=== TEST 6: get() works with pureffi lru implementation
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"
            local lrucache = require "resty.lrucache.pureffi"

            local lru = lrucache.new(100)

            local cache, err = mlcache.new("cache")
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            cache:add_lru("my_pureffi_lru", lru)

            local function cb()
                return 123
            end

            local value, err = cache:get("my_key", { lru = "my_pureffi_lru" }, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("pureffi lru has: ", lru:get("my_key"))
            ngx.say("default lru has: ", cache.lru:get("my_key"))
        }
    }
--- request
GET /t
--- response_body
pureffi lru has: 123
default lru has: nil
--- no_error_log
[error]



=== TEST 7: delete() invalidates from all lrus
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"
            local lrucache = require "resty.lrucache"

            local lru = lrucache.new(100)

            local cache, err = mlcache.new("cache", { ipc_shm = "events" })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            cache:add_lru("my_lru", lru)

            local function cb()
                return 123
            end

            local value, err = cache:get("my_key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("default lru: ", cache.lru:get("my_key"))

            local value, err = cache:get("my_key", { lru = "my_lru" }, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("custom lru: ", lru:get("my_key"))

            assert(cache:delete("my_key"))

            ngx.say("default lru: ", cache.lru:get("my_key"))
            ngx.say("custom lru: ", lru:get("my_key"))
        }
    }
--- request
GET /t
--- response_body
default lru: 123
custom lru: 123
default lru: nil
custom lru: nil
--- no_error_log
[error]
