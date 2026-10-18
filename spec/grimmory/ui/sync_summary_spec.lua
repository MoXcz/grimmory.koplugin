local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

package.preload["gettext"] = function()
    return function(text) return text end
end

package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local arguments = { ... }

            return (text:gsub("%%(%d)", function(index)
                return tostring(arguments[tonumber(index)])
            end))
        end,
    }
end

local GrimmorySyncSummary = require("grimmory/ui/sync_summary")

describe("GrimmorySyncSummary", function()
    local kept_progress_message = {
        state = "progress-kept",
        book_path = "/books/a.epub",
        local_progress = 100,
        remote_progress = 34,
    }

    it("has no details for a sync that only checked books", function()
        local summary = GrimmorySyncSummary:new()

        summary:record({ state = "book-pull-metadata", book_path = "/books/a.epub" })
        summary:record({ state = "shelf-add" })

        assert.is_false(summary:hasDetails())
        assert.are.same({ { "Books already up to date", "1" } }, summary:toKeyValuePairs())
    end)

    it("lists downloaded books by file name", function()
        local summary = GrimmorySyncSummary:new()

        summary:record({ state = "book-downloaded", book_path = "/books/Dune - Frank Herbert.epub" })

        assert.is_true(summary:hasDetails())
        assert.are.same({
            { "Books downloaded", "1" },
            { "  Dune - Frank Herbert", "" },
        }, summary:toKeyValuePairs())
    end)

    it("shows progress changes in both directions", function()
        local summary = GrimmorySyncSummary:new()

        summary:record({
            state = "progress-pushed",
            book_path = "/books/a.epub",
            from_progress = 12.4,
            to_progress = 45,
        })
        summary:record({ state = "progress-pushed", book_path = "/books/b.epub", to_progress = 8 })
        summary:record({ state = "progress-pulled", book_path = "/books/c.epub", from_progress = 30, to_progress = 62 })

        assert.are.same({
            { "Progress sent to Grimmory", "2" },
            { "  a", "12% → 45%" },
            { "  b", "8%", separator = true },
            { "Progress received from Grimmory", "1" },
            { "  c", "30% → 62%" },
        }, summary:toKeyValuePairs())
    end)

    it("explains progress that was left unchanged", function()
        local summary = GrimmorySyncSummary:new()

        summary:record(kept_progress_message)

        assert.are.same({
            { "Progress left unchanged (would move back)", "1" },
            { "  a", "device 100%, Grimmory 34%" },
        }, summary:toKeyValuePairs())
    end)

    it("lists a book once when push and pull both leave it unchanged", function()
        local summary = GrimmorySyncSummary:new()
        summary:record(kept_progress_message)
        summary:record(kept_progress_message)

        assert.are.equal(1, #summary.kept_progress)
    end)

    it("does not count unchanged progress alone as worth a summary screen", function()
        local summary = GrimmorySyncSummary:new()

        summary:record(kept_progress_message)

        assert.is_false(summary:hasDetails())
    end)

    it("announces newer progress for the open book", function()
        local summary = GrimmorySyncSummary:new()

        summary:record({
            state = "progress-available",
            book_path = "/books/a.epub",
            from_progress = 30,
            to_progress = 62,
        })
        summary:record({ state = "book-pull-metadata", book_path = "/books/a.epub" })

        assert.are.same({
            { "Newer progress for the open book", "1" },
            { "  a", "30% → 62%", separator = true },
            { "Books already up to date", "1" },
        }, summary:toKeyValuePairs())
    end)

    it("reports failures with the session message key", function()
        local summary = GrimmorySyncSummary:new()

        summary:record({ state = "session-error", bookPath = "/books/a.epub" })
        summary:record({ state = "book-error", book_id = 7, message = "timeout" })

        assert.are.same({
            { "Books failed", "1" },
            { "  Book 7", "timeout", separator = true },
            { "Sessions failed", "1" },
            { "  a", "" },
        }, summary:toKeyValuePairs())
    end)

    it("reports books whose annotations failed", function()
        local summary = GrimmorySyncSummary:new()

        summary:record({ state = "annotations-failed", book_path = "/books/a.epub" })

        assert.is_true(summary:hasDetails())
        assert.are.same({
            { "Annotations failed", "1" },
            { "  a", "" },
        }, summary:toKeyValuePairs())
    end)
end)
