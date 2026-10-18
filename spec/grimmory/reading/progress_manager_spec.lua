local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

package.preload["grimmory/logger"] = function()
    local quiet = function() end

    return {
        new = function()
            return { err = quiet, warn = quiet, info = quiet, dbg = quiet }
        end
    }
end

package.preload["ui/event"] = function()
    return {}
end

package.preload["util"] = function()
    return {}
end

package.preload["ffi/sha2"] = function()
    return { md5 = function() return "md5" end }
end

-- Maps a path to what realpath resolves it to; false stands for a missing file.
local resolved_paths = {}

package.preload["ffi/util"] = function()
    return {
        realpath = function(path)
            local resolved_path = resolved_paths[path]

            if resolved_path == false then
                return nil
            end

            return resolved_path or path
        end,
    }
end

local ReadingProgressManager = require("grimmory/reading/progress_manager")

---@param recorded table | nil progress from the plugin's recorded events
---@param sidecar_percent number | nil position stored in the book sidecar
---@param remote table | nil progress on the server
local function new_manager(recorded, sidecar_percent, remote)
    local manager = ReadingProgressManager:new({
        doc_metadata = {
            getProgressPercent = function() return sidecar_percent end,
        },
    })

    manager.getLocalProgressForBook = function() return recorded end
    manager.getRemoteProgressForBook = function() return "Phone", "id", remote end

    return manager
end

describe("ReadingProgressManager", function()
    describe("isOpenBook", function()
        local function manager_reading(file)
            return ReadingProgressManager:new({ ui = { document = file and { file = file } } })
        end

        before_each(function()
            resolved_paths = {}
        end)

        it("recognizes the open book through a relative download path", function()
            resolved_paths["grimmory//a.epub"] = "/books/grimmory/a.epub"

            assert.is_true(manager_reading("/books/grimmory/a.epub"):isOpenBook("grimmory//a.epub"))
        end)

        it("does not match another book", function()
            assert.is_false(manager_reading("/books/a.epub"):isOpenBook("/books/b.epub"))
        end)

        it("does not match a file that no longer exists", function()
            resolved_paths["/books/a.epub"] = false

            assert.is_false(manager_reading("/books/a.epub"):isOpenBook("/books/a.epub"))
        end)

        it("is false when no book is open", function()
            assert.is_false(manager_reading(nil):isOpenBook("/books/a.epub"))
        end)
    end)

    describe("getPullDecision", function()
        it("applies remote progress that is newer and further ahead", function()
            local manager = new_manager(
                { end_time = 100, end_progress = 30 },
                30,
                { end_time = 200, end_progress = 60 }
            )

            local decision, local_percent, remote_progress = manager:getPullDecision("/books/a.epub")

            assert.are.equal("apply", decision)
            assert.are.equal(30, local_percent)
            assert.are.equal(60, remote_progress.end_progress)
        end)

        it("keeps local progress when newer remote progress is further back", function()
            local manager = new_manager(
                { end_time = 100, end_progress = 100 },
                100,
                { end_time = 200, end_progress = 34 }
            )

            assert.are.equal("keep-local", (manager:getPullDecision("/books/a.epub")))
        end)

        it("protects a finished book that has no recorded events", function()
            local manager = new_manager(nil, 100, { end_time = 200, end_progress = 34 })

            assert.are.equal("keep-local", (manager:getPullDecision("/books/a.epub")))
        end)

        it("ignores a tiny backward difference from another layout", function()
            local manager = new_manager(nil, 34, { end_time = 200, end_progress = 33.6 })

            assert.are.equal("none", (manager:getPullDecision("/books/a.epub")))
        end)

        it("leaves a reread on this device alone even when the remote is ahead", function()
            local manager = new_manager(
                { end_time = 300, end_progress = 5 },
                5,
                { end_time = 200, end_progress = 100 }
            )

            assert.are.equal("none", (manager:getPullDecision("/books/a.epub")))
        end)

        it("ignores remote progress that is older than local", function()
            local manager = new_manager(
                { end_time = 300, end_progress = 30 },
                30,
                { end_time = 200, end_progress = 60 }
            )

            assert.are.equal("none", (manager:getPullDecision("/books/a.epub")))
        end)

        it("does nothing when the sidecar already matches the remote", function()
            local manager = new_manager(nil, 60, { end_time = 200, end_progress = 60 })

            assert.are.equal("none", (manager:getPullDecision("/books/a.epub")))
        end)

        it("applies remote progress to a book never opened on this device", function()
            local manager = new_manager(nil, nil, { end_time = 200, end_progress = 60 })

            assert.are.equal("apply", (manager:getPullDecision("/books/a.epub")))
        end)

        it("does nothing without remote progress", function()
            local manager = new_manager({ end_time = 100, end_progress = 30 }, 30, nil)

            assert.are.equal("none", (manager:getPullDecision("/books/a.epub")))
        end)
    end)

    describe("getPushDecision", function()
        local local_progress = { book_path = "/books/a.epub", end_progress = 34 }

        it("keeps the remote when it is further ahead", function()
            local manager = new_manager(nil, nil, { end_time = 200, end_progress = 100 })

            local decision, remote_percent = manager:getPushDecision(local_progress)

            assert.are.equal("keep-remote", decision)
            assert.are.equal(100, remote_percent)
        end)

        it("pushes ahead of the remote", function()
            local manager = new_manager(nil, nil, { end_time = 200, end_progress = 20 })

            assert.are.equal("push", (manager:getPushDecision(local_progress)))
        end)

        it("pushes when layout differences put the remote slightly ahead", function()
            local manager = new_manager(nil, nil, { end_time = 200, end_progress = 34.4 })

            assert.are.equal("push", (manager:getPushDecision(local_progress)))
        end)

        it("pushes when the remote has no progress", function()
            local manager = new_manager(nil, nil, nil)

            assert.are.equal("push", (manager:getPushDecision(local_progress)))
        end)

        it("is unknown when the remote cannot be read", function()
            local manager = new_manager(nil, nil, nil)
            manager.getRemoteProgressForBook = function() return nil, nil, nil, true end

            assert.are.equal("unknown", (manager:getPushDecision(local_progress)))
        end)
    end)
end)
