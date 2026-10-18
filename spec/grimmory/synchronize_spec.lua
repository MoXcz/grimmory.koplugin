local assert = require 'luassert'
local match = require 'luassert.match'
local spy = require 'luassert.spy'
local stub = require 'luassert.stub'

package.path = "grimmory.koplugin/?.lua;" .. package.path

local fake_logger = {
    err = spy.new(function() end),
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

            stub(synchronizer, "pushBookMetadata", function() error("boom", 0) end)

            local states, callback = collect_states()
            synchronizer:pushAllPendingBookMetadata(callback)

            assert.are.same({ "book-push-metadata", "book-push-metadata" }, states)
            assert.spy(fake_logger.err).was_called_with(fake_logger, "Failed to push metadata for book:", 7, "boom")
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

    describe("pullBook", function()
        local util = require("util")

        local function new_synchronizer()
            local synchronizer = GrimmorySynchronize:new({
                settings = new_settings(),
                repository = { upsertBook = spy.new(function() return true, 1, 5 end) },
            })

            stub(synchronizer, "getBookDownloadPath", function() return "/books/a.epub", "md5-a" end)
            stub(synchronizer, "associateWithShelves")
            stub(synchronizer, "pullBookProgress")

            return synchronizer
        end

        before_each(function()
            util.fileExists = function() return true end
            util.partialMD5 = spy.new(function() return "md5-read" end)
        end)

        after_each(function()
            util.fileExists = nil
            util.partialMD5 = nil
        end)

        it("reuses the checksum of a copy that is already downloaded", function()
            local synchronizer = new_synchronizer()

            synchronizer:pullBook({ id = 5 }, function() end)

            assert.spy(util.partialMD5).was_not_called()
            assert.spy(synchronizer.repository.upsertBook)
                .was_called_with(synchronizer.repository, "/books/a.epub", 5, "md5-a")
            assert.stub(synchronizer.pullBookProgress)
                .was_called_with(synchronizer, "/books/a.epub", match._, "md5-a")
        end)

        it("computes the checksum once for a book it had to look for", function()
            local synchronizer = new_synchronizer()
            synchronizer.getBookDownloadPath = function() return "/books/a.epub", nil end

            synchronizer:pullBook({ id = 5 }, function() end)

            assert.spy(util.partialMD5).was_called(1)
            assert.spy(synchronizer.repository.upsertBook)
                .was_called_with(synchronizer.repository, "/books/a.epub", 5, "md5-read")
        end)

        it("skips the progress lookup when the list shows Grimmory has none for the book", function()
            local synchronizer = new_synchronizer()
            synchronizer.is_koreader_progress_listed = true

            synchronizer:pullBook({ id = 5, has_koreader_progress = false }, function() end)

            assert.stub(synchronizer.pullBookProgress).was_not_called()
        end)

        it("still looks up progress while the list has never shown it", function()
            local synchronizer = new_synchronizer()
            synchronizer.is_koreader_progress_listed = false

            synchronizer:pullBook({ id = 5, has_koreader_progress = false }, function() end)

            assert.stub(synchronizer.pullBookProgress).was_called(1)
        end)
    end)

    describe("pullBooks", function()
        local util = require("util")

        ---@param listed_books table[] the books each sync's list returns
        local function new_synchronizer(listed_books)
            local synchronizer = GrimmorySynchronize:new({
                settings = new_settings({ getDownloadsBooks = true, getDownloadDirectory = "/books" }),
                repository = { upsertBook = function() return true, 1, 5 end },
                api = {
                    getBooks = function()
                        local index = 0

                        return function()
                            index = index + 1
                            if listed_books[index] ~= nil then
                                return listed_books[index], index, #listed_books
                            end
                        end
                    end,
                },
            })

            stub(synchronizer, "isTargetBook", function() return true end)
            stub(synchronizer, "getBookDownloadPath", function(_, book)
                return "/books/" .. book.id .. ".epub", "md5-" .. book.id
            end)
            stub(synchronizer, "associateWithShelves")
            stub(synchronizer, "pullBookProgress")

            return synchronizer
        end

        ---@return string[] paths the books whose progress was looked up
        local function progress_lookups(synchronizer)
            local paths = {}

            for _, call in ipairs(synchronizer.pullBookProgress.calls) do
                table.insert(paths, call.vals[2])
            end

            return paths
        end

        before_each(function()
            util.makePath = function() return true end
            util.fileExists = function() return true end
            util.findFiles = function() end
        end)

        after_each(function()
            util.makePath = nil
            util.fileExists = nil
            util.findFiles = nil
        end)

        it("skips progress lookups only after the list has shown KOReader progress, again for each sync", function()
            local listed_books = {
                { id = 1, has_koreader_progress = false },
                { id = 2, has_koreader_progress = true },
                { id = 3, has_koreader_progress = false },
            }
            local synchronizer = new_synchronizer(listed_books)

            synchronizer:pullBooks(function() end)

            assert.are.same({ "/books/1.epub", "/books/2.epub" }, progress_lookups(synchronizer))

            listed_books[2] = { id = 2, has_koreader_progress = false }
            synchronizer.pullBookProgress:clear()

            synchronizer:pullBooks(function() end)

            assert.are.same({ "/books/1.epub", "/books/2.epub", "/books/3.epub" }, progress_lookups(synchronizer))
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

        it("passes a known checksum on to the progress lookup", function()
            local synchronizer = new_synchronizer("none", 60)
            synchronizer.reading_progress_manager.getPullDecision = spy.new(function() return "none" end)

            synchronizer:pullBookProgress("/books/a.epub", function() end, "md5-a")

            assert.spy(synchronizer.reading_progress_manager.getPullDecision)
                .was_called_with(synchronizer.reading_progress_manager, "/books/a.epub", "md5-a")
        end)

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

        it("sends each session's book so Grimmory can tell its type", function()
            local synchronizer = new_synchronizer({ session() }, { true })

            synchronizer:pushBookSessions(1, function() end)

            assert.spy(synchronizer.api.recordSession).was_called_with(
                synchronizer.api, 5, 0, 600, 0, 10, "1", "10", "/books/a.epub"
            )
        end)

        it("skips sessions shorter than the time threshold", function()
            local synchronizer = new_synchronizer({ session({ end_time = 30 }) }, {})

            local states, callback = collect_states()
            synchronizer:pushBookSessions(1, callback)

            assert.are.same({ "session-skip" }, states)
            assert.spy(synchronizer.api.recordSession).was_not_called()
        end)

        it("moves past a short session that has finished", function()
            local synchronizer = new_synchronizer({ session({ end_time = 30, is_finished = true }) }, {})

            synchronizer:pushBookSessions(1, function() end)

            assert.spy(synchronizer.repository.updateBookSyncTimestamp)
                .was_called_with(synchronizer.repository, 1, "sessions", 30)
        end)

        it("moves past a finished session with too few pages", function()
            local synchronizer = new_synchronizer({ session({ end_page = 1, is_finished = true }) }, {})
            synchronizer.settings = new_settings({ getSessionThresholdPages = 5 })

            synchronizer:pushBookSessions(1, function() end)

            assert.spy(synchronizer.api.recordSession).was_not_called()
            assert.spy(synchronizer.repository.updateBookSyncTimestamp)
                .was_called_with(synchronizer.repository, 1, "sessions", 600)
        end)

        it("keeps a short session that may still grow pending", function()
            local synchronizer = new_synchronizer({ session({ end_time = 30, is_finished = false }) }, {})

            synchronizer:pushBookSessions(1, function() end)

            assert.spy(synchronizer.repository.updateBookSyncTimestamp).was_not_called()
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

    describe("pushBookAnnotations", function()
        ---@param options table annotations, modified IDs and the API answers (create_result, update_ok, delete_ok,
        ---refresh_ok and refreshed_remote_annotations for the reads after the first)
        local function new_synchronizer(options)
            local remote_reads = 0

            return GrimmorySynchronize:new({
                reading_annotations = {
                    getAnnotations = function()
                        return options.local_annotations ~= nil, options.local_annotations
                    end,
                    setGrimmoryIds = spy.new(function() end),
                },
                doc_metadata = {
                    getModifiedGrimmoryAnnotations = function() return options.modified_ids or {} end,
                    removeModifiedGrimmoryAnnotation = spy.new(function() end),
                    appendModifiedGrimmoryAnnotation = spy.new(function() end),
                },
                api = {
                    getAnnotations = spy.new(function()
                        remote_reads = remote_reads + 1

                        if remote_reads > 1 and options.refresh_ok == false then
                            return false, nil
                        end

                        if remote_reads > 1 and options.refreshed_remote_annotations ~= nil then
                            return true, options.refreshed_remote_annotations
                        end

                        return options.remote_ok ~= false, options.remote_annotations or {}
                    end),
                    createAnnotation = spy.new(function()
                        return options.create_result ~= false, options.create_result
                    end),
                    updateAnnotation = spy.new(function() return options.update_ok ~= false end),
                    deleteAnnotation = spy.new(function() return options.delete_ok ~= false end),
                },
            })
        end

        local function annotation(overrides)
            local base = { local_index = 1, cfi = "cfi-a", color = "#FFC107", style = "highlight", text = "text" }

            for key, value in pairs(overrides or {}) do
                base[key] = value
            end

            return base
        end

        it("stores the ID Grimmory assigns to a new annotation", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation({ local_index = 2 }) },
                create_result = 41,
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.reading_annotations.setGrimmoryIds).was_called_with(
                synchronizer.reading_annotations,
                "/books/a.epub",
                { { index = 2, grimmory_id = 41 } }
            )
            assert.spy(synchronizer.api.getAnnotations).was_called(1)
        end)

        it("links a new annotation to the unlinked one Grimmory already has at its CFI", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation() },
                remote_annotations = { { id = 9, cfi = "cfi-a", color = "#FFC107", style = "highlight" } },
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.api.createAnnotation).was_not_called()
            assert.spy(synchronizer.api.updateAnnotation).was_not_called()
            assert.spy(synchronizer.reading_annotations.setGrimmoryIds).was_called_with(
                synchronizer.reading_annotations,
                "/books/a.epub",
                { { index = 1, grimmory_id = 9 } }
            )
        end)

        it("keeps this device's note when linking to an existing Grimmory annotation", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation({ note = "mine" }) },
                remote_annotations = { { id = 9, cfi = "cfi-a", color = "#FFC107", style = "highlight" } },
                update_ok = false,
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.api.updateAnnotation)
                .was_called_with(synchronizer.api, 9, "#FFC107", "highlight", "mine")
            assert.spy(synchronizer.doc_metadata.appendModifiedGrimmoryAnnotation)
                .was_called_with(synchronizer.doc_metadata, "/books/a.epub", 9)
        end)

        it("leaves Grimmory's note alone when linking a highlight without one", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation() },
                remote_annotations = {
                    { id = 9, cfi = "cfi-a", color = "#FFC107", style = "highlight", note = "theirs" },
                },
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.api.updateAnnotation).was_not_called()
        end)

        it("keeps Grimmory's note when linking a restyled highlight without one", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation({ color = "#E91E63" }) },
                remote_annotations = {
                    { id = 9, cfi = "cfi-a", color = "#FFC107", style = "highlight", note = "theirs" },
                },
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.api.updateAnnotation)
                .was_called_with(synchronizer.api, 9, "#E91E63", "highlight", "theirs")
        end)

        it("updates a linked annotation whose style differs", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation({ style = "underline" }) },
                remote_annotations = { { id = 9, cfi = "cfi-a", color = "#FFC107", style = "highlight" } },
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.api.updateAnnotation)
                .was_called_with(synchronizer.api, 9, "#FFC107", "underline", nil)
        end)

        it("treats an empty note like a missing one when linking", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation({ note = "" }) },
                remote_annotations = { { id = 9, cfi = "cfi-a", color = "#FFC107", style = "highlight" } },
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.api.updateAnnotation).was_not_called()
        end)

        it("updates an edited annotation in place when it has not moved", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation({ id = 7, note = "new note" }) },
                remote_annotations = { { id = 7, cfi = "cfi-a" } },
                modified_ids = { 7 },
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.api.updateAnnotation)
                .was_called_with(synchronizer.api, 7, "#FFC107", "highlight", "new note")
            assert.spy(synchronizer.api.createAnnotation).was_not_called()
            assert.spy(synchronizer.api.deleteAnnotation).was_not_called()
            assert.spy(synchronizer.doc_metadata.removeModifiedGrimmoryAnnotation)
                .was_called_with(synchronizer.doc_metadata, "/books/a.epub", 7)
        end)

        it("keeps an edit pending when updating it fails", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation({ id = 7 }) },
                remote_annotations = { { id = 7, cfi = "cfi-a" } },
                modified_ids = { 7 },
                update_ok = false,
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.doc_metadata.removeModifiedGrimmoryAnnotation).was_not_called()
        end)

        it("creates a moved annotation before deleting its old copy", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation({ id = 7, cfi = "cfi-b" }) },
                remote_annotations = { { id = 7, cfi = "cfi-a" } },
                modified_ids = { 7 },
                create_result = 42,
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.reading_annotations.setGrimmoryIds).was_called_with(
                synchronizer.reading_annotations,
                "/books/a.epub",
                { { index = 1, grimmory_id = 42 } }
            )
            assert.spy(synchronizer.api.deleteAnnotation).was_called_with(synchronizer.api, 7)
            assert.spy(synchronizer.doc_metadata.removeModifiedGrimmoryAnnotation)
                .was_called_with(synchronizer.doc_metadata, "/books/a.epub", 7)
        end)

        it("keeps a moved annotation and its old copy when creating it fails", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation({ id = 7, cfi = "cfi-b" }) },
                remote_annotations = { { id = 7, cfi = "cfi-a" } },
                modified_ids = { 7 },
                create_result = false,
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.api.deleteAnnotation).was_not_called()
            assert.spy(synchronizer.reading_annotations.setGrimmoryIds).was_not_called()
            assert.spy(synchronizer.doc_metadata.removeModifiedGrimmoryAnnotation).was_not_called()
        end)

        it("keeps a removal pending when deleting the Grimmory copy fails", function()
            local synchronizer = new_synchronizer({
                local_annotations = {},
                remote_annotations = { { id = 9, cfi = "cfi-a" } },
                modified_ids = { 9 },
                delete_ok = false,
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.api.deleteAnnotation).was_called_with(synchronizer.api, 9)
            assert.spy(synchronizer.doc_metadata.removeModifiedGrimmoryAnnotation).was_not_called()
        end)

        it("forgets a removal that Grimmory no longer has", function()
            local synchronizer = new_synchronizer({ local_annotations = {}, modified_ids = { 9 } })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.api.deleteAnnotation).was_not_called()
            assert.spy(synchronizer.doc_metadata.removeModifiedGrimmoryAnnotation)
                .was_called_with(synchronizer.doc_metadata, "/books/a.epub", 9)
        end)

        it("leaves an edit pending when the annotation cannot be converted", function()
            local synchronizer = new_synchronizer({
                local_annotations = { { id = 7, local_index = 1 } },
                remote_annotations = { { id = 7, cfi = "cfi-a" } },
                modified_ids = { 7 },
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.api.updateAnnotation).was_not_called()
            assert.spy(synchronizer.api.deleteAnnotation).was_not_called()
            assert.spy(synchronizer.doc_metadata.removeModifiedGrimmoryAnnotation).was_not_called()
        end)

        it("links to the copy a create that seemed to fail left on Grimmory", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation() },
                create_result = false,
                refreshed_remote_annotations = { { id = 12, cfi = "cfi-a", color = "#FFC107", style = "highlight" } },
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.reading_annotations.setGrimmoryIds).was_called_with(
                synchronizer.reading_annotations,
                "/books/a.epub",
                { { index = 1, grimmory_id = 12 } }
            )
        end)

        it("reads Grimmory again only once for all creates that seemed to fail", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation({ local_index = 1 }), annotation({ local_index = 2, cfi = "cfi-b" }) },
                create_result = false,
                refreshed_remote_annotations = {
                    { id = 12, cfi = "cfi-a", color = "#FFC107", style = "highlight" },
                    { id = 13, cfi = "cfi-b", color = "#FFC107", style = "highlight" },
                },
            })

            local unchecked_cfis = synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.api.getAnnotations).was_called(2)
            assert.spy(synchronizer.reading_annotations.setGrimmoryIds).was_called_with(
                synchronizer.reading_annotations,
                "/books/a.epub",
                { { index = 1, grimmory_id = 12 }, { index = 2, grimmory_id = 13 } }
            )
            assert.are.same({}, unchecked_cfis)
        end)

        it("returns the CFIs of failed creates when Grimmory cannot be read again", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation({ local_index = 1 }), annotation({ local_index = 2, cfi = "cfi-b" }) },
                create_result = false,
                refresh_ok = false,
            })

            assert.are.same(
                { ["cfi-a"] = true, ["cfi-b"] = true },
                synchronizer:pushBookAnnotations("/books/a.epub", 5)
            )
        end)

        it("links a moved annotation whose create seemed to fail and deletes its old copy", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation({ id = 7, cfi = "cfi-b" }) },
                remote_annotations = { { id = 7, cfi = "cfi-a" } },
                modified_ids = { 7 },
                create_result = false,
                refreshed_remote_annotations = {
                    { id = 7, cfi = "cfi-a" },
                    { id = 42, cfi = "cfi-b", color = "#FFC107", style = "highlight" },
                },
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.reading_annotations.setGrimmoryIds).was_called_with(
                synchronizer.reading_annotations,
                "/books/a.epub",
                { { index = 1, grimmory_id = 42 } }
            )
            assert.spy(synchronizer.api.deleteAnnotation).was_called_with(synchronizer.api, 7)
        end)

        it("decides removals by the list read again after failed creates", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation() },
                remote_annotations = { { id = 9, cfi = "cfi-z" } },
                modified_ids = { 9 },
                create_result = false,
                refreshed_remote_annotations = {},
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.api.deleteAnnotation).was_not_called()
            assert.spy(synchronizer.doc_metadata.removeModifiedGrimmoryAnnotation)
                .was_called_with(synchronizer.doc_metadata, "/books/a.epub", 9)
        end)

        it("saves new IDs before deleting old copies", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation({ id = 7, cfi = "cfi-b" }) },
                remote_annotations = { { id = 7, cfi = "cfi-a" } },
                modified_ids = { 7 },
                create_result = 42,
            })
            local calls = {}
            synchronizer.reading_annotations.setGrimmoryIds = function()
                table.insert(calls, "setGrimmoryIds")
            end
            synchronizer.api.deleteAnnotation = function()
                table.insert(calls, "deleteAnnotation")
                return true
            end

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.are.same({ "setGrimmoryIds", "deleteAnnotation" }, calls)
        end)

        it("does not link a new annotation to a Grimmory one another annotation holds", function()
            local synchronizer = new_synchronizer({
                local_annotations = {
                    annotation({ id = 9, local_index = 1 }),
                    annotation({ local_index = 2 }),
                },
                remote_annotations = { { id = 9, cfi = "cfi-a" } },
                create_result = 43,
            })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.api.createAnnotation).was_called(1)
            assert.spy(synchronizer.reading_annotations.setGrimmoryIds).was_called_with(
                synchronizer.reading_annotations,
                "/books/a.epub",
                { { index = 2, grimmory_id = 43 } }
            )
        end)

        it("treats a create that returns no ID as failed", function()
            local synchronizer = new_synchronizer({ local_annotations = { annotation() } })

            synchronizer:pushBookAnnotations("/books/a.epub", 5)

            assert.spy(synchronizer.reading_annotations.setGrimmoryIds).was_not_called()
        end)

        it("saves the IDs created before a failure", function()
            local synchronizer = new_synchronizer({
                local_annotations = { annotation({ local_index = 1 }), annotation({ local_index = 2, cfi = "cfi-b" }) },
                create_result = 44,
            })
            local creates = 0
            synchronizer.api.createAnnotation = function()
                creates = creates + 1
                if creates == 2 then
                    error("connection reset", 0)
                end
                return true, 44
            end

            assert.has_error(function()
                synchronizer:pushBookAnnotations("/books/a.epub", 5)
            end, "connection reset")

            assert.spy(synchronizer.reading_annotations.setGrimmoryIds).was_called_with(
                synchronizer.reading_annotations,
                "/books/a.epub",
                { { index = 1, grimmory_id = 44 } }
            )
        end)

        it("fails before changing anything when Grimmory cannot be read", function()
            local synchronizer = new_synchronizer({ local_annotations = { annotation() }, remote_ok = false })

            assert.has_error(function()
                synchronizer:pushBookAnnotations("/books/a.epub", 5)
            end, "Could not read annotations from Grimmory")

            assert.spy(synchronizer.api.createAnnotation).was_not_called()
        end)

        it("fails before touching Grimmory when the annotations cannot be read", function()
            local synchronizer = new_synchronizer({ modified_ids = { 9 } })

            assert.has_error(function()
                synchronizer:pushBookAnnotations("/books/a.epub", 5)
            end)

            assert.spy(synchronizer.api.deleteAnnotation).was_not_called()
        end)
    end)

    describe("pullBookAnnotations", function()
        it("fails when Grimmory cannot be read", function()
            local synchronizer = GrimmorySynchronize:new({
                api = { getAnnotations = function() return false, nil end },
            })

            assert.has_error(function()
                synchronizer:pullBookAnnotations("/books/a.epub", 5)
            end)
        end)

        it("hands the CFIs to hold back to the book", function()
            local apply_annotations = spy.new(function() return true end)
            local synchronizer = GrimmorySynchronize:new({
                api = { getAnnotations = function() return true, {} end },
                reading_annotations = { applyAnnotations = apply_annotations },
            })
            local held_back_cfis = { ["cfi-a"] = true }

            synchronizer:pullBookAnnotations("/books/a.epub", 5, held_back_cfis)

            assert.spy(apply_annotations)
                .was_called_with(synchronizer.reading_annotations, "/books/a.epub", {}, held_back_cfis)
        end)

        it("fails when the annotations cannot be written to the book", function()
            local synchronizer = GrimmorySynchronize:new({
                api = { getAnnotations = function() return true, {} end },
                reading_annotations = { applyAnnotations = function() return false end },
            })

            assert.has_error(function()
                synchronizer:pullBookAnnotations("/books/a.epub", 5)
            end)
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

        it("keeps the pull from importing what the push could not check", function()
            local synchronizer = new_synchronizer(true)
            local unchecked_cfis = { ["cfi-a"] = true }
            synchronizer.pushBookAnnotations = function() return unchecked_cfis end

            synchronizer:synchronizeBook("/books/a.epub", false, function() end)

            assert.stub(synchronizer.pullBookAnnotations)
                .was_called_with(synchronizer, "/books/a.epub", 5, unchecked_cfis)
        end)

        it("leaves annotations alone when annotation sync is disabled", function()
            local synchronizer, call_order = new_synchronizer(false)

            synchronizer:synchronizeBook("/books/a.epub", false, function() end)

            assert.are.same({ "pushBookMetadata", "pullBookProgress" }, call_order)
        end)

        it("skips annotations for books that are not EPUB", function()
            local synchronizer, call_order = new_synchronizer(true)

            synchronizer:synchronizeBook("/books/a.pdf", false, function() end)

            assert.are.same({ "pushBookMetadata", "pullBookProgress" }, call_order)
        end)

        it("still syncs progress and sessions when annotations fail", function()
            local synchronizer, call_order = new_synchronizer(true)
            synchronizer.pushBookAnnotations = function() error("Could not read annotations", 0) end

            local progress_messages = {}
            synchronizer:synchronizeBook("/books/a.epub", false, function(message)
                table.insert(progress_messages, message)
            end)

            assert.are.same({ "pushBookMetadata", "pullBookProgress" }, call_order)
            assert.are.same({ state = "annotations-failed", book_path = "/books/a.epub" }, progress_messages[1])
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
