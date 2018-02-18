-- vim: st=4 sts=4 sw=4 et:

local ffi        = require "ffi"
local cjson      = require "cjson.safe"
local lrucache   = require "resty.lrucache"
local resty_lock = require "resty.lock"


local now          = ngx.now
local fmt          = string.format
local sub          = string.sub
local find         = string.find
local type         = type
local pcall        = pcall
local error        = error
local shared       = ngx.shared
local tostring     = tostring
local tonumber     = tonumber
local setmetatable = setmetatable


local LOCK_KEY_PREFIX         = "lua-resty-mlcache:lock:"
local CACHE_MISS_SENTINEL_LRU = {}
local LRU_INSTANCES           = {}


local c_str_type    = ffi.typeof("char *")
local c_lru_gc_type = ffi.metatype([[
    struct {
        char *lru_name;
        int   len;
    }
]], {
    __gc = function(c_gc_type)
        local lru_name = ffi.string(c_gc_type.lru_name, c_gc_type.len)

        local lru_gc = LRU_INSTANCES[lru_name]
        if lru_gc then
            lru_gc.count = lru_gc.count - 1
            if lru_gc.count <= 0 then
                LRU_INSTANCES[lru_name] = nil
            end
        end
    end
})


local TYPES_LOOKUP = {
    number  = 1,
    boolean = 2,
    string  = 3,
    table   = 4,
}


local marshallers = {
    shm_value = function(str_value, value_type, at, ttl)
        return fmt("%d:%f:%f:%s", value_type, at, ttl, str_value)
    end,

    shm_nil = function(at, ttl)
        return fmt("0:%f:%f:", at, ttl)
    end,

    [1] = function(number) -- number
        return tostring(number)
    end,

    [2] = function(bool)   -- boolean
        return bool and "true" or "false"
    end,

    [3] = function(str)    -- string
        return str
    end,

    [4] = function(t)      -- table
        local json, err = cjson.encode(t)
        if not json then
            return nil, "could not encode table value: " .. err
        end

        return json
    end,
}


local unmarshallers = {
    shm_value = function(marshalled)
        -- split our shm marshalled value by the hard-coded ":" tokens
        -- "type:at:ttl:value"
        -- 1:1501831735.052000:0.500000:123
        local ttl_last = find(marshalled, ":", 21, true) - 1

        local value_type = sub(marshalled, 1, 1)         -- n:...
        local at         = sub(marshalled, 3, 19)        -- n:1501831160
        local ttl        = sub(marshalled, 21, ttl_last)
        local str_value  = sub(marshalled, ttl_last + 2)

        return str_value, tonumber(value_type), tonumber(at), tonumber(ttl)
    end,

    [1] = function(str) -- number
        return tonumber(str)
    end,

    [2] = function(str) -- boolean
        return str == "true"
    end,

    [3] = function(str) -- string
        return str
    end,

    [4] = function(str) -- table
        local t, err = cjson.decode(str)
        if not t then
            return nil, "could not decode table value: " .. err
        end

        return t
    end,
}


local function rebuild_lru(self)
    local name = self.name

    if self.lru then
        -- When calling purge(), we invalidate the entire LRU by
        -- GC-ing it.
        -- lua-resty-lrucache has a 'flush_all()' method in development
        -- which would be more appropriate:
        -- https://github.com/openresty/lua-resty-lrucache/pull/23
        LRU_INSTANCES[name] = nil
        self.c_lru_gc = nil
        self.lru = nil
    end

    -- Several mlcache instances can have the same name and hence, the same
    -- lru instance. We need to GC such LRU instances when all mlcache
    -- instances using them are GC'ed.
    -- We do this by using a C struct with a __gc metamethod.

    local c_lru_gc    = ffi.new(c_lru_gc_type)
    c_lru_gc.len      = #name
    c_lru_gc.lru_name = ffi.cast(c_str_type, name)

    -- keep track of our LRU instance and a counter of how many mlcache
    -- instances are refering to it

    local lru_gc = LRU_INSTANCES[name]
    if not lru_gc then
        lru_gc              = { count = 0, lru = nil }
        LRU_INSTANCES[name] = lru_gc
    end

    local lru = lru_gc.lru
    if not lru then
        lru        = lrucache.new(self.lru_size)
        lru_gc.lru = lru
    end

    self.lru      = lru
    self.c_lru_gc = c_lru_gc

    lru_gc.count = lru_gc.count + 1
end


local _M     = {
    _VERSION = "1.0.1",
    _AUTHOR  = "Thibault Charbonnier",
    _LICENSE = "MIT",
    _URL     = "https://github.com/thibaultcha/lua-resty-mlcache",
}
local mt = { __index = _M }


function _M.new(name, shm, opts)
    if type(name) ~= "string" then
        error("name must be a string", 2)
    end

    if type(shm) ~= "string" then
        error("shm must be a string", 2)
    end

    if opts ~= nil then
        if type(opts) ~= "table" then
            error("opts must be a table", 2)
        end

        if opts.lru_size ~= nil and type(opts.lru_size) ~= "number" then
            error("opts.lru_size must be a number", 2)
        end

        if opts.ttl ~= nil then
            if type(opts.ttl) ~= "number" then
                error("opts.ttl must be a number", 2)
            end

            if opts.ttl < 0 then
                error("opts.ttl must be >= 0", 2)
            end
        end

        if opts.neg_ttl ~= nil then
            if type(opts.neg_ttl) ~= "number" then
                error("opts.neg_ttl must be a number", 2)
            end

            if opts.neg_ttl < 0 then
                error("opts.neg_ttl must be >= 0", 2)
            end
        end

        if opts.resty_lock_opts ~= nil
            and type(opts.resty_lock_opts) ~= "table"
        then
            error("opts.resty_lock_opts must be a table", 2)
        end

        if opts.ipc_shm ~= nil and type(opts.ipc_shm) ~= "string" then
            error("opts.ipc_shm must be a string", 2)
        end

        if opts.l1_serializer ~= nil
            and type(opts.l1_serializer) ~= "function"
        then
            error("opts.l1_serializer must be a function", 2)
        end
    else
        opts = {}
    end

    local dict = shared[shm]
    if not dict then
        return nil, "no such lua_shared_dict: " .. shm
    end

    local self          = {
        name            = name,
        dict            = dict,
        shm             = shm,
        ttl             = opts.ttl     or 30,
        neg_ttl         = opts.neg_ttl or 5,
        lru_size        = opts.lru_size or 100,
        resty_lock_opts = opts.resty_lock_opts,
        l1_serializer   = opts.l1_serializer,
    }

    if opts.ipc_shm then
        local mlcache_ipc = require "resty.mlcache.ipc"

        local err
        self.ipc, err = mlcache_ipc.new(opts.ipc_shm, opts.debug)
        if not self.ipc then
            return nil, "could not instanciate mlcache.ipc: " .. err
        end

        self.ipc_invalidation_channel = fmt("mlcache:invalidations:%s", name)
        self.ipc_purge_channel = fmt("mlcache:purge:%s", name)

        self.ipc:subscribe(self.ipc_invalidation_channel, function(key)
            self.lru:delete(key)
        end)

        self.ipc:subscribe(self.ipc_purge_channel, function()
            rebuild_lru(self)
        end)
    end

    if opts.lru then
        self.lru = opts.lru

    else
        rebuild_lru(self)
    end

    return setmetatable(self, mt)
end


local function set_lru(self, key, value, ttl, neg_ttl, l1_serializer)
    if value == nil then
        if neg_ttl == 0 then
            -- indefinite ttl for lua-resty-lrucache is 'nil'
            neg_ttl = nil
        end

        self.lru:set(key, CACHE_MISS_SENTINEL_LRU, neg_ttl)

        return CACHE_MISS_SENTINEL_LRU
    end

    if ttl == 0 then
        -- indefinite ttl for lua-resty-lrucache is 'nil'
        ttl = nil
    end

    if l1_serializer then
        local ok, err
        ok, value, err = pcall(l1_serializer, value)
        if not ok then
            return nil, "l1_serializer threw an error: " .. value
        end

        if err then
            return nil, err
        end

        if value == nil then
            return nil, "l1_serializer returned a nil value"
        end
    end

    self.lru:set(key, value, ttl)

    return value
end


local function set_shm(self, shm_key, value, ttl, neg_ttl)
    local at = now()

    if value == nil then
        local shm_nil = marshallers.shm_nil(at, neg_ttl)

        -- we need to cache that this was a miss, and ensure cache hit for a
        -- nil value
        local ok, err = self.dict:set(shm_key, shm_nil, neg_ttl)
        if not ok then
            return nil, "could not write to lua_shared_dict: " .. err
        end

        return true
    end

    -- serialize insertion time + Lua types for shm storage

    local value_type = TYPES_LOOKUP[type(value)]

    if not marshallers[value_type] then
        error("cannot cache value of type " .. type(value))
    end

    local str_marshalled, err = marshallers[value_type](value)
    if not str_marshalled then
        return nil, "could not serialize value for lua_shared_dict insertion: "
                    .. err
    end

    local shm_marshalled = marshallers.shm_value(str_marshalled, value_type,
                                                 at, ttl)

    -- cache value in shm for currently-locked workers

    local ok, err = self.dict:set(shm_key, shm_marshalled, ttl)
    if not ok then
        return nil, "could not write to lua_shared_dict: " .. err
    end

    return true
end


local function get_shm_set_lru(self, key, shm_key, l1_serializer)
    local v, err = self.dict:get(shm_key)
    if err then
        return nil, "could not read from lua_shared_dict: " .. err
    end

    if v ~= nil then
        local str_serialized, value_type, at, ttl = unmarshallers.shm_value(v)

        local remaining_ttl
        if ttl == 0 then
            -- indefinite ttl, keep '0' as it means 'forever'
            remaining_ttl = 0

        else
            -- compute elapsed time to get remaining ttl for LRU caching
            remaining_ttl = ttl - (now() - at)
        end

        -- value_type of 0 is a nil entry
        if value_type == 0 then
            return set_lru(self, key, nil, remaining_ttl, remaining_ttl,
                           l1_serializer)
        end

        local value, err = unmarshallers[value_type](str_serialized)
        if err then
            return nil, "could not deserialize value after lua_shared_dict " ..
                        "retrieval: " .. err
        end

        return set_lru(self, key, value, remaining_ttl, remaining_ttl,
                       l1_serializer)
    end
end


local function check_opts(self, opts)
    local ttl
    local neg_ttl
    local l1_serializer

    if opts ~= nil then
        if type(opts) ~= "table" then
            error("opts must be a table", 3)
        end

        ttl = opts.ttl
        if ttl ~= nil then
            if type(ttl) ~= "number" then
                error("opts.ttl must be a number", 3)
            end

            if ttl < 0 then
                error("opts.ttl must be >= 0", 3)
            end
        end

        neg_ttl = opts.neg_ttl
        if neg_ttl ~= nil then
            if type(neg_ttl) ~= "number" then
                error("opts.neg_ttl must be a number", 3)
            end

            if neg_ttl < 0 then
                error("opts.neg_ttl must be >= 0", 3)
            end
        end

        l1_serializer = opts.l1_serializer
        if l1_serializer ~= nil and type(l1_serializer) ~= "function" then
           error("opts.l1_serializer must be a function", 3)
        end
    end

    if not ttl then
        ttl = self.ttl
    end

    if not neg_ttl then
        neg_ttl = self.neg_ttl
    end

    if not l1_serializer then
        l1_serializer = self.l1_serializer
    end

    return ttl, neg_ttl, l1_serializer
end


local function unlock_and_ret(lock, res, err, hit_lvl)
    local ok, lerr = lock:unlock()
    if not ok then
        return nil, "could not unlock callback: " .. lerr
    end

    return res, err, hit_lvl
end


function _M:get(key, opts, cb, ...)
    if type(key) ~= "string" then
        error("key must be a string", 2)
    end

    if type(cb) ~= "function" then
        error("callback must be a function", 2)
    end

    -- worker LRU cache retrieval

    local data = self.lru:get(key)
    if data == CACHE_MISS_SENTINEL_LRU then
        return nil, nil, 1
    end

    if data ~= nil then
        return data, nil, 1
    end

    -- not in worker's LRU cache, need shm lookup

    -- restrict this key to the current namespace, so we isolate this
    -- mlcache instance from potential other instances using the same
    -- shm
    local namespaced_key = self.name .. key

    -- opts validation

    local ttl, neg_ttl, l1_serializer = check_opts(self, opts)

    local err
    data, err = get_shm_set_lru(self, key, namespaced_key, l1_serializer)
    if err then
        return nil, err
    end

    if data == CACHE_MISS_SENTINEL_LRU then
        return nil, nil, 2
    end

    if data ~= nil then
        return data, nil, 2
    end

    -- not in shm either
    -- single worker must execute the callback

    local lock, err = resty_lock:new(self.shm, self.resty_lock_opts)
    if not lock then
        return nil, "could not create lock: " .. err
    end

    local elapsed, err = lock:lock(LOCK_KEY_PREFIX .. namespaced_key)
    if not elapsed then
        return nil, "could not aquire callback lock: " .. err
    end

    -- check for another worker's success at running the callback

    data, err = get_shm_set_lru(self, key, namespaced_key, l1_serializer)
    if err then
        return unlock_and_ret(lock, nil, err)
    end

    if data then
        if data == CACHE_MISS_SENTINEL_LRU then
            return unlock_and_ret(lock, nil, nil, 2)
        end

        return unlock_and_ret(lock, data, nil, 2)
    end

    -- still not in shm, we are responsible for running the callback
    --
    -- Note: the `_` variable is a placeholder for forward compatibility
    -- for callback-returned errors

    local ok, err, _, new_ttl = pcall(cb, ...)
    if not ok then
        return unlock_and_ret(lock, nil, "callback threw an error: " .. err)
    end

    data = err

    -- override ttl / neg_ttl

    if type(new_ttl) == "number" and new_ttl >= 0 then
        if data == nil then
            neg_ttl = new_ttl

        else
            ttl = new_ttl
        end
    end

    -- set shm cache level

    local ok, err = set_shm(self, namespaced_key, data, ttl, neg_ttl)
    if not ok then
        return unlock_and_ret(lock, nil, err)
    end

    -- set our own worker's LRU cache

    data, err = set_lru(self, key, data, ttl, neg_ttl, l1_serializer)
    if err then
        return unlock_and_ret(lock, nil, err)
    end

    if data == CACHE_MISS_SENTINEL_LRU then
        return unlock_and_ret(lock, nil, nil, 3)
    end

    -- unlock and return

    return unlock_and_ret(lock, data, nil, 3)
end


function _M:peek(key)
    if type(key) ~= "string" then
        error("key must be a string", 2)
    end

    -- restrict this key to the current namespace, so we isolate this
    -- mlcache instance from potential other instances using the same
    -- shm
    local namespaced_key = self.name .. key

    local v, err = self.dict:get(namespaced_key)
    if err then
        return nil, "could not read from lua_shared_dict: " .. err
    end

    if v ~= nil then
        local str_serialized, value_type, at, ttl = unmarshallers.shm_value(v)

        local remaining_ttl = ttl - (now() - at)

        -- value_type of 0 is a nil entry
        if value_type == 0 then
            return remaining_ttl
        end

        local value, err = unmarshallers[value_type](str_serialized)
        if err then
            return nil, "could not deserialize value after lua_shared_dict " ..
                        "retrieval: " .. err
        end

        return remaining_ttl, nil, value
    end
end


function _M:set(key, opts, value)
    if not self.ipc then
        error("no ipc to propagate update, specify ipc_shm", 2)
    end

    if type(key) ~= "string" then
        error("key must be a string", 2)
    end

    do
        -- restrict this key to the current namespace, so we isolate this
        -- mlcache instance from potential other instances using the same
        -- shm
        local ttl, neg_ttl, l1_serializer = check_opts(self, opts)
        local namespaced_key = self.name .. key

        set_lru(self, key, value, ttl, neg_ttl, l1_serializer)

        local ok, err = set_shm(self, namespaced_key, value, ttl, neg_ttl)
        if not ok then
            return nil, err
        end
    end

    local ok, err = self.ipc:broadcast(self.ipc_invalidation_channel, key)
    if not ok then
        return nil, "could not broadcast update: " .. err
    end

    return true
end


function _M:delete(key)
    if not self.ipc then
        error("no ipc to propagate deletion, specify ipc_shm", 2)
    end

    if type(key) ~= "string" then
        error("key must be a string", 2)
    end

    -- delete from shm first
    do
        -- restrict this key to the current namespace, so we isolate this
        -- mlcache instance from potential other instances using the same
        -- shm
        local namespaced_key = self.name .. key

        local ok, err = self.dict:delete(namespaced_key)
        if not ok then
            return nil, "could not delete from shm: " .. err
        end
    end

    -- delete from LRU and propagate
    self.lru:delete(key)

    local ok, err = self.ipc:broadcast(self.ipc_invalidation_channel, key)
    if not ok then
        return nil, "could not broadcast deletion: " .. err
    end

    return true
end


function _M:purge(flush_expired)
    if not self.ipc then
        error("no ipc to propagate purge, specify ipc_shm", 2)
    end

    -- clear shm first
    self.dict:flush_all()

    if flush_expired then
        self.dict:flush_expired()
    end

    -- clear LRU content and propagate
    rebuild_lru(self)

    local ok, err = self.ipc:broadcast(self.ipc_purge_channel, "")
    if not ok then
        return nil, "could not broadcast purge: " .. err
    end

    return true
end


function _M:update(timeout)
    if not self.ipc then
        error("no ipc to poll updates, specify ipc_shm", 2)
    end

    local ok, err = self.ipc:poll(timeout)
    if not ok then
        return nil, "could not poll ipc events: " .. err
    end

    return true
end


return _M
