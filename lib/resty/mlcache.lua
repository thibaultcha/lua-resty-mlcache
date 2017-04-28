-- vim: st=4 sts=4 sw=4 et:

local ffi        = require "ffi"
local cjson      = require "cjson.safe"
local lrucache   = require "resty.lrucache"
local resty_lock = require "resty.lock"


local now          = ngx.now
local type         = type
local pcall        = pcall
local error        = error
local shared       = ngx.shared
local ffi_str      = ffi.string
local ffi_cast     = ffi.cast
local tostring     = tostring
local tonumber     = tonumber
local setmetatable = setmetatable


ffi.cdef [[
    struct shm_value {
        unsigned int    type_len;
        unsigned int    len;
        unsigned char  *type_data;
        unsigned char  *data;
        double          at;
    };
]]


local marshallers
local unmarshallers


local LOCK_KEY_PREFIX         = "lock:"
local CACHE_MISS_SENTINEL_LRU = {}


do
    local str_const       = ffi.typeof("unsigned char *")
    local shm_value_const = ffi.typeof("const struct shm_value*")
    local shm_value_size  = ffi.sizeof("struct shm_value")
    local shm_value_cdata = ffi.new("struct shm_value")

    local shm_value_nil_cdata     = ffi.new("struct shm_value")
    shm_value_nil_cdata.len       = 0
    shm_value_nil_cdata.type_len  = 3
    shm_value_nil_cdata.data      = ffi_cast(str_const, "")
    shm_value_nil_cdata.type_data = ffi_cast(str_const, "nil")


    marshallers = {
        shm_value = function(str_value, value_type, at)
            shm_value_cdata.at        = at
            shm_value_cdata.len       = #str_value
            shm_value_cdata.type_len  = #value_type
            shm_value_cdata.data      = ffi_cast(str_const, str_value)
            shm_value_cdata.type_data = ffi_cast(str_const, value_type)

            return ffi_str(shm_value_cdata, shm_value_size)
        end,

        shm_nil = function(at)
            shm_value_nil_cdata.at = at

            return ffi_str(shm_value_nil_cdata, shm_value_size)
        end,

        number = function(number)
            return tostring(number)
        end,

        boolean = function(bool)
            return bool and "true" or "false"
        end,

        string = function(str)
            return str
        end,

        table = function(t)
            local json, err = cjson.encode(t)
            if not json then
                return nil, "could not encode table value: " .. err
            end

            return json
        end,
    }


    unmarshallers = {
        shm_value = function(marshalled)
            local shm_value = ffi_cast(shm_value_const, marshalled)

            local value      = ffi_str(shm_value.data, shm_value.len)
            local value_type = ffi_str(shm_value.type_data, shm_value.type_len)

            return value, value_type, shm_value.at
        end,

        number = function(str)
            return tonumber(str)
        end,

        boolean = function(str)
            return str == "true"
        end,

        string = function(str)
            return str
        end,

        table = function(str)
            local t, err = cjson.decode(str)
            if not t then
                return nil, "could not decode table value: " .. err
            end

            return t
        end,
    }
end


local _M = {}
local mt = { __index = _M }


function _M.new(shm, opts)
    if type(shm) ~= "string" then
        return error("shm must be a string")
    end

    if opts then
        if type(opts) ~= "table" then
            return error("opts must be a table")
        end

        if opts.lru_size and type(opts.lru_size) ~= "number" then
            return error("opts.lru_size must be a number")
        end

        if opts.ttl and type(opts.ttl) ~= "number" then
            return error("opts.ttl must be a number")
        end

        if opts.neg_ttl and type(opts.neg_ttl) ~= "number" then
            return error("opts.neg_ttl must be a number")
        end

        if opts.ipc_shm and type(opts.ipc_shm) ~= "string" then
            return error("opts.ipc_shm must be a string")
        end

    else
        opts = {}
    end

    local dict = shared[shm]
    if not dict then
        return nil, "no such lua_shared_dict: " .. shm
    end

    local self  = {
        lru     = lrucache.new(opts.lru_size or 100),
        dict    = dict,
        shm     = shm,
        ttl     = opts.ttl     or 30,
        neg_ttl = opts.neg_ttl or 5
    }

    if opts.ipc_shm then
        local mlcache_ipc = require "resty.mlcache.ipc"

        local ipc, err = mlcache_ipc.new(opts.ipc_shm, opts.debug)
        if not ipc then
            return nil, "could not instanciate mlcache.ipc: " .. err
        end

        ipc:subscribe("invalidations", function(key)
            self.lru:delete(key)
        end)

        self.ipc = ipc
    end

    return setmetatable(self, mt)
end


local function set_lru(self, key, value, ttl)
    self.lru:set(key, value, ttl)

    return value
end


local function shmlru_get(self, key, ttl, neg_ttl)
    local v, err = self.dict:get(key)
    if err then
        return nil, "could not read from lua_shared_dict: " .. err
    end

    if v ~= nil then
        local str_serialized, value_type, at = unmarshallers.shm_value(v)

        if value_type == "nil" then
            local remaining_ttl = neg_ttl - (now() - at)
            return set_lru(self, key, CACHE_MISS_SENTINEL_LRU, remaining_ttl)
        end

        local value, err = unmarshallers[value_type](str_serialized)
        if err then
            return nil, "could not deserialize table after lua_shared_dict " ..
                        "retrieval: " .. err
        end

        local remaining_ttl = ttl - (now() - at)

        return set_lru(self, key, value, remaining_ttl)
    end
end


local function shmlru_set(self, key, value, ttl, neg_ttl)
    local at = now()

    if value == nil then
        local shm_nil = marshallers.shm_nil(at)

        -- we need to cache that this was a miss, and ensure cache hit for a
        -- nil value
        local ok, err = self.dict:set(key, shm_nil, neg_ttl)
        if not ok then
            return nil, "could not write to lua_shared_dict: " .. err
        end

        -- set our own worker's LRU cache

        self.lru:set(key, CACHE_MISS_SENTINEL_LRU, neg_ttl)

        return nil
    end

    -- serialize insertion time + Lua types for shm storage

    local value_type = type(value)

    if not marshallers[value_type] then
        return error("cannot cache value of type " .. value_type)
    end

    local str_marshalled, err = marshallers[value_type](value)
    if not str_marshalled then
        return nil, "could not serialize table for lua_shared_dict insertion: "
                    .. err
    end

    local shm_marshalled = marshallers.shm_value(str_marshalled, value_type, at)

    -- cache value in shm for currently-locked workers

    local ok, err = self.dict:set(key, shm_marshalled, ttl)
    if not ok then
        return nil, "could not write to lua_shared_dict: " .. err
    end

    -- set our own worker's LRU cache

    return set_lru(self, key, value, ttl)
end


local function unlock_and_ret(lock, res, err)
    local ok, lerr = lock:unlock()
    if not ok then
        return nil, "could not unlock callback: " .. lerr
    end

    return res, err
end


function _M:get(key, opts, cb, ...)
    if type(key) ~= "string" then
        return error("key must be a string")
    end

    if type(cb) ~= "function" then
        return error("callback must be a function")
    end

    -- opts validation

    local ttl
    local neg_ttl

    if opts then
        if type(opts) ~= "table" then
            return error("opts must be a table")
        end

        if opts.ttl and type(opts.ttl) ~= "number" then
            return error("opts.ttl must be a number")
        end

        if opts.neg_ttl and type(opts.neg_ttl) ~= "number" then
            return error("opts.neg_ttl must be a number")
        end

        ttl     = opts.ttl
        neg_ttl = opts.neg_ttl
    end

    if not ttl then
        ttl = self.ttl
    end

    if not neg_ttl then
        neg_ttl = self.neg_ttl
    end

    -- worker LRU cache retrieval

    local data = self.lru:get(key)
    if data == CACHE_MISS_SENTINEL_LRU then
        return nil
    end

    if data ~= nil then
        return data
    end

    -- not in worker's LRU cache, need shm lookup

    local err
    data, err = shmlru_get(self, key, ttl, neg_ttl)
    if err then
        return nil, err
    end

    if data == CACHE_MISS_SENTINEL_LRU then
        return nil
    end

    if data ~= nil then
        return data
    end

    -- not in shm either
    -- single worker must execute the callback

    local lock, err = resty_lock:new(self.shm)
    if not lock then
        return nil, "could not create lock: " .. err
    end

    local elapsed, err = lock:lock(LOCK_KEY_PREFIX .. key)
    if not elapsed then
        return nil, "could not aquire callback lock: " .. err
    end

    -- check for another worker's success at running the callback

    data, err = shmlru_get(self, key, ttl, neg_ttl)
    if err then
        return unlock_and_ret(lock, nil, err)
    end

    if data then
        if data == CACHE_MISS_SENTINEL_LRU then
            return unlock_and_ret(lock, nil)
        end

        return unlock_and_ret(lock, data)
    end

    -- still not in shm, we are responsible for running the callback

    local ok, err = pcall(cb, ...)
    if not ok then
        return unlock_and_ret(lock, nil, "callback threw an error: " .. err)
    end

    local value, err = shmlru_set(self, key, err, ttl, neg_ttl)
    if err then
        return unlock_and_ret(lock, nil, err)
    end

    return unlock_and_ret(lock, value)
end


function _M:delete(key)
    if type(key) ~= "string" then
        return error("key must be a string")
    end

    if not self.ipc then
        return nil, "no ipc to propagate deletion"
    end

    self.lru:delete(key)

    local ok, err = self.dict:delete(key)
    if not ok then
        return nil, "could not delete from shm: " .. err
    end

    local ok, err = self.ipc:broadcast("invalidations", key)
    if not ok then
        return nil, "could not broadcast deletion: " .. err
    end

    return true
end


function _M:update()
    if not self.ipc then
        return nil, "no ipc to update from"
    end

    local ok, err = self.ipc:poll()
    if not ok then
        return nil, "could not poll ipc events: " .. err
    end

    return true
end


return _M
