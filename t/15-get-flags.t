# vim:set ts=4 sts=4 sw=4 et ft=:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);
use lib '.';
use t::Util;

no_long_string();

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

add_block_preprocessor(sub {
    my $block = shift;

    my $http_config .= <<_EOC_;
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  cache_shm      1m;

    init_by_lua_block {
        require "resty.core"
    }
_EOC_

    $block->set_value("http_config", $http_config);
    $block->set_value("request", "GET /t");

    if (!defined $block->no_error_log) {
        $block->set_value("no_error_log", "[error]");
    }
});

run_tests();

__DATA__

=== TEST 1: hit_level() errors on invalid 'flags' argument
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local pok, perr = pcall(mlcache.hit_level, "foo")
            if not pok then
                ngx.say(perr)
            end
        }
    }
--- response_body
flags must be a number



=== TEST 2: forcible() errors on invalid 'flags' argument
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local pok, perr = pcall(mlcache.forcible, "foo")
            if not pok then
                ngx.say(perr)
            end
        }
    }
--- response_body
flags must be a number



=== TEST 3: resurrected() errors on invalid 'flags' argument
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local pok, perr = pcall(mlcache.resurrected, "foo")
            if not pok then
                ngx.say(perr)
            end
        }
    }
--- response_body
flags must be a number



=== TEST 4: stale() errors on invalid 'flags' argument
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local pok, perr = pcall(mlcache.stale, "foo")
            if not pok then
                ngx.say(perr)
            end
        }
    }
--- response_body
flags must be a number



=== TEST 5: get() returns flags with hit level bitmask
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm"))

            local function cb()
                return 123
            end

            -- from L3
            local _, _, flags = assert(cache:get("key", nil, cb))
            ngx.say("hit level from callback: ", mlcache.hit_level(flags))

            -- from L1
            _, _, flags = assert(cache:get("key", nil, cb))
            ngx.say("hit level from LRU: ", mlcache.hit_level(flags))

            -- delete from LRU
            cache.lru:delete("key")

            -- from L2
            _, _, flags = assert(cache:get("key", nil, cb))
            ngx.say("hit level from shm: ", mlcache.hit_level(flags))
        }
    }
--- response_body
hit level from callback: 3
hit level from LRU: 1
hit level from shm: 2



=== TEST 6: get() returns flags with hit level bitmask for nil values
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm"))

            local function cb()
                return nil
            end

            -- from L3
            local _, _, flags = cache:get("key", nil, cb)
            ngx.say("hit level from callback: ", mlcache.hit_level(flags))

            -- from L1
            _, _, flags = cache:get("key", nil, cb)
            ngx.say("hit level from LRU: ", mlcache.hit_level(flags))

            -- delete from LRU
            cache.lru:delete("key")

            -- from L2
            _, _, flags = cache:get("key", nil, cb)
            ngx.say("hit level from shm: ", mlcache.hit_level(flags))
        }
    }
--- response_body
hit level from callback: 3
hit level from LRU: 1
hit level from shm: 2



=== TEST 7: get() returns flags with hit level bitmask for boolean false hits
--- skip_eval: 3: t::Util::skip_openresty('<', '1.11.2.3')
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm"))

            local function cb()
                return false
            end

            -- from L3
            local _, _, flags = cache:get("key", nil, cb)
            ngx.say("hit level from callback: ", mlcache.hit_level(flags))

            -- from L1
            _, _, flags = cache:get("key", nil, cb)
            ngx.say("hit level from LRU: ", mlcache.hit_level(flags))

            -- delete from LRU
            cache.lru:delete("key")

            -- from L2
            _, _, flags = cache:get("key", nil, cb)
            ngx.say("hit level from shm: ", mlcache.hit_level(flags))
        }
    }
--- response_body
hit level from callback: 3
hit level from LRU: 1
hit level from shm: 2



=== TEST 8: get() returns flags with forcible bitmask when evicting from shm
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache = assert(mlcache.new("my_mlcache", "cache_shm"))

            local function cb()
                return 123
            end

            -- not evicting

            local _, _, flags = cache:get("a", nil, cb)

            local forcible_l1, forcible_l2 = mlcache.forcible(flags)
            ngx.say("forcible_l1: ", forcible_l1) -- NYI
            ngx.say("forcible_l2: ", forcible_l2)

            -- fill up shm

            local i = 0

            repeat
                local _, _, forcible = assert(ngx.shared.cache_shm:set(i, "foo"))
                i = i + 1
            until forcible

            ngx.say("shm full")

            -- evicting

            local _, _, flags = cache:get("b", nil, cb)

            local forcible_l1, forcible_l2 = mlcache.forcible(flags)
            ngx.say("forcible_l1: ", forcible_l1) -- NYI
            ngx.say("forcible_l2: ", forcible_l2)
        }
    }
--- response_body
forcible_l1: false
forcible_l2: false
shm full
forcible_l1: false
forcible_l2: true
