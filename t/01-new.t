# vim:set ts=4 sts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * (blocks() * 3) + 4;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  cache_shm 1m;
};

run_tests();

__DATA__

=== TEST 1: module has version number
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            ngx.say(mlcache._VERSION)
        }
    }
--- request
GET /t
--- response_body_like
\d+\.\d+\.\d+
--- no_error_log
[error]



=== TEST 2: new() validates name
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local ok, err = pcall(mlcache.new)
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log
name must be a string



=== TEST 3: new() validates shm
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local ok, err = pcall(mlcache.new, "name")
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log
shm must be a string



=== TEST 4: new() validates ipc_shm name
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local ok, err = pcall(mlcache.new, "name", "cache_shm", { ipc_shm = 1 })
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log
ipc_shm must be a string



=== TEST 5: new() validates opts
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local ok, err = pcall(mlcache.new, "name", "cache_shm", "foo")
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log
opts must be a table



=== TEST 6: new() ensures shm exists
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("name", "foo")
            if not cache then
                ngx.log(ngx.ERR, err)
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log
no such lua_shared_dict: foo



=== TEST 7: new() ensures ipc shm exists
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("name", "cache_shm", { ipc_shm = "ipc" })
            if not cache then
                ngx.log(ngx.ERR, err)
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log
no such lua_shared_dict: ipc



=== TEST 8: new() validates lru_size
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local ok, err = pcall(mlcache.new, "name", "cache_shm", {
                lru_size = "",
            })
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log
opts.lru_size must be a number



=== TEST 9: new() validates ttl
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local ok, err = pcall(mlcache.new, "name", "cache_shm", {
                ttl = ""
            })
            if not ok then
                ngx.log(ngx.ERR, err)
            end

            local ok, err = pcall(mlcache.new, "name", "cache_shm", {
                ttl = -1
            })
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log
opts.ttl must be a number
opts.ttl must be >= 0



=== TEST 10: new() validates neg_ttl
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local ok, err = pcall(mlcache.new, "name", "cache_shm", {
                neg_ttl = ""
            })
            if not ok then
                ngx.log(ngx.ERR, err)
            end

            local ok, err = pcall(mlcache.new, "name", "cache_shm", {
                neg_ttl = -1
            })
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log
opts.neg_ttl must be a number
opts.neg_ttl must be >= 0



=== TEST 11: new() creates an mlcache object with defaults
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("name", "cache_shm")
            if not cache then
                ngx.log(ngx.ERR, err)
            end

            ngx.say(type(cache))
            ngx.say(type(cache.ttl))
            ngx.say(type(cache.neg_ttl))
        }
    }
--- request
GET /t
--- response_body
table
number
number
--- no_error_log
[error]



=== TEST 12: new() accepts user-provided LRU instances
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache          = require "resty.mlcache"
            local pureffi_lrucache = require "resty.lrucache.pureffi"

            local my_lru = pureffi_lrucache.new(100)

            local cache = assert(mlcache.new("name", "cache_shm", { lru = my_lru }))

            ngx.say("lru is user-provided: ", cache.lru == my_lru)
        }
    }
--- request
GET /t
--- response_body
lru is user-provided: true
--- no_error_log
[error]
