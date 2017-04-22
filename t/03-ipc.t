
# vim:set ts=4 sts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * (blocks() * 4) + 8;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  ipc 1m;

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

=== TEST 1: new() ensures shm exists
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache_ipc = require "resty.mlcache.ipc"

            local ipc, err = mlcache_ipc.new("foo")
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body
no such lua_shared_dict: foo
--- no_error_log
[error]



=== TEST 2: broadcast() sends an event through shm
--- http_config eval
qq{
    $::HttpConfig

    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "received event from my_channel: ", data)
        end)
    }
}
--- config
    location = /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "hello world"))

            unset_pid(ipc, 1)

            assert(ipc:poll())
        }
    }
--- request
GET /t
--- response_body

--- no_error_log
[error]
--- error_log
received event from my_channel: hello world



=== TEST 3: poll() catches up with all events
--- http_config eval
qq{
    $::HttpConfig

    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "received event from my_channel: ", data)
        end)
    }
}
--- config
    location = /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "msg 1"))
            assert(ipc:broadcast("my_channel", "msg 2"))
            assert(ipc:broadcast("my_channel", "msg 3"))

            unset_pid(ipc, 1)
            unset_pid(ipc, 2)
            unset_pid(ipc, 3)

            assert(ipc:poll())
        }
    }
--- request
GET /t
--- response_body

--- no_error_log
[error]
--- error_log
received event from my_channel: msg 1
received event from my_channel: msg 2
received event from my_channel: msg 3



=== TEST 4: poll() does not execute events from self (same pid)
--- http_config eval
qq{
    $::HttpConfig

    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "received event from my_channel: ", data)
        end)
    }
}
--- config
    location = /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "hello world"))

            assert(ipc:poll())
        }
    }
--- request
GET /t
--- response_body

--- no_error_log
[error]
received event from my_channel: hello world



=== TEST 5: poll() runs all registered callbacks for a channel
--- http_config eval
qq{
    $::HttpConfig

    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "callback 1 from my_channel: ", data)
        end)

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "callback 2 from my_channel: ", data)
        end)

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "callback 3 from my_channel: ", data)
        end)
    }
}
--- config
    location = /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "hello world"))

            unset_pid(ipc, 1)

            assert(ipc:poll())
        }
    }
--- request
GET /t
--- response_body

--- no_error_log
[error]
--- error_log
callback 1 from my_channel: hello world
callback 2 from my_channel: hello world
callback 3 from my_channel: hello world



=== TEST 6: poll() exits when no event to poll
--- http_config eval
qq{
    $::HttpConfig

    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "callback from my_channel: ", data)
        end)
    }
}
--- config
    location = /t {
        content_by_lua_block {
            assert(ipc:poll())
        }
    }
--- request
GET /t
--- response_body

--- no_error_log
[error]
callback from my_channel: hello world



=== TEST 7: poll() runs all callbacks from all channels
--- http_config eval
qq{
    $::HttpConfig

    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "callback 1 from my_channel: ", data)
        end)

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "callback 2 from my_channel: ", data)
        end)

        ipc:subscribe("other_channel", function(data)
            ngx.log(ngx.NOTICE, "callback 1 from other_channel: ", data)
        end)

        ipc:subscribe("other_channel", function(data)
            ngx.log(ngx.NOTICE, "callback 2 from other_channel: ", data)
        end)
    }
}
--- config
    location = /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "hello world"))
            assert(ipc:broadcast("other_channel", "hello ipc"))
            assert(ipc:broadcast("other_channel", "hello ipc 2"))

            unset_pid(ipc, 1)
            unset_pid(ipc, 2)
            unset_pid(ipc, 3)

            assert(ipc:poll())
        }
    }
--- request
GET /t
--- response_body

--- no_error_log
[error]
--- error_log
callback 1 from my_channel: hello world
callback 2 from my_channel: hello world
callback 1 from other_channel: hello ipc
callback 2 from other_channel: hello ipc
callback 1 from other_channel: hello ipc 2
callback 2 from other_channel: hello ipc 2
