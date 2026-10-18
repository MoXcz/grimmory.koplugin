local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

local GrimmoryMessageReader = require("grimmory/message_reader")

---@param chunks (string | false)[] what each read returns; false means nothing is waiting
local function new_reader(chunks)
    local read_index = 0

    return GrimmoryMessageReader:new({
        read_chunk = function()
            read_index = read_index + 1
            return chunks[read_index] or nil
        end,
    })
end

describe("GrimmoryMessageReader", function()
    it("returns nothing until a message is complete", function()
        local reader = new_reader({ '{"state":', false, '"a"}\0' })

        assert.is_nil(reader:next())
        assert.is_nil(reader:next())
        assert.are.equal('{"state":"a"}', reader:next())
    end)

    it("splits several messages that arrive in one read", function()
        local reader = new_reader({ "one\0two\0three\0" })

        assert.are.equal("one", reader:next())
        assert.are.equal("two", reader:next())
        assert.are.equal("three", reader:next())
        assert.is_nil(reader:next())
    end)

    it("keeps a partial message for the following read", function()
        local reader = new_reader({ "first\0sec", "ond\0" })

        assert.are.equal("first", reader:next())
        assert.are.equal("second", reader:next())
    end)

    it("returns nothing when no data is waiting", function()
        local reader = new_reader({})

        assert.is_nil(reader:next())
    end)
end)
