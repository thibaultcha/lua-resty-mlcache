# vim:set ts=4 sts=4 sw=4 et ft=:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3 + 3);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  cache_shm      1m;
    lua_shared_dict  cache_shm_miss 1m;
};

no_long_string();
log_level('warn');

run_tests();

__DATA__

=== TEST 1: new() validates 'opts.resurrect_ttl' (number && >= 0)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local pok, perr = pcall(mlcache.new, "my_mlcache", "cache_shm", {
                resurrect_ttl = "",
            })
            if not pok then
                ngx.say(perr)
            end

            local pok, perr = pcall(mlcache.new, "my_mlcache", "cache_shm", {
                resurrect_ttl = -1,
            })
            if not pok then
                ngx.say(perr)
            end
        }
    }
--- request
GET /t
--- response_body
opts.resurrect_ttl must be a number
opts.resurrect_ttl must be >= 0
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
                resurrect_ttl = "",
            }, cb)
            if not pok then
                ngx.say(perr)
            end

            local pok, perr = pcall(cache.get, cache, "key", {
                resurrect_ttl = -1,
            }, cb)
            if not pok then
                ngx.say(perr)
            end
        }
    }
--- request
GET /t
--- response_body
opts.resurrect_ttl must be a number
opts.resurrect_ttl must be >= 0
--- no_error_log
[error]



=== TEST 3: get() resurrects a stale value upon callback soft error for 'resurrect_ttl' instance option
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ttl = 0.3,
                resurrect_ttl = 0.2,
            }))

            local cb_called = 0

            local function cb()
                cb_called = cb_called + 1

                if cb_called == 1 then
                    return 123

                elseif cb_called == 2 then
                    return nil, "some error"

                elseif cb_called == 3 then
                    return 456
                end
            end

            ngx.say("-> 1st get()")
            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say("data: ", data)

            ngx.say()
            ngx.say("sleeping for 0.3s...")
            ngx.sleep(0.3)
            ngx.say()

            ngx.say("-> stale get()")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags))
            ngx.say("resurrected: ", mlcache.resurrected(flags))
            ngx.say("stale: ", mlcache.stale(flags))

            ngx.say()
            ngx.say("-> subsequent get() from LRU")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags))
            ngx.say("resurrected: ", mlcache.resurrected(flags))
            ngx.say("stale: NYI") -- NYI in L1

            ngx.say()
            ngx.say("-> subsequent get() from shm")
            cache.lru:delete("key")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags))
            ngx.say("resurrected: ", mlcache.resurrected(flags))
            ngx.say("stale: ", mlcache.stale(flags))

            ngx.say()
            ngx.say("sleeping for 0.2s...")
            ngx.sleep(0.21)
            ngx.say()

            ngx.say("-> successfull callback get()")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags))
            ngx.say("resurrected: ", mlcache.resurrected(flags))
            ngx.say("stale: ", mlcache.stale(flags))
        }
    }
--- request
GET /t
--- response_body
-> 1st get()
data: 123

sleeping for 0.3s...

-> stale get()
data: 123
err: nil
hit_lvl: 2
resurrected: true
stale: true

-> subsequent get() from LRU
data: 123
err: nil
hit_lvl: 1
resurrected: false
stale: NYI

-> subsequent get() from shm
data: 123
err: nil
hit_lvl: 2
resurrected: false
stale: true

sleeping for 0.2s...

-> successfull callback get()
data: 456
err: nil
hit_lvl: 3
resurrected: false
stale: false
--- no_error_log
[error]



=== TEST 4: get() logs soft callback error with warn level when resurrecting
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ttl = 0.3,
                resurrect_ttl = 0.2,
            }))

            local cb_called = 0

            local function cb()
                cb_called = cb_called + 1

                if cb_called == 1 then
                    return 123

                elseif cb_called == 2 then
                    return nil, "some error"

                elseif cb_called == 3 then
                    return 456
                end
            end

            ngx.say("-> 1st get()")
            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say("data: ", data)

            ngx.say()
            ngx.say("sleeping for 0.3s...")
            ngx.sleep(0.3)
            ngx.say()

            ngx.say("-> stale get()")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("resurrected: ", mlcache.resurrected(flags))
        }
    }
--- request
GET /t
--- response_body
-> 1st get()
data: 123

sleeping for 0.3s...

-> stale get()
data: 123
err: nil
resurrected: true
--- error_log eval
qr/\[warn\] .*? callback returned an error \(some error\) but stale value found/



=== TEST 5: get() accepts 'opts.resurrect_ttl' option to override instance option
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ttl = 0.3,
                resurrect_ttl = 0.8,
            }))

            local cb_called = 0

            local function cb()
                cb_called = cb_called + 1

                if cb_called == 1 then
                    return 123

                else
                    return nil, "some error"
                end
            end

            ngx.say("-> 1st get()")
            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say("data: ", data)

            ngx.say()
            ngx.say("sleeping for 0.3s...")
            ngx.sleep(0.3)
            ngx.say()

            ngx.say("-> stale get()")
            data, err, flags = cache:get("key", {
                resurrect_ttl = 0.2
            }, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("resurrected: ", mlcache.resurrected(flags))

            ngx.say()
            ngx.say("sleeping for 0.2s...")
            ngx.sleep(0.21)
            ngx.say()

            ngx.say("-> subsequent stale get()")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("resurrected: ", mlcache.resurrected(flags))
        }
    }
--- request
GET /t
--- response_body
-> 1st get()
data: 123

sleeping for 0.3s...

-> stale get()
data: 123
err: nil
resurrected: true

sleeping for 0.2s...

-> subsequent stale get()
data: 123
err: nil
resurrected: true
--- no_error_log
[error]



=== TEST 6: get() resurrects a nil stale value (negative cache)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                neg_ttl = 0.3,
                resurrect_ttl = 0.2,
            }))

            local cb_called = 0

            local function cb()
                cb_called = cb_called + 1

                if cb_called == 1 then
                    return nil

                elseif cb_called == 2 then
                    return nil, "some error"

                elseif cb_called == 3 then
                    return 456
                end
            end

            ngx.say("-> 1st get()")
            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say("data: ", data)

            ngx.say()
            ngx.say("sleeping for 0.3s...")
            ngx.sleep(0.3)
            ngx.say()

            ngx.say("-> stale get()")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags))
            ngx.say("resurrected: ", mlcache.resurrected(flags))

            ngx.say()
            ngx.say("-> subsequent get()")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags))

            ngx.say()
            ngx.say("sleeping for 0.2s...")
            ngx.sleep(0.21)
            ngx.say()

            ngx.say("-> successfull callback get()")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags))
        }
    }
--- request
GET /t
--- response_body
-> 1st get()
data: nil

sleeping for 0.3s...

-> stale get()
data: nil
err: nil
hit_lvl: 2
resurrected: true

-> subsequent get()
data: nil
err: nil
hit_lvl: 1

sleeping for 0.2s...

-> successfull callback get()
data: 456
err: nil
hit_lvl: 3
--- no_error_log
[error]



=== TEST 7: get() resurrects a nil stale value (negative cache) in 'opts.shm_miss'
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                neg_ttl = 0.3,
                resurrect_ttl = 0.2,
                shm_miss = "cache_shm_miss"
            }))

            local cb_called = 0

            local function cb()
                cb_called = cb_called + 1

                if cb_called == 1 then
                    return nil

                elseif cb_called == 2 then
                    return nil, "some error"

                elseif cb_called == 3 then
                    return 456
                end
            end

            ngx.say("-> 1st get()")
            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say("data: ", data)

            ngx.say()
            ngx.say("sleeping for 0.3s...")
            ngx.sleep(0.3)
            ngx.say()

            ngx.say("-> stale get()")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags))
            ngx.say("resurrected: ", mlcache.resurrected(flags))

            ngx.say()
            ngx.say("-> subsequent get()")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags))

            ngx.say()
            ngx.say("sleeping for 0.2s...")
            ngx.sleep(0.21)
            ngx.say()

            ngx.say("-> successfull callback get()")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags))
        }
    }
--- request
GET /t
--- response_body
-> 1st get()
data: nil

sleeping for 0.3s...

-> stale get()
data: nil
err: nil
hit_lvl: 2
resurrected: true

-> subsequent get()
data: nil
err: nil
hit_lvl: 1

sleeping for 0.2s...

-> successfull callback get()
data: 456
err: nil
hit_lvl: 3
--- no_error_log
[error]



=== TEST 8: get() ignores cb return values upon stale value resurrection
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ttl = 0.3,
                resurrect_ttl = 0.2,
            }))

            local cb_called = 0

            local function cb()
                cb_called = cb_called + 1

                if cb_called == 2 then
                    -- ignore ret values 1 and 3
                    return 456, "some error", 10

                else
                    return 123
                end
            end

            ngx.say("-> 1st get()")
            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say("data: ", data)

            ngx.say()
            ngx.say("sleeping for 0.3s...")
            ngx.sleep(0.3)
            ngx.say()

            ngx.say("-> stale get()")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags))
            ngx.say("resurrected: ", mlcache.resurrected(flags))

            ngx.say()
            ngx.say("-> subsequent get()")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags))

            ngx.say()
            ngx.say("sleeping for 0.2s...")
            ngx.sleep(0.21)
            ngx.say()

            ngx.say("-> successfull callback get()")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags))
        }
    }
--- request
GET /t
--- response_body
-> 1st get()
data: 123

sleeping for 0.3s...

-> stale get()
data: 123
err: nil
hit_lvl: 2
resurrected: true

-> subsequent get()
data: 123
err: nil
hit_lvl: 1

sleeping for 0.2s...

-> successfull callback get()
data: 123
err: nil
hit_lvl: 3
--- no_error_log
[error]



=== TEST 9: get() does not resurrect a stale value when callback throws error
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ttl = 0.3,
                resurrect_ttl = 0.2,
            }))

            local cb_called = 0

            local function cb()
                cb_called = cb_called + 1

                if cb_called == 1 then
                    return 123

                elseif cb_called == 2 then
                    error("thrown error")

                elseif cb_called == 3 then
                    return 123
                end
            end

            ngx.say("-> 1st get()")
            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say("data: ", data)

            ngx.say()
            ngx.say("sleeping for 0.3s...")
            ngx.sleep(0.3)
            ngx.say()

            ngx.say("-> stale get()")
            data, err = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", string.match(err, "callback threw an error:"), " ",
                    string.match(err, "thrown error"))

            ngx.say()
            ngx.say("-> subsequent get()")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags))
        }
    }
--- request
GET /t
--- response_body
-> 1st get()
data: 123

sleeping for 0.3s...

-> stale get()
data: nil
err: callback threw an error: thrown error

-> subsequent get()
data: 123
err: nil
hit_lvl: 3
--- no_error_log
[error]



=== TEST 10: get() returns error and data on lock timeout but does not resurrect
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            -- insert 2 dummy values to ensure that lock acquisition (which
            -- uses shm:set) will _not_ evict out stale cached value
            ngx.shared.cache_shm:set(1, true, 0.2)
            ngx.shared.cache_shm:set(2, true, 0.2)

            local mlcache = require "resty.mlcache"
            local cache_1 = assert(mlcache.new("my_mlcache", "cache_shm", {
                ttl = 0.3,
                resurrect_ttl = 0.3
            }))
            local cache_2 = assert(mlcache.new("my_mlcache", "cache_shm", {
                ttl = 0.3,
                resurrect_ttl = 0.3,
                resty_lock_opts = {
                    timeout = 0.2
                }
            }))

            local function cb(delay, return_val)
                if delay then
                    ngx.sleep(delay)
                end

                return return_val or 123
            end

            -- cache in shm

            local data, err, flags = cache_1:get("my_key", nil, cb)
            assert(data == 123)
            assert(err == nil)
            assert(mlcache.hit_level(flags) == 3)

            -- make shm + LRU expire

            ngx.sleep(0.3)

            local t1 = ngx.thread.spawn(function()
                -- trigger L3 callback again, but slow to return this time

                cache_1:get("my_key", nil, cb, 0.3, 456)
            end)

            local t2 = ngx.thread.spawn(function()
                -- make this mlcache wait on other's callback, and timeout

                local data, err, flags = cache_2:get("my_key", nil, cb)
                ngx.say("data: ", data)
                ngx.say("err: ", err)
                ngx.say("hit_lvl: ", mlcache.hit_level(flags))
                ngx.say("resurrected: ", mlcache.resurrected(flags))
                ngx.say("stale: ", mlcache.stale(flags))
            end)

            assert(ngx.thread.wait(t1))
            assert(ngx.thread.wait(t2))

            ngx.say()
            ngx.say("-> subsequent get()")
            data, err, flags = cache_2:get("my_key", nil, cb, nil, 123)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags)) -- should be 1 since LRU instances are shared by mlcache namespace, and t1 finished
        }
    }
--- request
GET /t
--- response_body
data: 123
err: nil
hit_lvl: 2
resurrected: false
stale: true

-> subsequent get()
data: 456
err: nil
hit_lvl: 1
--- no_error_log
[error]
--- error_log eval
qr/\[warn\] .*? could not acquire callback lock: timeout/



=== TEST 11: get() returns nil cached item on callback lock timeout
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            -- insert 2 dummy values to ensure that lock acquisition (which
            -- uses shm:set) will _not_ evict out stale cached value
            ngx.shared.cache_shm:set(1, true, 0.2)
            ngx.shared.cache_shm:set(2, true, 0.2)

            local mlcache = require "resty.mlcache"
            local cache_1 = assert(mlcache.new("my_mlcache", "cache_shm", {
                neg_ttl = 0.3,
                resurrect_ttl = 0.3
            }))
            local cache_2 = assert(mlcache.new("my_mlcache", "cache_shm", {
                neg_ttl = 0.3,
                resurrect_ttl = 0.3,
                resty_lock_opts = {
                    timeout = 0.2
                }
            }))

            local function cb(delay)
                if delay then
                    ngx.sleep(delay)
                end

                return nil
            end

            -- cache in shm

            local data, err, flags = cache_1:get("my_key", nil, cb)
            assert(data == nil)
            assert(err == nil)
            assert(mlcache.hit_level(flags) == 3)

            -- make shm + LRU expire

            ngx.sleep(0.3)

            local t1 = ngx.thread.spawn(function()
                -- trigger L3 callback again, but slow to return this time

                cache_1:get("my_key", nil, cb, 0.3)
            end)

            local t2 = ngx.thread.spawn(function()
                -- make this mlcache wait on other's callback, and timeout

                local data, err, flags = cache_2:get("my_key", nil, cb)
                ngx.say("data: ", data)
                ngx.say("err: ", err)
                ngx.say("hit_lvl: ", mlcache.hit_level(flags))
                ngx.say("resurrected: ", mlcache.resurrected(flags))
                ngx.say("stale: ", mlcache.stale(flags))
            end)

            assert(ngx.thread.wait(t1))
            assert(ngx.thread.wait(t2))

            ngx.say()
            ngx.say("-> subsequent get()")
            data, err, flags = cache_2:get("my_key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags)) -- should be 1 since LRU instances are shared by mlcache namespace, and t1 finished
        }
    }
--- request
GET /t
--- response_body
data: nil
err: nil
hit_lvl: 2
resurrected: false
stale: true

-> subsequent get()
data: nil
err: nil
hit_lvl: 1
--- no_error_log
[error]
--- error_log eval
qr/\[warn\] .*? could not acquire callback lock: timeout/



=== TEST 12: get() does not resurrect a stale value if no 'resurrect_ttl' is set on the instance
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ttl = 0.3,
            }))

            local cb_called = 0

            local function cb()
                cb_called = cb_called + 1

                if cb_called == 1 then
                    return 123
                end

                if cb_called == 2 then
                    return nil, "some error"
                end

                return 456
            end

            ngx.say("-> 1st get()")
            local data, err = cache:get("key", nil, cb)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end
            ngx.say("data: ", data)

            ngx.say()
            ngx.say("sleeping for 0.3s...")
            ngx.sleep(0.3)
            ngx.say()

            ngx.say("-> stale get()")
            data, err = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)

            ngx.say()
            ngx.say("-> subsequent get()")
            data, err, flags = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", mlcache.hit_level(flags))
        }
    }
--- request
GET /t
--- response_body
-> 1st get()
data: 123

sleeping for 0.3s...

-> stale get()
data: nil
err: some error

-> subsequent get()
data: 456
err: nil
hit_lvl: 3
--- no_error_log
[error]



=== TEST 13: get() callback can return nil + err (non-string) safely with opts.resurrect_ttl
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"
            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ttl = 0.3,
                resurrect_ttl = 1,
            }))

            local data, err = cache:get("1", nil, function() return 123 end)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.sleep(0.3)

            local data, err = cache:get("1", nil, function() return nil, {} end)
            if err then
                ngx.log(ngx.ERR, err)
                return
            end

            ngx.say("cb return values: ", data, " ", err)
        }
    }
--- request
GET /t
--- response_body
cb return values: 123 nil
--- no_error_log
[error]
--- error_log eval
qr/\[warn\] .*? callback returned an error \(table: 0x[[:xdigit:]]+\)/



=== TEST 14: get() returns stale hit_lvl when retrieved from shm on last ms (see GH PR #58)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local forced_now = ngx.now()
            ngx.now = function()
                return forced_now
            end

            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm", {
                ttl = 0.2,
                resurrect_ttl = 0.2,
            }))

            local cb_called = 0

            local function cb()
                cb_called = cb_called + 1

                if cb_called == 1 then
                    return 42
                end

                return nil, "some error causing a resurrect"
            end

            local data, err = cache:get("key", nil, cb)
            assert(data == 42, err or "invalid data value: " .. data)

            -- cause a resurrect in L2 shm
            ngx.sleep(0.201)
            forced_now = forced_now + 0.201

            local data, err, flags = cache:get("key", nil, cb)
            assert(data == 42, err or "invalid data value: " .. data)
            assert(mlcache.resurrected(flags), "resurrected bit should be set")

            -- value is now resurrected

            -- drop L1 cache value
            cache.lru:delete("key")

            -- advance 0.2 second in the future, and simulate another :get()
            -- call; the L2 shm entry will still be alive (as its clock is
            -- not faked), but mlcache will compute a remaining_ttl of 0;
            -- in such cases we should still see the stale bit in flags
            forced_now = forced_now + 0.2

            local data, err, flags = cache:get("key", nil, cb)
            assert(data == 42, err or "invalid data value: " .. data)

            ngx.say("+0.200s after resurrect stale bit: ", mlcache.stale(flags))
        }
    }
--- request
GET /t
--- response_body
+0.200s after resurrect stale bit: true
--- no_error_log
[error]
