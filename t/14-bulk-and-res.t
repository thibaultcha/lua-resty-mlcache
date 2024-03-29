# vim:set ts=4 sts=4 sw=4 et ft=:

use strict;
use lib '.';
use t::TestMLCache;

workers(2);
#repeat_each(2);

plan tests => repeat_each() * blocks() * 3;

run_tests();

__DATA__

=== TEST 1: new_bulk() creates a bulk
--- config
    location /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local bulk = mlcache.new_bulk()

            ngx.say("type: ", type(bulk))
            ngx.say("size: ", #bulk)
            ngx.say("bulk.n: ", bulk.n)
        }
    }
--- response_body
type: table
size: 0
bulk.n: 0
--- no_error_log
[error]



=== TEST 2: new_bulk() creates a bulk with narr in arg #1
--- config
    location /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local bulk = mlcache.new_bulk(3)

            ngx.say("type: ", type(bulk))
            ngx.say("size: ", #bulk)
            ngx.say("bulk.n: ", bulk.n)
        }
    }
--- response_body
type: table
size: 0
bulk.n: 0
--- no_error_log
[error]



=== TEST 3: bulk:add() adds bulk operations
--- config
    location /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local function cb() end

            local bulk = mlcache.new_bulk(3)

            for i = 1, 3 do
                bulk:add("key_" .. i, nil, cb, i)
            end

            for i = 1, 3*4, 4 do
                ngx.say(tostring(bulk[i]), " ",
                        tostring(bulk[i + 1]), " ",
                        tostring(bulk[i + 2]), " ",
                        tostring(bulk[i + 3]))
            end

            ngx.say("bulk.n: ", bulk.n)
        }
    }
--- response_body_like
key_1 nil function: 0x[0-9a-fA-F]+ 1
key_2 nil function: 0x[0-9a-fA-F]+ 2
key_3 nil function: 0x[0-9a-fA-F]+ 3
bulk\.n: 3
--- no_error_log
[error]



=== TEST 4: bulk:add() can be given to get_bulk()
--- config
    location /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"
            local cache = assert(mlcache.new("my_mlcache", "cache_shm"))

            local function cb(i) return i end

            local bulk = mlcache.new_bulk(3)

            for i = 1, 3 do
                bulk:add("key_" .. i, nil, cb, i)
            end

            local res, err = cache:get_bulk(bulk)
            if not res then
                ngx.log(ngx.ERR, err)
                return
            end

            for i = 1, res.n, 3 do
                ngx.say(tostring(res[i]), " ",
                        tostring(res[i + 1]), " ",
                        tostring(res[i + 2]))
            end
        }
    }
--- response_body
1 nil 3
2 nil 3
3 nil 3
--- no_error_log
[error]



=== TEST 5: each_bulk_res() iterates over get_bulk() results
--- config
    location /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"
            local cache = assert(mlcache.new("my_mlcache", "cache_shm"))

            local res, err = cache:get_bulk {
                "key_a", nil, function() return 1 end, nil,
                "key_b", nil, function() return 2 end, nil,
                "key_c", nil, function() return 3 end, nil,
                n = 3,
            }
            if not res then
                ngx.log(ngx.ERR, err)
                return
            end

            for i, data, err, hit_lvl in mlcache.each_bulk_res(res) do
                ngx.say(i, " ", data, " ", err, " ", hit_lvl)
            end
        }
    }
--- response_body
1 1 nil 3
2 2 nil 3
3 3 nil 3
--- no_error_log
[error]



=== TEST 6: each_bulk_res() throws an error on unrocognized res
--- config
    location /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local pok, perr = pcall(mlcache.each_bulk_res, {})
            if not pok then
                ngx.say(perr)
            end
        }
    }
--- response_body
res must have res.n field; is this a get_bulk() result?
--- no_error_log
[error]
