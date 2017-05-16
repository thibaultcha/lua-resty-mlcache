-- vim: st=4 sts=4 sw=4 et:

local ffi = require "ffi"


local ERR          = ngx.ERR
local WARN         = ngx.WARN
local INFO         = ngx.INFO
local sleep        = ngx.sleep
local shared       = ngx.shared
local worker_pid   = ngx.worker.pid
local ngx_now      = ngx.now
local ngx_log      = ngx.log
local min          = math.min
local type         = type
local pcall        = pcall
local insert       = table.insert
local ffi_str      = ffi.string
local ffi_cast     = ffi.cast
local setmetatable = setmetatable


ffi.cdef [[
    struct event {
        unsigned int    at;
        unsigned int    pid;
        unsigned int    data_len;
        unsigned int    channel_len;
        unsigned char  *channel;
        unsigned char  *data;
    };
]]


local INDEX_KEY        = "lua-resty-ipc:index"
local POLL_SLEEP_RATIO = 2


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


local function log(lvl, ...)
    return ngx_log(lvl, "[ipc] ", ...)
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

    local marshalled_event = marshall {
        at      = now(),
        pid     = worker_pid(),
        channel = channel,
        data    = data,
    }

    local idx, err = self.dict:incr(INDEX_KEY, 1, 0)
    if not idx then
        return nil, "failed to increment index: " .. err
    end

    local ok, err = self.dict:set(idx, marshalled_event)
    if not ok then
        return nil, "failed to insert event in shm: " .. err
    end

    return true
end


function _M:poll(max_event_wait)
    if max_event_wait ~= nil and type(max_event_wait) ~= "number" then
        return nil, "max_event_wait must be a number"
    end

    local idx, err = self.dict:get(INDEX_KEY)
    if err then
        return nil, "failed to get index: " .. err
    end

    if idx == nil then
        -- no events to poll yet
        return true
    end

    if type(idx) ~= "number" then
        return nil, "index is not a number, shm tampered with"
    end

    for _ = self.idx, idx - 1 do
        self.idx = self.idx + 1

        -- fetch event from shm with a retry policy in case
        -- we run our :get() in between another worker's
        -- :incr() and :set()

        local v

        do
            local perr
            local pok        = true
            local elapsed    = 0
            local sleep_step = 0.001

            if not max_event_wait then
                max_event_wait = 0.3
            end

            while elapsed < max_event_wait do
                v, err = self.dict:get(self.idx)
                if err then
                    log(ERR, "failed to get event from shm: ", err)
                end

                if v ~= nil or err then
                    break
                end

                if pok then
                    log(INFO, "no event data at index '", self.idx, "', ",
                              "retrying in: ", sleep_step, "s")

                    -- sleep is not available in all ngx_lua contexts
                    -- if we fail once, never retry to sleep
                    pok, perr = pcall(sleep, sleep_step)
                    if not pok then
                        log(WARN, "could not sleep before retry: ", perr,
                                  " (note: it is safer to call this function ",
                                  " in contexts that support the ngx.sleep()",
                                  " API)")
                    end
                end

                elapsed    = elapsed + sleep_step
                sleep_step = min(sleep_step * POLL_SLEEP_RATIO,
                                 max_event_wait - elapsed)
            end
        end

        if v == nil then
            log(ERR, "could not get event at index: '", self.idx, "'")

        elseif type(v) ~= "string" then
            log(ERR, "event at index '", self.idx, "' is not a string, ",
                     "shm tampered with")

        else
            local event = unmarshall(v)

            if self.pid ~= event.pid then
                -- coming from another worker
                local cbs = self.callbacks[event.channel]
                if cbs then
                    for j = 1, #cbs do
                        local pok, perr = pcall(cbs[j], event.data)
                        if not pok then
                            log(ERR, "callback for channel '", event.channel,
                                     "' threw a Lua error: ", perr)
                        end
                    end
                end
            end
        end
    end

    return true
end


return _M
