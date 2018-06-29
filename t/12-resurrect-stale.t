# vim:set ts=4 sts=4 sw=4 et ft=:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3 + 2);

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
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)

            ngx.say()
            ngx.say("-> subsequent get()")
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)

            ngx.say()
            ngx.say("sleeping for 0.2s...")
            ngx.sleep(0.21)
            ngx.say()

            ngx.say("-> successfull callback get()")
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)
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
hit_lvl: 4

-> subsequent get()
data: 123
err: nil
hit_lvl: 1

sleeping for 0.2s...

-> successfull callback get()
data: 456
err: nil
hit_lvl: 3
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
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)
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
hit_lvl: 4
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
            data, err, hit_lvl = cache:get("key", {
                resurrect_ttl = 0.2
            }, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)

            ngx.say()
            ngx.say("sleeping for 0.2s...")
            ngx.sleep(0.21)
            ngx.say()

            ngx.say("-> subsequent stale get()")
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)
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
hit_lvl: 4

sleeping for 0.2s...

-> subsequent stale get()
data: 123
err: nil
hit_lvl: 4
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
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)

            ngx.say()
            ngx.say("-> subsequent get()")
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)

            ngx.say()
            ngx.say("sleeping for 0.2s...")
            ngx.sleep(0.21)
            ngx.say()

            ngx.say("-> successfull callback get()")
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)
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
hit_lvl: 4

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
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)

            ngx.say()
            ngx.say("-> subsequent get()")
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)

            ngx.say()
            ngx.say("sleeping for 0.2s...")
            ngx.sleep(0.21)
            ngx.say()

            ngx.say("-> successfull callback get()")
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)
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
hit_lvl: 4

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
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)

            ngx.say()
            ngx.say("-> subsequent get()")
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)

            ngx.say()
            ngx.say("sleeping for 0.2s...")
            ngx.sleep(0.21)
            ngx.say()

            ngx.say("-> successfull callback get()")
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)
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
hit_lvl: 4

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
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", string.match(err, "callback threw an error:"), " ",
                    string.match(err, "thrown error"))
            ngx.say("hit_lvl: ", hit_lvl)

            ngx.say()
            ngx.say("-> subsequent get()")
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)
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
hit_lvl: nil

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

            local data, err, hit_lvl = cache_1:get("my_key", nil, cb)
            assert(data == 123)
            assert(err == nil)
            assert(hit_lvl == 3)

            -- make shm + LRU expire

            ngx.sleep(0.3)

            local t1 = ngx.thread.spawn(function()
                -- trigger L3 callback again, but slow to return this time

                cache_1:get("my_key", nil, cb, 0.3, 456)
            end)

            local t2 = ngx.thread.spawn(function()
                -- make this mlcache wait on other's callback, and timeout

                local data, err, hit_lvl = cache_2:get("my_key", nil, cb)
                ngx.say("data: ", data)
                ngx.say("err: ", err)
                ngx.say("hit_lvl: ", hit_lvl)
            end)

            assert(ngx.thread.wait(t1, t2))

            ngx.say()
            ngx.say("-> subsequent get()")
            data, err, hit_lvl = cache_2:get("my_key", nil, cb, nil, 123)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)
        }
    }
--- request
GET /t
--- response_body
data: 123
err: nil
hit_lvl: 4

-> subsequent get()
data: 456
err: nil
hit_lvl: 2
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

            local data, err, hit_lvl = cache_1:get("my_key", nil, cb)
            assert(data == nil)
            assert(err == nil)
            assert(hit_lvl == 3)

            -- make shm + LRU expire

            ngx.sleep(0.3)

            local t1 = ngx.thread.spawn(function()
                -- trigger L3 callback again, but slow to return this time

                cache_1:get("my_key", nil, cb, 0.3)
            end)

            local t2 = ngx.thread.spawn(function()
                -- make this mlcache wait on other's callback, and timeout

                local data, err, hit_lvl = cache_2:get("my_key", nil, cb)
                ngx.say("data: ", data)
                ngx.say("err: ", err)
                ngx.say("hit_lvl: ", hit_lvl)
            end)

            assert(ngx.thread.wait(t1, t2))

            ngx.say()
            ngx.say("-> subsequent get()")
            data, err, hit_lvl = cache_2:get("my_key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)
        }
    }
--- request
GET /t
--- response_body
data: nil
err: nil
hit_lvl: 4

-> subsequent get()
data: nil
err: nil
hit_lvl: 2
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

                return nil, "some error"
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
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)

            ngx.say()
            ngx.say("-> subsequent get()")
            data, err, hit_lvl = cache:get("key", nil, cb)
            ngx.say("data: ", data)
            ngx.say("err: ", err)
            ngx.say("hit_lvl: ", hit_lvl)
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
hit_lvl: nil

-> subsequent get()
data: nil
err: some error
hit_lvl: nil
--- no_error_log
[error]
