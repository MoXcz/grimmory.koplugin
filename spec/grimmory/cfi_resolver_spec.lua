local assert = require 'luassert'
local spy = require 'luassert.spy'
local stub = require 'luassert.stub'

package.path = "grimmory.koplugin/?.lua;" .. package.path

local fake_logger = {
    err = spy.new(function() end),
    info = spy.new(function() end),
    dbg = spy.new(function() end),
}

package.preload["grimmory/logger"] = function()
    return {
        new = function()
            return fake_logger
        end
    }
end

local fake_cache = {}

package.preload["cache"] = function()
    return {
        new = function()
            return {
                get = function(_, key)
                    return fake_cache[tostring(key)]
                end,
                insert = function(_, key, value)
                    fake_cache[tostring(key)] = value
                end
            }
        end,
    }
end

local fake_document = stub.new()

local GrimmoryCFIResolver = require("grimmory/cfi_resolver")

local EXAMPLE_HTML = [[CDATA
<html>
    <head>
    </head>
    <body>
        <div id="chapter2">
            <h1>Chapter 2</h1>
            <p>Content of chapter <code>two</code>.</p>
            <p>
                Second paragraph
                with
                <bold>more</bold> text.
            </p>
            <p class="foo"><span class="foo">
                <img />
                </span>Third <span>paragraph with</span> <bold>lots</bold> of <span>inline</span> elements.
            </p>
        </div>
    </body>
</html>
]]

describe("GrimmoryCFIResolver", function()
    before_each(function()
        fake_document.loadDocument = spy.new(function() return true end)
        fake_document.getNormalizedXPointer = spy.new(function(_, xp) return xp end)
        fake_document.getHTMLFromXPointer = spy.new(function() return "<DocFragment Source=\"example.html\">" end)
        fake_document.getDocumentFileContent = spy.new(function() return EXAMPLE_HTML end)
        fake_document.close = spy.new(function() end)

        for key in pairs(fake_cache) do
            fake_cache[key] = nil
        end
    end)

    describe("cfiToXpointer", function()
        it("handles self-ending tag", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
            <html>
                <head>
                </head>
                <body>
                    <h1>Chapter 2</h1>
                    <span self="ending" tag />
                    <p>Content of chapter <code>two</code>.</p>
                </body>
            </html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:cfiToXpointer(
                "epubcfi(/6/24!/4/6)"
            )

            assert.are.equal(
                "/body/DocFragment[12]/body/p",
                actual
            )
        end)

        it("prevents entering self-ending tag", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
            <html>
                <head>
                </head>
                <body>
                    <h1>Chapter 2</h1>
                    <span self="ending" tag />
                    <p>Content of chapter <code>two</code>.</p>
                </body>
            </html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.are.has_error(
                function()
                    cfi_resolver:cfiToXpointer("epubcfi(/6/24!/4/4/2)")
                end,
                "impossible CFI for document: attempting to get children of void"
            )
        end)

        it("converts simple xpointer", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:cfiToXpointer(
                "epubcfi(/6/24!/4/2/4)"
            )

            assert.are.equal(
                "/body/DocFragment[12]/body/div/p",
                actual
            )
        end)

        it("converts xpointer referencing second occurrence", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:cfiToXpointer(
                "epubcfi(/6/24!/4/2/6)"
            )

            assert.are.equal(
                "/body/DocFragment[12]/body/div/p[2]",
                actual
            )
        end)

        it("converts xpointer referencing text", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:cfiToXpointer(
                "epubcfi(/6/24!/4/2/4/1:3)"
            )

            assert.are.equal(
                "/body/DocFragment[12]/body/div/p/text().3",
                actual
            )
        end)

        it("converts xpointer mapping text offsets", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:cfiToXpointer(
                "epubcfi(/6/24!/4/2/6/1:19)"
            )

            assert.are.equal(
                "/body/DocFragment[12]/body/div/p[2]/text().3",
                actual
            )
        end)

        it("converts xpointer referencing text in between elements", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:cfiToXpointer(
                "epubcfi(/6/24!/4/2/6/3:3)"
            )

            assert.are.equal(
            "/body/DocFragment[12]/body/div/p[2]/text()[2].3",
                actual
            )
        end)

        it("converts to xpointer referencing a target with no spaces between nodes", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:cfiToXpointer(
                "epubcfi(/6/24!/4/2/8/4/1:1)"
            )

            assert.are.equal(
            "/body/DocFragment[12]/body/div/p[3]/span[2]/text().1",
                actual
            )
        end)

        it("skips empty text nodes when indexing text()", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
<html><head></head><body><div><p><span epub:type="pagebreak"/>first real<span/>second real</p></div></body></html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:cfiToXpointer(
                "epubcfi(/6/24!/4/2/2/5)"
            )

            assert.are.equal(
                "/body/DocFragment[12]/body/div/p/text()[2]",
                actual
            )
        end)

        it("indexes the only non-empty text node as the first", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
<html><head></head><body><div><p><span epub:type="pagebreak"/><span/>only real</p></div></body></html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:cfiToXpointer(
                "epubcfi(/6/24!/4/2/2/5)"
            )

            assert.are.equal(
                "/body/DocFragment[12]/body/div/p/text()",
                actual
            )
        end)
    end)

    describe("xpointerToCFI", function()
        it("converts simple xpointer", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:xpointerToCFI(
                "/body/DocFragment[12]/body/div/p"
            )

            assert.are.equal(
                "epubcfi(/6/24!/4/2/4)",
                actual
            )
        end)

        it("converts xpointer referencing second occurrence", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:xpointerToCFI(
                "/body/DocFragment[12]/body/div/p[2]"
            )

            assert.are.equal(
                "epubcfi(/6/24!/4/2/6)",
                actual
            )
        end)

        it("converts xpointer referencing text", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:xpointerToCFI(
                "/body/DocFragment[12]/body/div/p/text().3"
            )

            assert.are.equal(
                "epubcfi(/6/24!/4/2/4/1:3)",
                actual
            )
        end)

        it("converts xpointer mapping text offsets", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:xpointerToCFI(
                "/body/DocFragment[12]/body/div/p[2]/text().3"
            )

            assert.are.equal(
                "epubcfi(/6/24!/4/2/6/1:19)",
                actual
            )
        end)

        it("converts xpointer referencing text in between elements", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:xpointerToCFI(
                "/body/DocFragment[12]/body/div/p[2]/text()[2].3"
            )

            assert.are.equal(
                "epubcfi(/6/24!/4/2/6/3:3)",
                actual
            )
        end)

        it("converts xpointer referencing a target with no spaces between nodes", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:xpointerToCFI(
                "/body/DocFragment[12]/body/div/p[3]/span[2]/text().1"
            )

            assert.are.equal(
                "epubcfi(/6/24!/4/2/8/4/1:1)",
                actual
            )
        end)

        it("converts text that follows a leading inline element", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
<html><head></head><body><p><i>Italic</i> rest of text</p></body></html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.are.equal(
                "epubcfi(/6/24!/4/2/3:3)",
                cfi_resolver:xpointerToCFI("/body/DocFragment[12]/body/p/text().3")
            )
            assert.are.equal(
                "/body/DocFragment[12]/body/p/text().3",
                cfi_resolver:cfiToXpointer("epubcfi(/6/24!/4/2/3:3)")
            )
        end)

        it("skips empty text nodes when indexing text()", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
<html><head></head><body><div><p><span epub:type="pagebreak"/>first real<span/>second real</p></div></body></html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.are.equal(
                "epubcfi(/6/24!/4/2/2/5:2)",
                cfi_resolver:xpointerToCFI("/body/DocFragment[12]/body/div/p/text()[2].2")
            )
        end)

        it("fails for a text node the chapter does not have", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.has_error(function()
                cfi_resolver:xpointerToCFI("/body/DocFragment[12]/body/div/p/text()[9].1")
            end, "Unable to find XPointer text in document")
        end)

        it("skips the whitespace crengine drops around indented markup", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
<html><head></head><body>
<div>
    <p>
        <i>Leading</i> after italic <b>bold</b> <i>italic</i> tail
    </p>
</div>
</body></html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            for _, case in ipairs({
                { xpointer = "/body/DocFragment[12]/body/div/p/text().3", cfi = "epubcfi(/6/24!/4/2/2/3:3)" },
                { xpointer = "/body/DocFragment[12]/body/div/p/text()[3].2", cfi = "epubcfi(/6/24!/4/2/2/7:2)" },
            }) do
                assert.are.equal(case.cfi, cfi_resolver:xpointerToCFI(case.xpointer))
                assert.are.equal(case.xpointer, cfi_resolver:cfiToXpointer(case.cfi))
            end
        end)

        it("keeps whitespace inside preformatted text", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
<html><head></head><body><pre>
  <i>a</i> mid <b>b</b> after</pre></body></html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.are.equal(
                "epubcfi(/6/24!/4/2/3:1)",
                cfi_resolver:xpointerToCFI("/body/DocFragment[12]/body/pre/text()[2].1")
            )
        end)

        it("drops the whitespace on either side of a block sibling", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
<html><head></head><body><div><i>a</i> <p>x</p> <i>d</i> tail</div></body></html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.are.equal(
                "epubcfi(/6/24!/4/2/7:2)",
                cfi_resolver:xpointerToCFI("/body/DocFragment[12]/body/div/text().2")
            )
            assert.are.equal(
                "/body/DocFragment[12]/body/div/text().2",
                cfi_resolver:cfiToXpointer("epubcfi(/6/24!/4/2/7:2)")
            )
        end)

        it("keeps whitespace after text that a comment splits off", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
<html><head></head><body><p>head<!-- c -->
<i>bb</i> tail <b>z</b> more</p></body></html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.are.equal(
                "epubcfi(/6/24!/4/2/3:1)",
                cfi_resolver:xpointerToCFI("/body/DocFragment[12]/body/p/text()[3].1")
            )
            assert.are.equal(
                "/body/DocFragment[12]/body/p/text()[3].1",
                cfi_resolver:cfiToXpointer("epubcfi(/6/24!/4/2/3:1)")
            )
        end)

        it("keeps leading whitespace inside an inline element", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
<html><head></head><body><p><span> <b>x</b> y <i>z</i> w</span> tail</p></body></html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.are.equal(
                "epubcfi(/6/24!/4/2/2/3:1)",
                cfi_resolver:xpointerToCFI("/body/DocFragment[12]/body/p/span/text()[2].1")
            )
        end)

        it("counts a comment-split chunk in characters, not bytes", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
<html><head></head><body><p>café AT&amp;T<!-- c -->Q tail</p></body></html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.are.equal(
                "epubcfi(/6/24!/4/2/1:11)",
                cfi_resolver:xpointerToCFI("/body/DocFragment[12]/body/p/text()[2].2")
            )
            assert.are.equal(
                "/body/DocFragment[12]/body/p/text()[2].2",
                cfi_resolver:cfiToXpointer("epubcfi(/6/24!/4/2/1:11)")
            )
        end)

        it("counts character references, astral characters and CRLF as the parsed text has them", function()
            local emoji = string.char(0xF0, 0x9F, 0x98, 0x80)

            -- Built in a normal string: a long string would turn the CRLF into a lone newline.
            fake_document.getDocumentFileContent = spy.new(function()
                return "<html><head></head><body><p>a&#8217;b&#x2019;" .. emoji
                    .. "\r\n<!-- c -->Q tail</p></body></html>"
            end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.are.equal(
                "epubcfi(/6/24!/4/2/1:7)",
                cfi_resolver:xpointerToCFI("/body/DocFragment[12]/body/p/text()[2].0")
            )
            assert.are.equal(
                "/body/DocFragment[12]/body/p/text()[2].0",
                cfi_resolver:cfiToXpointer("epubcfi(/6/24!/4/2/1:7)")
            )
        end)

        it("keeps a CFI offset past the end of the text at its end", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
<html><head></head><body><div>&amp;</div></body></html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.are.equal(
                "/body/DocFragment[12]/body/div/text().1",
                cfi_resolver:cfiToXpointer("epubcfi(/6/24!/4/2/1:35)")
            )
        end)

        it("fails for a CFI step that is not a number", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.has_error(function()
                cfi_resolver:cfiToXpointer("epubcfi(/6/24!/4/x/2)")
            end, "could not translate from local path to xpointer")
        end)

        it("skips an XML declaration and comments between elements", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html><head></head><body><p>First</p><!-- note --><p>Second paragraph</p></body></html>]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.are.equal(
                "epubcfi(/6/24!/4/4/1:3)",
                cfi_resolver:xpointerToCFI("/body/DocFragment[12]/body/p[2]/text().3")
            )
            assert.are.equal(
                "/body/DocFragment[12]/body/p[2]/text().3",
                cfi_resolver:cfiToXpointer("epubcfi(/6/24!/4/4/1:3)")
            )
        end)

        it("keeps the whitespace after an inline element at the end of a paragraph", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
<html><head></head><body><p>text <i>x</i> </p></body></html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.are.equal(
                "epubcfi(/6/24!/4/2/3:1)",
                cfi_resolver:xpointerToCFI("/body/DocFragment[12]/body/p/text()[2].1")
            )
            assert.are.equal(
                "/body/DocFragment[12]/body/p/text()[2].1",
                cfi_resolver:cfiToXpointer("epubcfi(/6/24!/4/2/3:1)")
            )
        end)

        it("fails for whitespace crengine drops at the end of a block that holds blocks", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
<html><head></head><body><div><p>one</p><i>a</i> b<i>c</i>
</div></body></html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.has_error(function()
                cfi_resolver:cfiToXpointer("epubcfi(/6/24!/4/2/7:0)")
            end, "could not translate from local path to xpointer")
        end)

        it("counts text split by a comment as one chunk", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
<html><head></head><body><p><i>aa</i>
<!-- note -->tail text</p><p>head<!-- note --> <i>bb</i> tail</p></body></html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            for _, case in ipairs({
                { xpointer = "/body/DocFragment[12]/body/p/text()[2].2", cfi = "epubcfi(/6/24!/4/2/3:3)" },
                { xpointer = "/body/DocFragment[12]/body/p[2]/i/text().1", cfi = "epubcfi(/6/24!/4/4/2/1:1)" },
            }) do
                assert.are.equal(case.cfi, cfi_resolver:xpointerToCFI(case.xpointer))
                assert.are.equal(case.xpointer, cfi_resolver:cfiToXpointer(case.cfi))
            end
        end)

        it("keeps all whitespace when crengine has more text than its default styles leave", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
<html><head></head><body><div class="code">
<span>kw</span> rest
</div></body></html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.are.equal(
                "epubcfi(/6/24!/4/2/3:1)",
                cfi_resolver:xpointerToCFI("/body/DocFragment[12]/body/div/text()[2].1")
            )
        end)

        it("fails for a CFI at whitespace crengine drops", function()
            fake_document.getDocumentFileContent = spy.new(function() return [[CDATA
<html><head></head><body><div>
<p>x</p></div></body></html>
            ]] end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            assert.has_error(function()
                cfi_resolver:cfiToXpointer("epubcfi(/6/24!/4/2/1:0)")
            end, "could not translate from local path to xpointer")
        end)

        it("converts a position late in a long chapter", function()
            local paragraphs = {}
            for index = 1, 1200 do
                table.insert(paragraphs, "<p>Paragraph " .. index .. " with <i>some</i> text.</p>")
            end

            fake_document.getDocumentFileContent = spy.new(function()
                return "<html><head></head><body>" .. table.concat(paragraphs, "\n") .. "</body></html>"
            end)

            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:xpointerToCFI(
                "/body/DocFragment[12]/body/p[1100]/text().5"
            )

            assert.are.equal(
                "epubcfi(/6/24!/4/2200/1:5)",
                actual
            )
        end)
    end)

    describe("cfiRangeToXPointers", function()
        it("handles start and end within text blocks", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual_start, actual_end = cfi_resolver:cfiRangeToXPointers(
                "epubcfi(/6/24!/4/2/6,/3:3,/3:5)"
            )

            assert.are.equal("/body/DocFragment[12]/body/div/p[2]/text()[2].3", actual_start)
            assert.are.equal("/body/DocFragment[12]/body/div/p[2]/text()[2].5", actual_end)
        end)
    end)

    describe("xpointerRangeToCFI", function()
        it("supports ranges between two block nodes", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:xpointerRangeToCFI(
                "/body/DocFragment[12]/body/div/p",
                "/body/DocFragment[12]/body/div/p[2]"
            )

            assert.are.equal(
                "epubcfi(/6/24!/4/2,/4,/6)",
                actual
            )
        end)

        it("supports ranges between block and inline", function()
            local cfi_resolver = GrimmoryCFIResolver:new(fake_document)

            local actual = cfi_resolver:xpointerRangeToCFI(
                "/body/DocFragment[12]/body/div/p/text()[1].2",
                "/body/DocFragment[12]/body/div/p/code[1]/text().2"
            )

            assert.are.equal(
                "epubcfi(/6/24!/4/2/4,/1:2,/2/1:2)",
                actual
            )
        end)
    end)
end)
