local assert = require 'luassert'
local match = require 'luassert.match'
local spy = require 'luassert.spy'
local stub = require 'luassert.stub'

package.path = "grimmory.koplugin/?.lua;" .. package.path


local fake_document = stub.new()
local opened_document = fake_document

package.preload["grimmory/logger"] = function()
    local quiet = function() end

    return {
        new = function()
            return { err = quiet, warn = quiet, info = quiet, dbg = quiet }
        end
    }
end

package.preload["document/documentregistry"] = function()
    return {
        hasProvider = function() return true end,
        openDocument = function() return opened_document end,
    }
end

local fake_cfi_resolver = stub.new()
local mock_cfi_resolver_new = spy.new(function() return fake_cfi_resolver end)

package.preload["grimmory/cfi_resolver"] = function()
    return {
        new = mock_cfi_resolver_new,
    }
end

local fake_doc_metadata = stub.new()

local GrimmoryReadingAnnotations = require("grimmory/reading/annotations")


local remote_grimmory_annotation = {
    ["id"] = 27,
    ["chapter"] = "Logical Reading Order",
    ["color"] = "",
    ["created_at"] = 1781321340,
    ["style"] = "highlight",
    ["page"] = "start",
    ["pos0"] = "start",
    ["pos1"] = "end",
    ["text"] = "Although you’ll hear that all EPUB 3s have a default reading order",
}

local local_grimmory_annotation = {
    ["chapter"] = "Logical Reading Order",
    ["color"] = "yellow",
    ["datetime"] = os.date("%Y-%m-%d %H:%M:%S", remote_grimmory_annotation.created_at),
    ["drawer"] = "lighten",
    ["grimmory_id"] = 27,
    ["page"] = "start",
    ["pos0"] = "start",
    ["pos1"] = "end",
    ["text"] = "Although you’ll hear that all EPUB 3s have a default reading order",
}

local local_annotation = {
    ["chapter"] = "Lists",
    ["color"] = "yellow",
    ["datetime"] = "2026-06-13 03:20:33Z",
    ["drawer"] = "lighten",
    ["page"] = "/body/DocFragment[12]/body/section/section/section[8]/p[3]/text()",
    ["pageno"] = 44,
    ["pos0"] = "/body/DocFragment[12]/body/section/section/section[8]/p[3]/text()",
    ["pos1"] = "/body/DocFragment[12]/body/section/section/section[8]/p[3]/text().163",
    ["text"] = "element, on the other hand, provides the ability both to move quickly " ..
                "from item to item and to escape the list entirely. It also allows a " ..
                "reading system to",
}


describe("GrimmoryReadingAnnotations", function()
    before_each(function()
        opened_document = fake_document
        fake_document.loadDocument = spy.new(function() return true end)
        fake_document.close = spy.new(function() end)

        fake_cfi_resolver.cfiRangeToXPointers = spy.new(function() return "start", "end" end)
        fake_cfi_resolver.xpointerRangeToCFI = spy.new(function() return "cfi" end)

        stub(fake_doc_metadata, "getAnnotations").returns({})
        stub(fake_doc_metadata, "setAnnotations")
        stub(fake_doc_metadata, "getModifiedGrimmoryAnnotations").returns({})
    end)

    describe("mergeAnnotations", function()
        it("removes missing grimmory annotations", function()
            local expected = {}

            fake_doc_metadata.getAnnotations.returns({
                local_grimmory_annotation,
            })

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            annotations:applyAnnotations("book_path", {})

            assert.spy(fake_doc_metadata.setAnnotations).was_called_with(
                match._,
                match.same("book_path"),
                match.same(expected)
            )
        end)

        it("retains non-grimmory annotations", function()
            local expected = { local_annotation }
            fake_doc_metadata.getAnnotations.returns({ local_annotation })

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            annotations:applyAnnotations("book_path", {})

            assert.spy(fake_doc_metadata.setAnnotations).was_called_with(
                match._,
                match.same("book_path"),
                match.same(expected)
            )
        end)

        it("appends grimmory annotations", function()
            local expected = {
                local_annotation,
                local_grimmory_annotation,
            }
            fake_doc_metadata.getAnnotations.returns({ local_annotation })

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            annotations:applyAnnotations("book_path", {
                remote_grimmory_annotation
            })

            assert.spy(fake_doc_metadata.setAnnotations).was_called_with(
                fake_doc_metadata,
                "book_path",
                expected
            )
        end)

        it("keeps a pending edit instead of taking Grimmory's version", function()
            local edited = {
                grimmory_id = 27,
                note = "edited on this device",
                page = "start",
                pos0 = "start",
                pos1 = "end",
            }
            fake_doc_metadata.getAnnotations.returns({ edited })
            fake_doc_metadata.getModifiedGrimmoryAnnotations.returns({ 27 })

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            annotations:applyAnnotations("book_path", { remote_grimmory_annotation })

            assert.spy(fake_doc_metadata.setAnnotations).was_called_with(
                match._,
                match.same("book_path"),
                match.same({
                    {
                        grimmory_id = 27,
                        note = "edited on this device",
                        page = "start",
                        pos0 = "start",
                        pos1 = "end",
                    },
                })
            )
        end)

        it("does not bring back an annotation whose removal is still pending", function()
            fake_doc_metadata.getModifiedGrimmoryAnnotations.returns({ 27 })

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            annotations:applyAnnotations("book_path", { remote_grimmory_annotation })

            assert.spy(fake_doc_metadata.setAnnotations).was_called_with(
                match._,
                match.same("book_path"),
                match.same({})
            )
        end)

        it("takes Grimmory's style and note but keeps the local position", function()
            local linked = { grimmory_id = 27, page = "start", pos0 = "start", pos1 = "end", note = "old" }
            fake_doc_metadata.getAnnotations.returns({ linked })
            fake_cfi_resolver.cfiRangeToXPointers = spy.new(function() return "moved", "elsewhere" end)

            local remote = {
                id = 27,
                cfi = "cfi",
                color = "#4ADE80",
                style = "underline",
                note = "new",
            }

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            annotations:applyAnnotations("book_path", { remote })

            assert.spy(fake_doc_metadata.setAnnotations).was_called_with(
                match._,
                match.same("book_path"),
                match.same({
                    {
                        grimmory_id = 27,
                        page = "start",
                        pos0 = "start",
                        pos1 = "end",
                        note = "new",
                        color = "green",
                        drawer = "underscore",
                    },
                })
            )
        end)

        it("keeps a pending local annotation whose Grimmory copy is gone", function()
            fake_doc_metadata.getAnnotations.returns({ local_grimmory_annotation })
            fake_doc_metadata.getModifiedGrimmoryAnnotations.returns({ 27 })

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            annotations:applyAnnotations("book_path", {})

            assert.spy(fake_doc_metadata.setAnnotations).was_called_with(
                match._,
                match.same("book_path"),
                match.same({ local_grimmory_annotation })
            )
        end)

        it("gives an annotation with an empty Grimmory note no note", function()
            local remote = { id = 31, cfi = "cfi", note = "" }

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            annotations:applyAnnotations("book_path", { remote })

            local saved = fake_doc_metadata.setAnnotations.calls[1].vals[3]
            assert.is_nil(saved[1].note)
        end)

        it("skips Grimmory annotations at held back CFIs but keeps the local ones linked to them", function()
            fake_doc_metadata.getAnnotations.returns({
                { grimmory_id = 31, pos0 = "start", pos1 = "end", color = "yellow", drawer = "lighten" },
            })

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            annotations:applyAnnotations("book_path", {
                { id = 31, cfi = "cfi-a", style = "underline", created_at = 1781321340 },
                { id = 32, cfi = "cfi-b", style = "underline", created_at = 1781321340 },
            }, { ["cfi-a"] = true, ["cfi-b"] = true })

            assert.spy(fake_doc_metadata.setAnnotations).was_called_with(
                match._,
                match.same("book_path"),
                match.same({ { grimmory_id = 31, pos0 = "start", pos1 = "end", color = "yellow", drawer = "lighten" } })
            )
        end)

        it("leaves annotations untouched when the book cannot be opened", function()
            opened_document = nil
            fake_doc_metadata.getAnnotations.returns({ local_grimmory_annotation })

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            assert.is_false(annotations:applyAnnotations("book_path", {}))
            assert.stub(fake_doc_metadata.setAnnotations).was_not_called()
        end)

        it("closes the book when it fails to load", function()
            fake_document.loadDocument = spy.new(function() return false end)

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            assert.is_false(annotations:applyAnnotations("book_path", { remote_grimmory_annotation }))
            assert.spy(fake_document.close).was_called()
            assert.stub(fake_doc_metadata.setAnnotations).was_not_called()
        end)
    end)

    describe("getAnnotations", function()
        it("translates colors and styles for local annotations", function()
            fake_doc_metadata.getAnnotations.returns({ local_annotation })

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            local ok, actual = annotations:getAnnotations("book_path")

            assert.is_true(ok)
            assert.equal(1, #actual)
            assert.equal("#FFC107", actual[1].color)
            assert.equal("highlight", actual[1].style)
            assert.equal(1, actual[1].local_index)
        end)

        it("returns nothing when the book cannot be opened", function()
            opened_document = nil
            fake_doc_metadata.getAnnotations.returns({ local_annotation })

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            assert.is_false((annotations:getAnnotations("book_path")))
        end)
    end)

    describe("setGrimmoryIds", function()
        it("stores IDs on the annotations at the given positions", function()
            local first = { pos0 = "a", pos1 = "b" }
            local second = { pos0 = "c", pos1 = "d", grimmory_id = 3 }
            local third = { pos0 = "e", pos1 = "f" }
            fake_doc_metadata.getAnnotations.returns({ first, second, third })

            local annotations = GrimmoryReadingAnnotations:new(fake_doc_metadata)

            annotations:setGrimmoryIds("book_path", {
                { index = 1, grimmory_id = 41 },
                { index = 3, grimmory_id = 42 },
            })

            assert.spy(fake_doc_metadata.setAnnotations).was_called_with(
                match._,
                match.same("book_path"),
                match.same({
                    { pos0 = "a", pos1 = "b", grimmory_id = 41 },
                    { pos0 = "c", pos1 = "d", grimmory_id = 3 },
                    { pos0 = "e", pos1 = "f", grimmory_id = 42 },
                })
            )
        end)
    end)
end)
