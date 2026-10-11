local assert = require 'luassert'
local spy = require 'luassert.spy'
local stub = require 'luassert.stub'

package.path = "grimmory.koplugin/?.lua;" .. package.path

local fake_logger = {
    err = function() end,
    warn = function() end,
    info = function() end,
    dbg = function() end,
}

package.preload["grimmory/logger"] = function()
    return {
        new = function()
            return fake_logger
        end
    }
end

package.preload["readcollection"] = function()
    return {
        coll = {},
        coll_settings = {},
        write = function() end,
    }
end

package.preload["ffi/MD5"] = function()
    return {}
end

package.preload["util"] = function()
    return {}
end

local GrimmorySynchronize = require("grimmory/synchronize")

local function collect_states()
    local states = {}

    local callback = function(progress)
        table.insert(states, progress.state)
    end

    return states, callback
end

local function new_settings(overrides)
    local values = {
        getSyncReadingProgress = true,
        getSyncReadingSessions = true,
        getSyncAnnotations = true,
        getSessionThresholdPages = 1,
        getSessionThresholdSeconds = 60,
    }

    for key, value in pairs(overrides or {}) do
        values[key] = value
    end

    local settings = {}
    for key, value in pairs(values) do
        settings[key] = function() return value end
    end

    return settings
end

describe("GrimmorySynchronize", function()
    describe("synchronizeAll", function()
        it("pushes before it pulls", function()
            local synchronizer = GrimmorySynchronize:new({
                api = { getServerVersion = function() return true, "1.0.0" end },
            })

            local call_order = {}
            for _, step in ipairs({
                "pushAllPendingBookMetadata",
                "synchronizeShelves",
                "pullBooks",
                "removeEmptyShelves",
            }) do
                stub(synchronizer, step, function()
                    table.insert(call_order, step)
                end)
            end

            synchronizer:synchronizeAll(function() end)

            assert.are.same({
                "pushAllPendingBookMetadata",
                "synchronizeShelves",
                "pullBooks",
                "removeEmptyShelves",
            }, call_order)
        end)

        it("fails when the server is unreachable", function()
            local synchronizer = GrimmorySynchronize:new({
                api = { getServerVersion = function() return false, "timeout" end },
            })

            stub(synchronizer, "pushAllPendingBookMetadata")

            assert.has_error(function()
                synchronizer:synchronizeAll(function() end)
            end)

            assert.stub(synchronizer.pushAllPendingBookMetadata).was_not_called()
        end)
    end)

    describe("pushAllPendingBookMetadata", function()
        it("reports each pushed book with the state the UI expects", function()
            local synchronizer = GrimmorySynchronize:new({
                settings = new_settings(),
                repository = { getBooksPendingSync = function() return { 7, 9 } end },
            })

            stub(synchronizer, "pushBookMetadata")

            local progress_messages = {}
            synchronizer:pushAllPendingBookMetadata(function(progress)
                table.insert(progress_messages, progress)
            end)

            assert.are.same({
                { state = "book-push-metadata", book_id = 7, pushed_books = 1, total_books = 2 },
                { state = "book-push-metadata", book_id = 9, pushed_books = 2, total_books = 2 },
            }, progress_messages)
        end)

        it("keeps going when one book fails", function()
            local synchronizer = GrimmorySynchronize:new({
                settings = new_settings(),
                repository = { getBooksPendingSync = function() return { 7, 9 } end },
            })

            stub(synchronizer, "pushBookMetadata", function() error("boom") end)

            local states, callback = collect_states()
            synchronizer:pushAllPendingBookMetadata(callback)

            assert.are.same({ "book-push-metadata", "book-push-metadata" }, states)
        end)
    end)

    describe("pushBookProgress", function()
        local progress = { book_path = "/books/a.epub", book_md5 = "abc", end_time = 200 }

        local function new_synchronizer(last_synced_at, push_ok)
            local repository = {
                getReadingProgress = function() return true, progress end,
                getBookSyncTimestamp = function() return true, last_synced_at end,
                updateBookSyncTimestamp = spy.new(function() end),
            }

            local reading_progress_manager = {
                pushRemoteProgress = spy.new(function() return push_ok end),
            }

            return GrimmorySynchronize:new({
                settings = new_settings(),
                repository = repository,
                reading_progress_manager = reading_progress_manager,
            })
        end

        it("pushes newer progress and records the sync time", function()
            local synchronizer = new_synchronizer(100, true)

            local states, callback = collect_states()
            synchronizer:pushBookProgress(1, callback)

            assert.are.same({ "progress-pushed" }, states)
            assert.spy(synchronizer.repository.updateBookSyncTimestamp)
                .was_called_with(synchronizer.repository, 1, "progress", 200)
        end)

        it("skips progress that is already synced", function()
            local synchronizer = new_synchronizer(200, true)

            local states, callback = collect_states()
            synchronizer:pushBookProgress(1, callback)

            assert.are.same({}, states)
            assert.spy(synchronizer.reading_progress_manager.pushRemoteProgress).was_not_called()
        end)

        it("reports a failed push without recording the sync time", function()
            local synchronizer = new_synchronizer(nil, false)

            local states, callback = collect_states()
            synchronizer:pushBookProgress(1, callback)

            assert.are.same({ "progress-failed" }, states)
            assert.spy(synchronizer.repository.updateBookSyncTimestamp).was_not_called()
        end)

        it("does nothing when progress sync is disabled", function()
            local synchronizer = new_synchronizer(nil, true)
            synchronizer.settings = new_settings({ getSyncReadingProgress = false })

            local states, callback = collect_states()
            synchronizer:pushBookProgress(1, callback)

            assert.are.same({}, states)
            assert.spy(synchronizer.reading_progress_manager.pushRemoteProgress).was_not_called()
        end)
    end)

    describe("pushBookSessions", function()
        local function session(overrides)
            local base = {
                grimmory_id = 5,
                book_path = "/books/a.epub",
                start_time = 0,
                end_time = 600,
                start_page = 1,
                end_page = 10,
                start_progress = 0,
                end_progress = 10,
            }

            for key, value in pairs(overrides or {}) do
                base[key] = value
            end

            return base
        end

        local function new_synchronizer(sessions, record_results)
            local record_index = 0

            return GrimmorySynchronize:new({
                settings = new_settings(),
                repository = {
                    getPendingSessions = function() return sessions end,
                    updateBookSyncTimestamp = spy.new(function() end),
                },
                api = {
                    recordSession = spy.new(function()
                        record_index = record_index + 1
                        return record_results[record_index], "body"
                    end),
                },
            })
        end

        it("records sessions above the thresholds", function()
            local synchronizer = new_synchronizer({ session() }, { true })

            local states, callback = collect_states()
            synchronizer:pushBookSessions(1, callback)

            assert.are.same({ "session-recorded" }, states)
            assert.spy(synchronizer.repository.updateBookSyncTimestamp)
                .was_called_with(synchronizer.repository, 1, "sessions", 600)
        end)

        it("skips sessions shorter than the time threshold", function()
            local synchronizer = new_synchronizer({ session({ end_time = 30 }) }, {})

            local states, callback = collect_states()
            synchronizer:pushBookSessions(1, callback)

            assert.are.same({ "session-skip" }, states)
            assert.spy(synchronizer.api.recordSession).was_not_called()
        end)

        it("stops at the first failed session so it can be retried", function()
            local synchronizer = new_synchronizer({ session(), session() }, { false, true })

            local states, callback = collect_states()
            synchronizer:pushBookSessions(1, callback)

            assert.are.same({ "session-error" }, states)
            assert.spy(synchronizer.api.recordSession).was_called(1)
        end)

        it("reports an error for a book that is not linked to Grimmory", function()
            local unlinked_session = session()
            unlinked_session.grimmory_id = nil

            local synchronizer = new_synchronizer({ unlinked_session }, {})

            local states, callback = collect_states()
            synchronizer:pushBookSessions(1, callback)

            assert.are.same({ "session-error" }, states)
            assert.spy(synchronizer.api.recordSession).was_not_called()
        end)
    end)

    describe("synchronizeBook", function()
        local function new_synchronizer(sync_annotations)
            local synchronizer = GrimmorySynchronize:new({
                settings = new_settings({ getSyncAnnotations = sync_annotations }),
                api = { getServerVersion = function() return true, "1.0.0" end },
                repository = { upsertBook = function() return true, 1, 5 end },
            })

            local call_order = {}
            for _, step in ipairs({
                "pushBookAnnotations",
                "pullBookAnnotations",
                "pushBookMetadata",
                "pullBookProgress",
            }) do
                stub(synchronizer, step, function()
                    table.insert(call_order, step)
                end)
            end

            return synchronizer, call_order
        end

        it("pushes local changes before pulling remote ones", function()
            local synchronizer, call_order = new_synchronizer(true)

            synchronizer:synchronizeBook("/books/a.epub", false, function() end)

            assert.are.same({
                "pushBookAnnotations",
                "pullBookAnnotations",
                "pushBookMetadata",
                "pullBookProgress",
            }, call_order)
        end)

        it("leaves annotations alone when annotation sync is disabled", function()
            local synchronizer, call_order = new_synchronizer(false)

            synchronizer:synchronizeBook("/books/a.epub", false, function() end)

            assert.are.same({ "pushBookMetadata", "pullBookProgress" }, call_order)
        end)

        it("fails a refresh for a book that is not linked to Grimmory", function()
            local synchronizer = new_synchronizer(true)
            synchronizer.repository.upsertBook = function() return true, 1, nil end

            assert.has_error(function()
                synchronizer:synchronizeBook("/books/a.epub", true, function() end)
            end)
        end)
    end)
end)
