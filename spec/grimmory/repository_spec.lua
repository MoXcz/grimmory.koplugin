local assert = require 'luassert'
local spy = require 'luassert.spy'
local stub = require 'luassert.stub'

package.path = "grimmory.koplugin/?.lua;" .. package.path

package.preload["lua-ljsqlite3/init"] = function()
    return {}
end

package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/settings" end }
end

package.preload["ffi/util"] = function()
    return {}
end

package.preload["util"] = function()
    return { directoryExists = function() return false end }
end

package.preload["grimmory/plugin_metadata"] = function()
    return { getPluginPath = function() return "/plugins/grimmory.koplugin" end }
end

package.preload["grimmory/logger"] = function()
    local quiet = function() end

    return {
        new = function()
            return { err = quiet, warn = quiet, info = quiet, dbg = quiet }
        end
    }
end

local GrimmoryLocalRepository = require("grimmory/repository")

-- Preloads outlive this file under busted; drop the fake so plugin_metadata_spec loads the real module.
package.preload["grimmory/plugin_metadata"] = nil

local NOW = 10000

---@param timestamps number[] when each page event of one book happened
local function pending_sessions_for(timestamps)
    local events = {}
    for index, timestamp in ipairs(timestamps) do
        table.insert(events, {
            grimmory_id = 5,
            book_md5 = "md5",
            book_path = "/books/a.epub",
            event_type = "page",
            timestamp = timestamp,
            page = index,
            page_count = 100,
        })
    end

    local repository = GrimmoryLocalRepository:new()
    repository.getPendingSessionEvents = function() return events end

    return repository:getPendingSessions(1)
end

describe("GrimmoryLocalRepository", function()
    local os_time

    before_each(function()
        os_time = stub(os, "time").returns(NOW)
    end)

    after_each(function()
        os_time:revert()
    end)

    describe("getPendingSessions", function()
        it("finishes a session once the collapse window has passed", function()
            local sessions = pending_sessions_for({ NOW - 300, NOW - 181 })

            assert.are.equal(1, #sessions)
            assert.is_true(sessions[1].is_finished)
        end)

        it("keeps a session open while a new event could still extend it", function()
            local sessions = pending_sessions_for({ NOW - 300, NOW - 180 })

            assert.is_false(sessions[1].is_finished)
        end)

        it("finishes only the older of two sessions split by a gap", function()
            local sessions = pending_sessions_for({ NOW - 2000, NOW - 1900, NOW - 10 })

            assert.are.equal(2, #sessions)
            assert.is_true(sessions[1].is_finished)
            assert.is_false(sessions[2].is_finished)
        end)
    end)

    describe("upsertBook", function()
        local SQ3 = require("lua-ljsqlite3/init")
        local ffiUtil = require("ffi/util")
        local util = require("util")

        local bound_checksums

        before_each(function()
            bound_checksums = {}
            ffiUtil.realpath = function(path) return path end
            util.partialMD5 = spy.new(function() return "md5-read" end)

            -- Every statement upsertBook prepares binds the path and the checksum, and finds book 1 on Grimmory 5.
            SQ3.open = function()
                return {
                    set_busy_timeout = function() end,
                    close = function() end,
                    prepare = function()
                        return {
                            bind = function(_, _, checksum) table.insert(bound_checksums, checksum) end,
                            step = function() return { 1, 5 } end,
                            close = function() end,
                        }
                    end,
                }
            end
        end)

        after_each(function()
            ffiUtil.realpath = nil
            util.partialMD5 = nil
            SQ3.open = nil
        end)

        it("uses the checksum the caller already has", function()
            local ok, book_id, grimmory_id = GrimmoryLocalRepository:new():upsertBook("/books/a.epub", 5, "md5-known")

            assert.is_true(ok)
            assert.are.equal(1, book_id)
            assert.are.equal(5, grimmory_id)
            assert.spy(util.partialMD5).was_not_called()
            assert.are.same({ "md5-known", "md5-known" }, bound_checksums)
        end)

        it("reads the checksum when the caller has none", function()
            GrimmoryLocalRepository:new():upsertBook("/books/a.epub", 5)

            assert.spy(util.partialMD5).was_called_with("/books/a.epub")
            assert.are.same({ "md5-read", "md5-read" }, bound_checksums)
        end)
    end)
end)
