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

            local ok, err = pcall(cache.delete, cache, "foo")
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
no ipc to propagate deletion, specify ipc_shm
--- no_error_log
[error]



=== TEST 2: delete() validates key
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache", {
                ipc_shm = "ipc",
            }))

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

            -- set a value (callback call)

            local data = assert(cache:get("key", nil, cb))
            ngx.say("from callback: ", data)

            -- get a value (no callback call)

            data = assert(cache:get("key", nil, cb))
            ngx.say("from LRU: ", data)

            -- test if value is set from shm (safer to check due to the key)

            local v = ngx.shared.cache:get(cache.namespace .. "key")
            ngx.say("shm has value before delete: ", v ~= nil)

            -- delete the value

            assert(cache:delete("key"))

            local v = ngx.shared.cache:get(cache.namespace .. "key")
            ngx.say("shm has value after delete: ", v ~= nil)

            -- ensure LRU was also deleted

            v = cache.lru:get("key")
            ngx.say("from LRU: ", v)

            -- start over from callback again

            value = 456

            data = assert(cache:get("key", nil, cb))
            ngx.say("from callback: ", data)
        }
    }
--- request
GET /t
--- response_body
in callback
from callback: 123
from LRU: 123
shm has value before delete: true
shm has value after delete: false
from LRU: nil
in callback
from callback: 456
--- no_error_log
[error]



=== TEST 4: delete() invalidates other workers' LRU cache
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache", {
                ipc_shm = "ipc",
                debug   = true, -- allows same worker to receive its own published events
            }))

            cache.ipc:subscribe("lua-resty-mlcache:invalidations:" .. cache.namespace, function(data)
                ngx.say("received event from invalidations: ", data)
            end)

            assert(cache:delete("my_key"))

            assert(cache:update())
        }
    }
--- request
GET /t
--- response_body
received event from invalidations: my_key
--- no_error_log
[error]
