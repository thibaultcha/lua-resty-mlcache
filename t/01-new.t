# vim:set ts=4 sts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  cache 1m;
};

run_tests();

__DATA__

=== TEST 1: new() validates shm name
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
shm must be a string



=== TEST 2: new() validates lru_size
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local ok, err = pcall(mlcache.new, "")
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log
lru_size must be a number



=== TEST 3: new() ensures shm exists
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("foo", 200)
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



=== TEST 4: new() validates ttl
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local ok, err = pcall(mlcache.new, "cache", 200, "")
            if not ok then
                ngx.log(ngx.ERR, err)
            end
        }
    }
--- request
GET /t
--- response_body

--- error_log
ttl must be a number



=== TEST 5: new() creates an mlcache object with defaults
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("cache", 200)
            if not cache then
                ngx.log(ngx.ERR, err)
            end

            ngx.say(type(cache))
            ngx.say(type(cache.ttl))
        }
    }
--- request
GET /t
--- response_body
table
number
--- no_error_log
[error]
