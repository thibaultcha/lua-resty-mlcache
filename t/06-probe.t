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

=== TEST 1: probe() validates key
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

            local ok, err = pcall(cache.probe, cache)
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



=== TEST 2: probe() returns nil if a key has never been fetched before
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

            local ttl, err = cache:probe("my_key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("ttl: ", ttl)
        }
    }
--- request
GET /t
--- response_body
ttl: nil
--- no_error_log
[error]



=== TEST 3: probe() returns the remaining ttl if a key has been fetched before
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

            local val, err = cache:get("my_key", { neg_ttl = 19 }, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            local ttl, err = cache:probe("my_key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("ttl: ", ttl)

            ngx.sleep(1)

            local ttl, err = cache:probe("my_key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("ttl: ", math.ceil(ttl))
        }
    }
--- request
GET /t
--- response_body
ttl: 19
ttl: 18
--- no_error_log
[error]



=== TEST 4: probe() returns the value if a key has been fetched before
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

            local function cb_number()
                return 123
            end

            local function cb_nil()
                return nil
            end

            local val, err = cache:get("my_key", nil, cb_number)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            local val, err = cache:get("my_nil_key", nil, cb_nil)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            local ttl, err, val = cache:probe("my_key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("ttl: ", ttl, " val: ", val)

            local ttl, err, val = cache:probe("my_nil_key")
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("ttl: ", ttl, " nil_val: ", val)
        }
    }
--- request
GET /t
--- response_body_like
ttl: \d* val: 123
ttl: \d* nil_val: nil
--- no_error_log
[error]
