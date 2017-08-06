# vim:set ts=4 sts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(2);

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 3) + 2;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  cache 1m;
    lua_shared_dict  ipc   1m;

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
                debug = true -- allows same worker to receive its own published events
            }))

            cache.ipc:subscribe("lua-resty-mlcache:invalidations:" .. cache.namespace, function(data)
                ngx.log(ngx.NOTICE, "received event from invalidations: ", data)
            end)

            assert(cache:delete("my_key"))

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



=== TEST 3: update() JITs when no events to catch up
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("cache", {
                ipc_shm = "ipc",
            }))

            for i = 1, 10e3 do
                assert(cache:update())
            end
        }
    }
--- request
GET /t
--- response_body

--- no_error_log
[error]
--- error_log eval
qr/\[TRACE   \d+ content_by_lua\(nginx\.conf:\d+\):8 loop\]/
