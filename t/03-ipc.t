
# vim:set ts=4 sts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(1);

plan tests => repeat_each() * (blocks() * 5);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  ipc 1m;

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



=== TEST 3: broadcast() runs event callback in protected mode
--- http_config eval
qq{
    $::HttpConfig

    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc", true))

        ipc:subscribe("my_channel", function(data)
            error("my callback had an error")
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

--- error_log eval
qr/\[error\] .*? \[ipc\] callback for channel 'my_channel' threw a Lua error: init_worker_by_lua:\d: my callback had an error/
--- no_error_log
lua entry thread aborted: runtime error



=== TEST 4: poll() catches invalid max_event_wait arg
--- http_config eval
qq{
    $::HttpConfig

    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc", true))
    }
}
--- config
    location = /t {
        content_by_lua_block {
            local ok, err = ipc:poll(false)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
max_event_wait must be a number
--- no_error_log
[error]



=== TEST 5: poll() catches up with all events
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



=== TEST 6: poll() does not execute events from self (same pid)
--- http_config eval
qq{
    $::HttpConfig

    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc"))

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



=== TEST 7: poll() runs all registered callbacks for a channel
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



=== TEST 8: poll() exits when no event to poll
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



=== TEST 9: poll() runs all callbacks from all channels
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



=== TEST 10: poll() catches tampered shm (by third-party users)
--- http_config eval
qq{
    $::HttpConfig

    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc", true))
    }
}
--- config
    location = /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "msg 1"))

            assert(ngx.shared.ipc:set("lua-resty-ipc:index", false))

            local ok, err = ipc:poll()
            if not ok then
                ngx.say(err)
            end
        }
    }
--- request
GET /t
--- response_body
index is not a number, shm tampered with
--- no_error_log
[error]



=== TEST 11: poll() retries getting an event if not yet inserted
--- http_config eval
qq{
    $::HttpConfig

    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc", true))
    }
}
--- config
    location = /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "msg 1"))

            ngx.shared.ipc:delete(1)
            ngx.shared.ipc:flush_expired()

            ipc:poll()
        }
    }
--- request
GET /t
--- response_body

--- error_log eval
[
    qr/\[info\] .*? \[ipc\] no event data at index '1', retrying in: 0\.001s/,
    qr/\[info\] .*? \[ipc\] no event data at index '1', retrying in: 0\.002s/,
    qr/\[info\] .*? \[ipc\] no event data at index '1', retrying in: 0\.004s/,
    qr/\[info\] .*? \[ipc\] no event data at index '1', retrying in: 0\.008s/,
    qr/\[info\] .*? \[ipc\] no event data at index '1', retrying in: 0\.016s/,
    qr/\[info\] .*? \[ipc\] no event data at index '1', retrying in: 0\.032s/,
    qr/\[info\] .*? \[ipc\] no event data at index '1', retrying in: 0\.064s/,
    qr/\[info\] .*? \[ipc\] no event data at index '1', retrying in: 0\.128s/,
    qr/\[info\] .*? \[ipc\] no event data at index '1', retrying in: 0\.045s/,
    qr/\[error\] .*? \[ipc\] could not get event at index: '1'/,
]



=== TEST 12: poll() get event retries never exceeds max_sleep
--- http_config eval
qq{
    $::HttpConfig

    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc", true))
    }
}
--- config
    location = /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "msg 1"))

            ngx.shared.ipc:delete(1)
            ngx.shared.ipc:flush_expired()

            ipc:poll(0.01)
        }
    }
--- request
GET /t
--- response_body

--- error_log eval
[
    qr/\[info\] .*? \[ipc\] no event data at index '1', retrying in: 0\.001s/,
    qr/\[info\] .*? \[ipc\] no event data at index '1', retrying in: 0\.002s/,
    qr/\[info\] .*? \[ipc\] no event data at index '1', retrying in: 0\.004s/,
    qr/\[info\] .*? \[ipc\] no event data at index '1', retrying in: 0\.003s/,
    qr/\[error\] .*? \[ipc\] could not get event at index: '1'/,
]



=== TEST 13: poll() logs errors and continue if event has been tampered with
--- http_config eval
qq{
    $::HttpConfig

    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc", true))

        ipc:subscribe("my_channel", function(data)
        print("HERE")
            ngx.log(ngx.NOTICE, "callback from my_channel: ", data)
        end)
    }
}
--- config
    location = /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "msg 1"))
            assert(ipc:broadcast("my_channel", "msg 2"))

            assert(ngx.shared.ipc:set(1, false))

            assert(ipc:poll())
        }
    }
--- request
GET /t
--- response_body

--- error_log eval
[
    qr/\[error\] .*? \[ipc\] event at index '1' is not a string, shm tampered with/,
    qr/\[notice\] .*? callback from my_channel: msg 2/,
]



=== TEST 14: poll() is safe to be called in contexts that don't support ngx.sleep()
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
        return 200;

        log_by_lua_block {
            assert(ipc:broadcast("my_channel", "msg 1"))

            ngx.shared.ipc:delete(1)
            ngx.shared.ipc:flush_expired()

            assert(ipc:poll())
        }
    }
--- request
GET /t
--- response_body

--- error_log eval
[
    qr/\[info\] .*? \[ipc\] no event data at index '1', retrying in: 0\.001s/,
    qr/\[warn\] .*? \[ipc\] could not sleep before retry: API disabled in the context of log_by_lua/,
    qr/\[error\] .*? \[ipc\] could not get event at index: '1'/,
]



=== TEST 15: poll() JITs
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
            for i = 1, 10e3 do
                assert(ipc:poll())
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log eval
qr/\[TRACE   \d+ content_by_lua\(nginx\.conf:\d+\):2 loop\]/



=== TEST 16: broadcast() JITs
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
            for i = 1, 10e3 do
                assert(ipc:broadcast("my_channel", "hello world"))
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log eval
qr/\[TRACE   \d+ content_by_lua\(nginx\.conf:\d+\):2 loop\]/
