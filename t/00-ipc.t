# vim:set ts=4 sts=4 sw=4 et ft=:

use strict;
use lib '.';
use t::TestMLCache;

plan tests => repeat_each() * blocks() * 5;

run_tests();

__DATA__

=== TEST 1: new() ensures shm exists
--- config
    location /t {
        content_by_lua_block {
            local mlcache_ipc = require "resty.mlcache.ipc"

            local ipc, err = mlcache_ipc.new("foo")
            ngx.say(err)
        }
    }
--- response_body
no such lua_shared_dict: foo
--- no_error_log
[error]
[crit]
[alert]



=== TEST 2: broadcast() sends an event through shm
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "received event from my_channel: ", data)
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "hello world"))
            assert(ipc:poll())
        }
    }
--- ignore_response_body
--- error_log
received event from my_channel: hello world
--- no_error_log
[error]
[crit]
[alert]



=== TEST 3: broadcast() runs event callback in protected mode
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

        ipc:subscribe("my_channel", function(data)
            error("my callback had an error")
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "hello world"))
            assert(ipc:poll())
        }
    }
--- ignore_response_body
--- error_log eval
qr/\[error\] .*? \[ipc\] callback for channel 'my_channel' threw a Lua error: init_worker_by_lua(.*?)?:\d: my callback had an error/
--- no_error_log
lua entry thread aborted: runtime error
[crit]
[alert]



=== TEST 4: poll() catches invalid timeout arg
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))
    }
--- config
    location /t {
        content_by_lua_block {
            local ok, err = pcall(ipc.poll, ipc, false)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- response_body
timeout must be a number
--- no_error_log
[error]
[crit]
[alert]



=== TEST 5: poll() catches up with all events
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "received event from my_channel: ", data)
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "msg 1"))
            assert(ipc:broadcast("my_channel", "msg 2"))
            assert(ipc:broadcast("my_channel", "msg 3"))
            assert(ipc:poll())
        }
    }
--- ignore_response_body
--- error_log
received event from my_channel: msg 1
received event from my_channel: msg 2
received event from my_channel: msg 3
--- no_error_log
[error]



=== TEST 6: poll() resumes to current idx if events were previously evicted
This ensures new workers spawned during a master process' lifecycle do not
attempt to replay all events from index 0.
https://github.com/thibaultcha/lua-resty-mlcache/issues/87
https://github.com/thibaultcha/lua-resty-mlcache/issues/93
--- http_config
    lua_shared_dict  ipc_shm 32k;

    init_by_lua_block {
        require "resty.core"
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "my_channel event: ", data)
        end)

        for i = 1, 32 do
            -- fill shm, simulating busy workers
            -- this must trigger eviction for this test to succeed
            assert(ipc:broadcast("my_channel", string.rep(".", 2^10)))
        end
    }
--- config
    location /t {
        content_by_lua_block {
            ngx.say("ipc.idx: ", ipc.idx)

            assert(ipc:broadcast("my_channel", "first broadcast"))
            assert(ipc:broadcast("my_channel", "second broadcast"))

            -- first poll without new() to simulate new worker
            assert(ipc:poll())

            -- ipc.idx set to shm_idx-1 ("second broadcast")
            ngx.say("ipc.idx: ", ipc.idx)
        }
    }
--- response_body
ipc.idx: 0
ipc.idx: 34
--- error_log
my_channel event: second broadcast
--- no_error_log
my_channel event: first broadcast
[error]



=== TEST 7: poll() does not execute events from self (same pid)
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm"))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "received event from my_channel: ", data)
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "hello world"))
            assert(ipc:poll())
        }
    }
--- ignore_response_body
--- no_error_log
received event from my_channel: hello world
[error]
[crit]
[alert]



=== TEST 8: poll() runs all registered callbacks for a channel
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

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
--- config
    location /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "hello world"))
            assert(ipc:poll())
        }
    }
--- ignore_response_body
--- error_log
callback 1 from my_channel: hello world
callback 2 from my_channel: hello world
callback 3 from my_channel: hello world
--- no_error_log
[error]



=== TEST 9: poll() exits when no event to poll
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "callback from my_channel: ", data)
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            assert(ipc:poll())
        }
    }
--- ignore_response_body
--- no_error_log
callback from my_channel: hello world
[error]
[crit]
[alert]



=== TEST 10: poll() runs all callbacks from all channels
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

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
--- config
    location /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "hello world"))
            assert(ipc:broadcast("other_channel", "hello ipc"))
            assert(ipc:broadcast("other_channel", "hello ipc 2"))
            assert(ipc:poll())
        }
    }
--- ignore_response_body
--- grep_error_log eval: qr/callback \d+ from [^,]*/
--- grep_error_log_out
callback 1 from my_channel: hello world
callback 2 from my_channel: hello world
callback 1 from other_channel: hello ipc
callback 2 from other_channel: hello ipc
callback 1 from other_channel: hello ipc 2
callback 2 from other_channel: hello ipc 2
--- no_error_log
[error]
[crit]
[alert]



=== TEST 11: poll() catches tampered shm (by third-party users)
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))
    }
--- config
    location /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "msg 1"))

            assert(ngx.shared.ipc_shm:set("lua-resty-ipc:index", false))

            local ok, err = ipc:poll()
            if not ok then
                ngx.say(err)
            end
        }
    }
--- response_body
index is not a number, shm tampered with
--- no_error_log
[error]
[crit]
[alert]



=== TEST 12: poll() retries getting an event until timeout
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))
    }
--- config
    location /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "msg 1"))

            ngx.shared.ipc_shm:delete(1)
            ngx.shared.ipc_shm:flush_expired()

            local ok, err = ipc:poll()
            if not ok then
                ngx.log(ngx.ERR, "could not poll: ", err)
            end
        }
    }
--- ignore_response_body
--- grep_error_log eval: qr/((\[error\] .*?)|(\[ipc\] no event data at index '\d+', retrying .*?))[^,]*/
--- grep_error_log_out eval
qr/\[ipc\] no event data at index '1', retrying in: 0\.001s
\[ipc\] no event data at index '1', retrying in: 0\.002s
\[ipc\] no event data at index '1', retrying in: 0\.004s
\[ipc\] no event data at index '1', retrying in: 0\.008s
\[ipc\] no event data at index '1', retrying in: 0\.016s
\[ipc\] no event data at index '1', retrying in: 0\.032s
\[ipc\] no event data at index '1', retrying in: 0\.064s
\[ipc\] no event data at index '1', retrying in: 0\.128s
\[ipc\] no event data at index '1', retrying in: 0\.045s
\[error\] .*? could not poll: timeout/
--- no_error_log
[warn]
[crit]
[alert]



=== TEST 13: poll() reaches custom timeout
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))
    }
--- config
    location /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "msg 1"))

            ngx.shared.ipc_shm:delete(1)
            ngx.shared.ipc_shm:flush_expired()

            local ok, err = ipc:poll(0.01)
            if not ok then
                ngx.log(ngx.ERR, "could not poll: ", err)
            end
        }
    }
--- ignore_response_body
--- grep_error_log eval: qr/((\[error\] .*?)|(\[ipc\] no event data at index '\d+', retrying .*?))[^,]*/
--- grep_error_log_out eval
qr/\[ipc\] no event data at index '1', retrying in: 0\.001s
\[ipc\] no event data at index '1', retrying in: 0\.002s
\[ipc\] no event data at index '1', retrying in: 0\.004s
\[ipc\] no event data at index '1', retrying in: 0\.003s
\[error\] .*? could not poll: timeout/
--- no_error_log
[warn]
[crit]
[alert]



=== TEST 14: poll() logs errors and continue if event has been tampered with
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "callback from my_channel: ", data)
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            assert(ipc:broadcast("my_channel", "msg 1"))
            assert(ipc:broadcast("my_channel", "msg 2"))

            assert(ngx.shared.ipc_shm:set(1, false))

            assert(ipc:poll())
        }
    }
--- ignore_response_body
--- error_log eval
[
    qr/\[error\] .*? \[ipc\] event at index '1' is not a string, shm tampered with/,
    qr/\[notice\] .*? callback from my_channel: msg 2/,
]
--- no_error_log
[warn]
[crit]



=== TEST 15: poll() is safe to be called in contexts that don't support ngx.sleep()
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "callback from my_channel: ", data)
        end)
    }
--- config
    location /t {
        return 200;

        log_by_lua_block {
            assert(ipc:broadcast("my_channel", "msg 1"))

            ngx.shared.ipc_shm:delete(1)
            ngx.shared.ipc_shm:flush_expired()

            local ok, err = ipc:poll()
            if not ok then
                ngx.log(ngx.ERR, "could not poll: ", err)
            end
        }
    }
--- ignore_response_body
--- error_log eval
[
    qr/\[info\] .*? \[ipc\] no event data at index '1', retrying in: 0\.001s/,
    qr/\[warn\] .*? \[ipc\] could not sleep before retry: API disabled in the context of log_by_lua/,
    qr/\[error\] .*? could not poll: timeout/,
]
--- no_error_log
[crit]



=== TEST 16: poll() guards self.idx from growing beyond the current shm idx
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "callback from my_channel: ", data)
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            assert(ipc:broadcast("other_channel", ""))
            assert(ipc:poll())
            assert(ipc:broadcast("my_channel", "fist broadcast"))
            assert(ipc:broadcast("other_channel", ""))
            assert(ipc:broadcast("my_channel", "second broadcast"))

            -- shm idx is 5, let's mess with the instance's idx
            ipc.idx = 10
            assert(ipc:poll())

            -- we may have skipped the above events, but we are able to resume polling
            assert(ipc:broadcast("other_channel", ""))
            assert(ipc:broadcast("my_channel", "third broadcast"))
            assert(ipc:poll())
        }
    }
--- ignore_response_body
--- error_log
callback from my_channel: third broadcast
--- no_error_log
callback from my_channel: first broadcast
callback from my_channel: second broadcast
[error]



=== TEST 17: poll() JITs
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "callback from my_channel: ", data)
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            for i = 1, 10e3 do
                assert(ipc:poll())
            end
        }
    }
--- ignore_response_body
--- error_log eval
qr/\[TRACE\s+\d+ content_by_lua\(nginx\.conf:\d+\):2 loop\]/
--- no_error_log
[warn]
[error]
[crit]



=== TEST 18: broadcast() JITs
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "callback from my_channel: ", data)
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            for i = 1, 10e3 do
                assert(ipc:broadcast("my_channel", "hello world"))
            end
        }
    }
--- ignore_response_body
--- error_log eval
qr/\[TRACE\s+\d+ content_by_lua\(nginx\.conf:\d+\):2 loop\]/
--- no_error_log
[warn]
[error]
[crit]



=== TEST 19: poll() steps over a run of lost events in a single call
Events whose index was consumed by broadcast()'s incr() but never stored, either
because the shm evicted them or because set() returned "no memory", leave a hole
that can never be filled. Skipping one index per call lets a busy writer outpace
the reader forever.
https://github.com/thibaultcha/lua-resty-mlcache/issues/87
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "my_channel event: ", data)
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            for i = 1, 5 do
                assert(ipc:broadcast("my_channel", "lost " .. i))
            end

            assert(ipc:broadcast("my_channel", "survivor"))

            -- events 1 through 5 are gone, 6 is still in the shm
            for i = 1, 5 do
                ngx.shared.ipc_shm:delete(i)
            end
            ngx.shared.ipc_shm:flush_expired()

            local ok, err = ipc:poll()
            ngx.say("poll: ", ok, " ", err)
            ngx.say("ipc.idx: ", ipc.idx)

            assert(ipc:poll())
            ngx.say("ipc.idx: ", ipc.idx)
        }
    }
--- response_body
poll: nil timeout
ipc.idx: 5
ipc.idx: 6
--- error_log
my_channel event: survivor
--- no_error_log
[crit]
[alert]



=== TEST 20: poll() steps over a run of lost events longer than the scan cap
A run of holes longer than MAX_HOLE_SCAN (1000) cannot be skipped in one call:
the scan runs out of budget and poll() resumes where it stopped, so a run of
2,500 lost events costs 3 polls (2 scans hitting the cap + 1 finding the
surviving event at index 2,501) instead of 2,500 timeouts.
https://github.com/thibaultcha/lua-resty-mlcache/issues/130
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "my_channel event: ", data)
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            for i = 1, 2500 do
                assert(ipc:broadcast("my_channel", "lost " .. i))
            end

            assert(ipc:broadcast("my_channel", "survivor"))

            -- events 1 through 2500 are gone, 2501 is still in the shm
            for i = 1, 2500 do
                ngx.shared.ipc_shm:delete(i)
            end
            ngx.shared.ipc_shm:flush_expired()

            -- first poll: burns the timeout at index 1, then scans 1000
            -- holes and resumes at index 1001
            local ok, err = ipc:poll()
            ngx.say("poll 1: ", ok, " ", err)
            ngx.say("ipc.idx: ", ipc.idx)

            -- second poll: same, resumes at index 2002
            local ok, err = ipc:poll()
            ngx.say("poll 2: ", ok, " ", err)
            ngx.say("ipc.idx: ", ipc.idx)

            -- third poll: the scan finds the survivor at index 2501 and
            -- resumes at index 2500
            local ok, err = ipc:poll()
            ngx.say("poll 3: ", ok, " ", err)
            ngx.say("ipc.idx: ", ipc.idx)

            assert(ipc:poll())
            ngx.say("ipc.idx: ", ipc.idx)
        }
    }
--- response_body
poll 1: nil timeout
ipc.idx: 1001
poll 2: nil timeout
ipc.idx: 2002
poll 3: nil timeout
ipc.idx: 2500
ipc.idx: 2501
--- error_log
my_channel event: survivor
--- no_error_log
[crit]
[alert]



=== TEST 21: poll() resumes at the current shm idx when no event survives
When the scan runs past the last index without finding a surviving event,
poll() must resume at the current shm idx so the next poll() does not re-scan
the drained run.
https://github.com/thibaultcha/lua-resty-mlcache/issues/130
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "my_channel event: ", data)
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            for i = 1, 5 do
                assert(ipc:broadcast("my_channel", "lost " .. i))
            end

            -- events 1 through 5 are gone, nothing survives
            for i = 1, 5 do
                ngx.shared.ipc_shm:delete(i)
            end
            ngx.shared.ipc_shm:flush_expired()

            local ok, err = ipc:poll()
            ngx.say("poll: ", ok, " ", err)
            ngx.say("ipc.idx: ", ipc.idx)

            -- the next poll must find nothing new to poll and return
            -- immediately
            assert(ipc:poll())
            ngx.say("ipc.idx: ", ipc.idx)

            -- and polling resumes normally for new events
            assert(ipc:broadcast("my_channel", "hello"))
            assert(ipc:poll())
            ngx.say("ipc.idx: ", ipc.idx)
        }
    }
--- response_body
poll: nil timeout
ipc.idx: 5
ipc.idx: 5
ipc.idx: 6
--- error_log
my_channel event: hello
--- no_error_log
[crit]
[alert]


=== TEST 22: poll() steps over the hole left by a broadcast() set() failure
A set() that returns "no memory" leaves the same unfillable hole as an evicted
event: broadcast() consumed the index at incr() and returns before setting any
flag. The failing event is deliberately larger than the whole zone: no amount
of LRU eviction can free enough of it, so set() deterministically fails with
"no memory". The subsequent poll() must step over that hole and deliver the
surviving events around it.
https://github.com/thibaultcha/lua-resty-mlcache/issues/130
https://github.com/thibaultcha/lua-resty-mlcache/issues/129
--- http_config
    lua_shared_dict  ipc_shm 64k;

    init_by_lua_block {
        require "resty.core"

        local dict = ngx.shared.ipc_shm

        -- fill the shm with filler keys of the same size class as the events
        -- below (the filler keys are 9 bytes and the events' marshalled
        -- values ~69 bytes, so both nodes land in the 128-byte slab class):
        -- set() evicts LRU fillers as needed and never fails, so the zone
        -- ends up full of a single class. The loop is bounded because a
        -- same-class set() can never fail
        local i = 0
        while i < 2000 do
            local ok = dict:set("filler" .. i, string.rep(".", 56))
            if not ok then
                break
            end
            i = i + 1
        end

        -- free a few filler-class slots for the events below, so that the
        -- events themselves are stored without any eviction (and thus
        -- without setting the forcible flag)
        for j = 0, 19 do
            dict:delete("filler" .. j)
        end
    }

    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "my_channel event: ", data)
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            -- small events consume indexes 1 through 8; poll them first so
            -- the subsequent poll() below runs with a warm (non-zero) idx
            for i = 1, 8 do
                assert(ipc:broadcast("my_channel", "event " .. i .. ":"
                    .. string.rep(".", 40)))
            end
            assert(ipc:poll())

            -- a 70KB event needs more whole slab pages than the 64k zone can
            -- ever hold, so set() must fail with "no memory" no matter how
            -- many items it evicts, consuming index 9 without storing
            -- anything
            local ok, err = ipc:broadcast("my_channel", "lost:"
                .. string.rep(".", 70 * 1024))
            ngx.say("broadcast: ", ok, " ", err)

            -- index 9 is a hole; the two events below are small again
            assert(ipc:broadcast("my_channel", "survivor 1"))
            assert(ipc:broadcast("my_channel", "survivor 2"))

            local ok, err = ipc:poll()
            ngx.say("poll: ", ok, " ", err)
            ngx.say("ipc.idx: ", ipc.idx)

            assert(ipc:poll())
            ngx.say("ipc.idx: ", ipc.idx)
        }
    }
--- response_body
broadcast: nil failed to insert event in shm: no memory
poll: nil timeout
ipc.idx: 9
ipc.idx: 11
--- error_log
my_channel event: survivor 1
my_channel event: survivor 2
--- no_error_log
[crit]



=== TEST 23: a failed broadcast() sets the forcible flag for new workers
When set() fails with "no memory", the index is consumed but nothing is
stored, leaving a hole just like an evicted event: broadcast() must raise
the FORCIBLE_KEY flag on that failure path too, so that a worker spawned
afterwards skips the lost run instead of replaying it.

The failed event is deliberately larger than the whole zone, so its set()
drains the LRU queue (30 forced evictions) without ever finding room and
fails with "no memory", evicting INDEX_KEY along the way. The two survivor
broadcasts then restart the index at 1 and 2. A worker spawned after the
failure polls from idx 0: with the flag set it must skip straight to
survivor 2; without it, it would replay survivor 1.
--- http_config
    init_worker_by_lua_block {
        local mlcache_ipc = require "resty.mlcache.ipc"

        ipc = assert(mlcache_ipc.new("ipc_shm", true))

        ipc:subscribe("my_channel", function(data)
            ngx.log(ngx.NOTICE, "my_channel event: ", data)
        end)
    }
--- config
    location /t {
        content_by_lua_block {
            -- events consume indexes 1 through 8
            for i = 1, 8 do
                assert(ipc:broadcast("my_channel", "event " .. i .. ":"
                    .. string.rep(".", 40)))
            end

            assert(ngx.shared.ipc_shm:get("lua-resty-ipc:forcible") == nil)

            -- a 2MB event cannot ever fit the 1m zone: set() fails with
            -- "no memory" after draining the LRU queue, consuming index 9
            -- without storing anything, and the failure path sets the
            -- FORCIBLE_KEY flag
            local ok, err = ipc:broadcast("my_channel", "lost:"
                .. string.rep(".", 2 * 1024 * 1024))
            ngx.say("broadcast: ", ok, " ", err)
            ngx.say("forcible: ", ngx.shared.ipc_shm:get("lua-resty-ipc:forcible"))
            ngx.say("index: ", ngx.shared.ipc_shm:get("lua-resty-ipc:index"))

            assert(ipc:broadcast("my_channel", "survivor 1"))
            assert(ipc:broadcast("my_channel", "survivor 2"))

            -- simulate a worker spawned after the failure: it must skip
            -- indexes 1 and 2 and resume at the current shm index
            local new_worker = assert(require("resty.mlcache.ipc")
                .new("ipc_shm", true))
            new_worker:subscribe("my_channel", function(data)
                ngx.log(ngx.NOTICE, "new worker event: ", data)
            end)

            assert(new_worker:poll())
            ngx.say("new worker idx: ", new_worker.idx)
        }
    }
--- response_body
broadcast: nil failed to insert event in shm: no memory
forcible: true
index: nil
new worker idx: 2
--- error_log
new worker event: survivor 2
--- no_error_log
new worker event: survivor 1
[crit]
