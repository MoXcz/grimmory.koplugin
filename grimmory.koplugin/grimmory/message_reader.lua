---Splits the null-delimited messages a subprocess writes to its pipe.
---@class GrimmoryMessageReader
---@field read_chunk fun(): string | nil returns the bytes available now, or nil when there are none
---@field private buffered string
local GrimmoryMessageReader = {}

function GrimmoryMessageReader:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.buffered = ""
    return o
end

---@return string | nil message the next complete message, or nil until one is fully buffered
function GrimmoryMessageReader:next()
    local message_end = self.buffered:find("\0", 1, true)

    if not message_end then
        local chunk = self.read_chunk()
        if chunk == nil then
            return nil
        end

        self.buffered = self.buffered .. chunk

        message_end = self.buffered:find("\0", 1, true)
        if not message_end then
            return nil
        end
    end

    local message = self.buffered:sub(1, message_end - 1)
    self.buffered = self.buffered:sub(message_end + 1)

    return message
end

return GrimmoryMessageReader
