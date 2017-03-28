-- vim: st=4 sts=4 sw=4 et:

local cjson      = require "cjson.safe"
local lrucache   = require "resty.lrucache"
local resty_lock = require "resty.lock"


local type         = type
local pcall        = pcall
local error        = error
local shared       = ngx.shared
local setmetatable = setmetatable


local SERIALIZED_KEY_PREFIX = "serialized:"
local LOCK_KEY_PREFIX       = "lock:"


local _M = {}
local mt = { __index = _M }


function _M.new(shm, lru_size, ttl)
    if type(shm) ~= "string" then
        return error("shm must be a string", 2)
    end

    if type(lru_size) ~= "number" then
        return error("lru_size must be a number", 2)
    end

    if ttl and type(ttl) ~= "number" then
        return error("ttl must be a number", 2)
    end

    local dict = shared[shm]
    if not dict then
        return nil, "no such lua_shared_dict: " .. shm
    end

    local ml_cache = {
        lru        = lrucache.new(lru_size),
        dict       = dict,
        shm        = shm,
        ttl        = ttl or 30,
    }

    return setmetatable(ml_cache, mt)
end


local function set_lru(self, key, value, ttl)
    self.lru:set(key, value, ttl)

    return value
end


local function shmlru_get(self, key, ttl)
    local v, err = self.dict:get(key)
    if err then
        return nil, "could not read from lua_shared_dict: " .. err
    end

    if v ~= nil then
        if type(v) ~= "string" then
            return set_lru(self, key, v, ttl)
        end

        -- maybe need to decode if encoded

        local encoded, err = self.dict:get(SERIALIZED_KEY_PREFIX .. key)
        if err then
            return nil, "could not read from lua_shared_dict: " .. err
        end

        if encoded == nil then
            -- was a plain string
            return set_lru(self, key, v, ttl)
        end

        local decoded, err = cjson.decode(v)
        if not decoded then
            return nil, "could not decode value: " .. err
        end

        return set_lru(self, key, decoded, ttl)
    end
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
        return error("key must be a string", 2)
    end

    if type(cb) ~= "function" then
        return error("callback must be a function", 2)
    end

    if opts then
        if type(opts) ~= "table" then
            return error("opts must be a table", 2)
        end

        if type(opts.ttl) ~= "number" then
            return error("opts.ttl must be a number", 2)
        end

    else
        opts = {}
    end

    local ttl = opts.ttl or self.ttl

    local data = self.lru:get(key)
    if data ~= nil then
        return data
    end

    -- not in worker's LRU cache, need shm lookup

    local err
    data, err = shmlru_get(self, key, ttl)
    if err then
        return nil, err
    end

    if data then
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

    data = shmlru_get(self, key, ttl)
    if data then
        return unlock_and_ret(lock, data)
    end

    -- still not in shm, we are responsible for running the callback

    local ok, err = pcall(cb, ...)
    if not ok then
        return unlock_and_ret(lock, nil, "callback threw an error: " .. err)
    end

    local res = err

    if res == nil then
        return unlock_and_ret(lock) -- nil, nil
    end

    local value = res

    if type(res) == "table" then
        -- res was a table, needs encoding
        local encoded, err = cjson.encode(res)
        if not encoded then
            return unlock_and_ret(lock, nil,
                                  "could not encode callback result: " .. err)
        end

        ok, err = self.dict:set(SERIALIZED_KEY_PREFIX .. key, true, ttl)
        if not ok then
            return unlock_and_ret(lock, nil,
                                  "could not write to lua_shared_dict: " .. err)
        end

        value = encoded
    end

    -- cache value in shm for currently-locked workers

    ok, err = self.dict:set(key, value, ttl)
    if not ok then
        return unlock_and_ret(lock, nil,
                              "could not write to lua_shared_dict: " .. err)
    end

    -- set our own worker's LRU cache

    set_lru(self, key, value, ttl)

    return unlock_and_ret(lock, res)
end


return _M
