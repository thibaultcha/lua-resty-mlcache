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
    lua_shared_dict  ipc   1m;
};

run_tests();

__DATA__

=== TEST 1: delete() errors if no ipc module
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache"))

            local ok, err = cache:delete("foo")
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
no ipc to propagate deletion
--- no_error_log
[error]



=== TEST 2: delete() validates key
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache"))

            local ok, err = pcall(cache.delete, cache, 123)
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
key must be a string
--- no_error_log
[error]



=== TEST 3: delete() removes a cached value from LRU + shm
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache", { ipc_shm = "ipc" }))

            local value = 123

            local function cb()
                ngx.say("in callback")
                return value
            end

            local data = assert(cache:get("key", nil, cb))
            ngx.say(data)

            data = assert(cache:get("key", nil, cb))
            ngx.say(data)

            assert(cache:delete("key"))

            local v = ngx.shared.cache:get("key")
            ngx.say(v)

            -- ensure LRU was also deleted
            value = 456

            data = assert(cache:get("key", nil, cb))
            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body
in callback
123
123
nil
in callback
456
--- no_error_log
[error]
