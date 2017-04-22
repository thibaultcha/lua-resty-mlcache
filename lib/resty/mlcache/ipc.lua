-- vim: st=4 sts=4 sw=4 et:

local ffi = require "ffi"


local type         = type
local insert       = table.insert
local ffi_str      = ffi.string
local ffi_cast     = ffi.cast
local shared       = ngx.shared
local worker_pid   = ngx.worker.pid
local ngx_now      = ngx.now
local setmetatable = setmetatable


local INDEX_KEY = "index"


ffi.cdef [[
  struct event {
    unsigned int   at;
    unsigned int   pid;
    unsigned int   data_len;
    unsigned int   channel_len;
    unsigned char *channel;
    unsigned char *data;
  };
]]


local str_const   = ffi.typeof("unsigned char *")
local event_const = ffi.typeof("const struct event*")
local event_size  = ffi.sizeof("struct event")
local event_cdata = ffi.new("struct event")


local function marshall(event)
    event_cdata.at          = event.at
    event_cdata.pid         = event.pid
    event_cdata.data_len    = #event.data
    event_cdata.channel_len = #event.channel
    event_cdata.data        = ffi_cast(str_const, event.data)
    event_cdata.channel     = ffi_cast(str_const, event.channel)

    return ffi_str(event_cdata, event_size)
end


local function unmarshall(str)
    local event = ffi_cast(event_const, str)

    return {
        at      = event.at,
        pid     = event.pid,
        channel = ffi_str(event.channel, event.channel_len),
        data    = ffi_str(event.data, event.data_len),
    }
end


local function now()
    return ngx_now() * 1000
end


local _M = {}
local mt = { __index = _M }


function _M.new(shm, debug)
    local dict = shared[shm]
    if not dict then
        return nil, "no such lua_shared_dict: " .. shm
    end

    local self    = {
        dict      = dict,
        pid       = worker_pid(),
        idx       = 0,
        callbacks = {},
    }

    if debug then
        self.marshall   = marshall
        self.unmarshall = unmarshall
    end

    return setmetatable(self, mt)
end


function _M:subscribe(channel, cb)
    if type(channel) ~= "string" then
        return error("channel must be a string")
    end

    if type(cb) ~= "function" then
        return error("callback must be a function")
    end

    if not self.callbacks[channel] then
        self.callbacks[channel] = { cb }

    else
        insert(self.callbacks[channel], cb)
    end
end


function _M:broadcast(channel, data)
    if type(channel) ~= "string" then
        return error("channel must be a string")
    end

    if type(data) ~= "string" then
        return error("data must be a string")
    end

    local idx, err = self.dict:incr(INDEX_KEY, 1, 0)
    if not idx then
        return nil, "failed to increment index: " .. err
    end

    local event = {
        at      = now(),
        pid     = worker_pid(),
        channel = channel,
        data    = data,
    }

    local ok, err = self.dict:set(idx, marshall(event))
    if not ok then
        return nil, "failed to insert event in shm: " .. err
    end

    return true
end


function _M:poll()
    local idx, err = self.dict:get(INDEX_KEY)
    if err then
        return nil, "failed to get index: " .. err
    end

    if not idx then
        -- no events to poll
        return true
    end

    if type(idx) ~= "number" then
        return nil, "index is not a number, shm tampered with"
    end

    for _ = self.idx, idx - 1 do
        self.idx = self.idx + 1

        local v, err = self.dict:get(self.idx)
        if err then
            return nil, "failed to get event from shm: " .. err
        end

        if not v then
            return nil, "no event at index: " .. idx
        end

        local event = unmarshall(v)

        if self.pid ~= event.pid then
            -- coming from another worker
            local cbs = self.callbacks[event.channel]
            if cbs then
                for j = 1, #cbs do
                    cbs[j](event.data)
                end
            end
        end
    end

    return true
end


return _M
