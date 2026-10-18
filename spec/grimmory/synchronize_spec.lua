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
    local ReadCollection = {
        coll = {},
        coll_settings = {},
        write = function() end,
    }

    function ReadCollection:addCollection(name)
        self.coll_settings[name] = { order = 1 }
        self.coll[name] = {}
    end

    function ReadCollection:renameCollection(name, new_name)
        self.coll_settings[new_name] = self.coll_settings[name]
        self.coll[new_name] = self.coll[name]
        self.coll_settings[name] = nil
        self.coll[name] = nil
    end

    return ReadCollection
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

    describe("synchronizeShelves", function()
        local ReadCollection = require("readcollection")

        ---@param shelves { id: number, name: string }[]
        ---@param connections { [string]: number | string | false } collection name to its shelf ID, false when unlinked
        ---@return string[] states the progress states the sync reported
        local function synchronize_shelves(shelves, connections)
            ReadCollection.coll = {}
            ReadCollection.coll_settings = {}

            for name, connector_id in pairs(connections) do
                ReadCollection.coll[name] = {}
                ReadCollection.coll_settings[name] = { order = 1, connectorId = connector_id or nil }
            end

            local synchronizer = GrimmorySynchronize:new({
                settings = new_settings({ getSyncShelves = true }),
                api = { getShelves = function() return true, shelves end },
            })

            local states, callback = collect_states()
            synchronizer:synchronizeShelves(callback)

            return states
        end

        ---@return { [string]: number | string | false } collection name to its shelf ID, false when unlinked
        local function connector_ids()
            local result = {}

            for name, settings in pairs(ReadCollection.coll_settings) do
                result[name] = settings.connectorId or false
            end

            return result
        end

        it("attaches a collection whose name differs from the shelf only in case", function()
            local states = synchronize_shelves({ { id = 5, name = "Fantasy" } }, { fantasy = false })

            assert.are.same({ fantasy = 5 }, connector_ids())
            assert.are.same({ "shelf-connect" }, states)
        end)

        it("attaches the collection named exactly like the shelf", function()
            synchronize_shelves({ { id = 5, name = "Fantasy" } }, { fantasy = false, Fantasy = false, FANTASY = false })

            assert.are.same({ fantasy = false, Fantasy = 5, FANTASY = false }, connector_ids())
        end)

        it("keeps a connected collection when its shelf changes only in case", function()
            local states = synchronize_shelves({ { id = 5, name = "sci-fi" } }, { ["Sci-Fi"] = 5 })

            assert.are.same({ ["Sci-Fi"] = 5 }, connector_ids())
            assert.are.same({}, states)
        end)

        it("keeps a collection connected with a shelf ID stored as a string", function()
            local states = synchronize_shelves({ { id = 5, name = "Fantasy" } }, { Fantasy = "5" })

            assert.are.same({ Fantasy = "5" }, connector_ids())
            assert.are.same({}, states)
        end)

        it("unlinks the twin of a collection that already mirrors the shelf", function()
            local states = synchronize_shelves({ { id = 5, name = "Fantasy" } }, { fantasy = 5, Fantasy = "5" })

            assert.are.same({ fantasy = false, Fantasy = "5" }, connector_ids())
            assert.are.same({ "shelf-disconnect" }, states)
        end)

        it("renames a connected collection after its shelf", function()
            local states = synchronize_shelves({ { id = 5, name = "Space" } }, { ["Sci-Fi"] = 5 })

            assert.are.same({ Space = 5 }, connector_ids())
            assert.are.same({ "shelf-rename" }, states)
        end)

        it("does not rename a collection onto another one", function()
            synchronize_shelves({ { id = 5, name = "Taken" } }, { Old = 5, Taken = false })

            assert.are.same({ Old = 5, Taken = false }, connector_ids())
        end)

        it("does not add a collection over one that uses the shelf's name", function()
            synchronize_shelves(
                { { id = 5, name = "Taken" }, { id = 9, name = "Other" } },
                { Taken = 9, Other = false }
            )

            assert.are.same({ Taken = 9, Other = false }, connector_ids())
        end)

        it("adds a collection for a new shelf", function()
            local states = synchronize_shelves({ { id = 7, name = "New" } }, {})

            assert.are.same({ New = 7 }, connector_ids())
            assert.are.same({ "shelf-add" }, states)
        end)

        it("reconnects a collection whose shelf was recreated", function()
            local states = synchronize_shelves({ { id = 8, name = "Favorites" } }, { Favorites = 3 })

            assert.are.same({ Favorites = 8 }, connector_ids())
            assert.are.same({ "shelf-disconnect", "shelf-connect" }, states)
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
        local progress = { book_path = "/books/a.epub", book_md5 = "abc", end_time = 200, end_progress = 50 }

        local function new_synchronizer(last_synced_at, push_ok, push_decision, remote_percent)
            local repository = {
                getReadingProgress = function() return true, progress end,
                getBookSyncTimestamp = function() return true, last_synced_at end,
                updateBookSyncTimestamp = spy.new(function() end),
            }

            local reading_progress_manager = {
                pushRemoteProgress = spy.new(function() return push_ok end),
                getPushDecision = function()
                    return push_decision or "push", remote_percent
                end,
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

        it("reports where the remote progress was before the push", function()
            local synchronizer = new_synchronizer(100, true, "push", 20)

            local progress_messages = {}
            synchronizer:pushBookProgress(1, function(message)
                table.insert(progress_messages, message)
            end)

            assert.are.equal(20, progress_messages[1].from_progress)
            assert.are.equal(50, progress_messages[1].to_progress)
        end)

        it("does not push progress that would move the remote back", function()
            local synchronizer = new_synchronizer(100, true, "keep-remote", 100)

            local states, callback = collect_states()
            synchronizer:pushBookProgress(1, callback)

            assert.are.same({ "progress-kept" }, states)
            assert.spy(synchronizer.reading_progress_manager.pushRemoteProgress).was_not_called()
            assert.spy(synchronizer.repository.updateBookSyncTimestamp)
                .was_called_with(synchronizer.repository, 1, "progress", 200)
        end)

        it("does not push blindly when the remote progress is unreadable", function()
            local synchronizer = new_synchronizer(100, true, "unknown")

            local states, callback = collect_states()
            synchronizer:pushBookProgress(1, callback)

            assert.are.same({ "progress-failed" }, states)
            assert.spy(synchronizer.reading_progress_manager.pushRemoteProgress).was_not_called()
            assert.spy(synchronizer.repository.updateBookSyncTimestamp).was_not_called()
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

    describe("pullBookProgress", function()
        local remote_progress = { book_path = "/books/a.epub", end_progress = 60 }

        local function new_synchronizer(decision, local_percent, is_open_book)
            return GrimmorySynchronize:new({
                settings = new_settings(),
                reading_progress_manager = {
                    getPullDecision = function() return decision, local_percent, remote_progress end,
                    isOpenBook = function() return is_open_book == true end,
                    applyProgress = spy.new(function() end),
                },
            })
        end

        it("applies newer remote progress and reports the change", function()
            local synchronizer = new_synchronizer("apply", 30)

            local progress_messages = {}
            synchronizer:pullBookProgress("/books/a.epub", function(message)
                table.insert(progress_messages, message)
            end)

            assert.spy(synchronizer.reading_progress_manager.applyProgress)
                .was_called_with(synchronizer.reading_progress_manager, remote_progress)
            assert.are.same({
                { state = "progress-pulled", book_path = "/books/a.epub", from_progress = 30, to_progress = 60 },
            }, progress_messages)
        end)

        it("only announces newer progress for the open book", function()
            local synchronizer = new_synchronizer("apply", 30, true)

            local states, callback = collect_states()
            synchronizer:pullBookProgress("/books/a.epub", callback)

            assert.are.same({ "progress-available" }, states)
            assert.spy(synchronizer.reading_progress_manager.applyProgress).was_not_called()
        end)

        it("keeps local progress that is further ahead", function()
            local synchronizer = new_synchronizer("keep-local", 100)

            local states, callback = collect_states()
            synchronizer:pullBookProgress("/books/a.epub", callback)

            assert.are.same({ "progress-kept" }, states)
            assert.spy(synchronizer.reading_progress_manager.applyProgress).was_not_called()
        end)

        it("stays silent when there is nothing to pull", function()
            local synchronizer = new_synchronizer("none", 60)

            local states, callback = collect_states()
            synchronizer:pullBookProgress("/books/a.epub", callback)

            assert.are.same({}, states)
            assert.spy(synchronizer.reading_progress_manager.applyProgress).was_not_called()
        end)
    end)

    describe("removeBook", function()
        local util = require("util")
        local ReadCollection = require("readcollection")

        local function new_synchronizer(is_open_book)
            return GrimmorySynchronize:new({
                reading_progress_manager = { isOpenBook = function() return is_open_book end },
                doc_metadata = { purge = spy.new(function() end) },
            })
        end

        before_each(function()
            util.removeFile = spy.new(function() return true end)
            ReadCollection.removeItem = spy.new(function() end)
        end)

        after_each(function()
            util.removeFile = nil
            ReadCollection.removeItem = nil
        end)

        it("removes a book that is not open", function()
            local synchronizer = new_synchronizer(false)

            synchronizer:removeBook("/books/a.epub")

            assert.spy(util.removeFile).was_called_with("/books/a.epub")
            assert.spy(synchronizer.doc_metadata.purge).was_called_with(synchronizer.doc_metadata, "/books/a.epub")
        end)

        it("does not remove the book that is open", function()
            local synchronizer = new_synchronizer(true)

            synchronizer:removeBook("/books/a.epub")

            assert.spy(util.removeFile).was_not_called()
            assert.spy(synchronizer.doc_metadata.purge).was_not_called()
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
