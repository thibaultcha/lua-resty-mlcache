
# vim:set ts=4 sts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(2);

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 3) + 1;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  cache 1m;
    lua_shared_dict  ipc   1m;

    init_by_lua_block {
        -- tamper with shm record and set a different pid
        function unset_pid(ipc, idx)
            local v = assert(ngx.shared.ipc:get(idx))
            if not v then return end
            local event = ipc.unmarshall(v)
            event.pid   = 0
            assert(ngx.shared.ipc:set(idx, ipc.marshall(event)))
        end
    }
};

run_tests();

__DATA__

=== TEST 1: update() errors if no ipc_shm
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache"))

            local ok, err = cache:update("foo")
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
no ipc to update from
--- no_error_log
[error]



=== TEST 2: update() catches up with invalidation events
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache", {
                ipc_shm = "ipc",
                debug = true
            }))

            cache.ipc:subscribe("lua-resty-mlcache:invalidations", function(data)
                ngx.log(ngx.NOTICE, "received event from invalidations: ", data)
            end)

            assert(cache:delete("my_key"))

            unset_pid(cache.ipc, 1)

            assert(cache:update())
        }
    }
--- request
GET /t
--- response_body

--- no_error_log
[error]
--- error_log
received event from invalidations: my_key
