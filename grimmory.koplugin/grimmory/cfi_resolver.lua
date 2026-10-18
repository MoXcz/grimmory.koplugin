local Cache = require("cache")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

-- Guards against runaway input; long chapters easily pass a few thousand tokens.
local DEFAULT_TOKEN_LIMIT = 100000

local HTML_VOID_ELEMENT_TAGS = {
    area=true,
    base=true,
    br=true,
    col=true,
    embed=true,
    hr=true,
    img=true,
    input=true,
    link=true,
    meta=true,
    param=true,
    source=true,
    track=true,
    wbr=true,
}

-- crengine's default block elements (fb2def.h); stylesheets that change display are not taken into account.
local HTML_BLOCK_ELEMENT_TAGS = {
    address = true, article = true, aside = true, blockquote = true, body = true, caption = true,
    center = true, col = true, colgroup = true, dd = true, dialog = true, dir = true, div = true,
    dl = true, dt = true, fieldset = true, figcaption = true, figure = true, footer = true, form = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true, header = true, hgroup = true,
    hr = true, html = true, legend = true, li = true, listing = true, main = true, menu = true,
    nav = true, ol = true, p = true, plaintext = true, pre = true, search = true, section = true,
    table = true, tbody = true, td = true, tfoot = true, th = true, thead = true, tr = true, ul = true,
    xmp = true,
}

local HTML_PREFORMATTED_TAGS = {
    listing = true,
    plaintext = true,
    pre = true,
    xmp = true,
}

-- Stands for a text node among the siblings crengine looks at.
local TEXT_SIBLING = "#text"

---crengine drops whitespace-only text in a block at its start and next to a block sibling, and at its end when the
---block also holds blocks.
---@param parent_tag string
---@param previous_sibling string | nil the closest node crengine kept before the text: a tag, TEXT_SIBLING or nil
---@param next_sibling string | nil the node right after the text: a tag or TEXT_SIBLING, nil when the text comes last
---@param has_block_child boolean
---@return boolean
local function is_dropped_whitespace(parent_tag, previous_sibling, next_sibling, has_block_child)
    if not HTML_BLOCK_ELEMENT_TAGS[parent_tag] or HTML_PREFORMATTED_TAGS[parent_tag] then
        return false
    end

    if previous_sibling == nil or HTML_BLOCK_ELEMENT_TAGS[previous_sibling] then
        return true
    end

    if next_sibling == nil then
        return has_block_child
    end

    return HTML_BLOCK_ELEMENT_TAGS[next_sibling] == true
end

---@param html string
---@return function token_iterator
local function tokenize_html(html, token_limit)
    if token_limit == nil then
        token_limit = DEFAULT_TOKEN_LIMIT
    end

    local pos = 0

    -- Flag to ensure text always is generated between nodes
    -- for proper counters.  The DOM must be tag -> text -> tag -> text,
    -- always or the counts get incorrect.
    local has_seen_text = false

    return function ()
        while html ~= nil and pos < #html do
            token_limit = token_limit - 1

            if token_limit <= 0 then
                error("Too many tokens")
            end

            -- Comments and processing instructions also start with "<"; the prefix checks below sort them out.
            local start = html:find("<", pos, true)
            if not start then
                local text = html:sub(pos)
                pos = #html

                return {
                    type = "text",
                    text = text,
                    raw = text,
                }
            end

            if not has_seen_text or start ~= pos then
                local text = html:sub(pos, start - 1)

                pos = start
                has_seen_text = true

                return {
                    type = "text",
                    text = text,
                    raw = text,
                }
            end

            local _, stop

            local is_ignored = false

            if html:sub(start, start + 3) == "<!--" then
                _,stop = html:find("-->", start, true)
                is_ignored = true
            elseif html:sub(start, start + 1) == "<?" then
                _,stop = html:find("?>", start, true)
                is_ignored = true
            else
                _,stop = html:find("%b<>", start)
            end

            if not stop then
                pos = start + 1

                local text = html:sub(start, start)

                return {
                    type = "text",
                    text = text,
                    raw = text,
                }
            elseif is_ignored then
                pos = stop + 1
            else
                pos = stop + 1

                has_seen_text = false

                local found_tag = html:sub(start, stop)
                local found_end_tag, found_tag_name = found_tag:match("^<(/?)([^/%s>]+)")

                if found_tag_name then
                    found_tag_name = found_tag_name:lower()

                    local is_void = false

                    if HTML_VOID_ELEMENT_TAGS[found_tag_name] then
                        is_void = true
                    end

                    if found_tag:match("/>%s*") then
                        is_void = true
                    end

                    if found_end_tag == "/" then
                        return {type="end-tag", text=found_tag_name, is_void=is_void, raw=found_tag}
                    else
                        return {type="tag", text=found_tag_name, is_void=is_void, raw=found_tag}
                    end
                end
            end
        end

        return nil
    end
end

---@param tokens function
---@param callback function
local function walk_tree(tokens, callback)
    -- If we we leave the fragment path we have a problem and should bail.
    local depth = 0

    -- Search among the siblings
    for token in tokens do
        if depth == 0 and not callback(depth, token) then
            return true
        end

        if token.type == "tag" and not token.is_void then
            depth = depth + 1
        elseif token.type == "end-tag" and not token.is_void then
            depth = depth - 1
        end

        if depth < 0 then
            return false
        end
    end

    return true
end

---Length in UTF-16 units of the text that raw markup stands for, which is what a CFI offset counts.
---@param raw string
---@return integer
local function utf16_length(raw)
    local units = 0

    raw = raw:gsub("\r\n?", "\n")

    raw = raw:gsub("&#(%d+);", function(code)
        units = units + (tonumber(code) > 0xFFFF and 2 or 1)
        return ""
    end)
    raw = raw:gsub("&#[xX](%x+);", function(code)
        units = units + (tonumber(code, 16) > 0xFFFF and 2 or 1)
        return ""
    end)
    raw = raw:gsub("&%w+;", function()
        units = units + 1
        return ""
    end)

    local _, code_points = raw:gsub("[^\128-\191]", "")
    local _, astral = raw:gsub("[\240-\247]", "")

    return units + code_points + astral
end

---Visits the children of the element the tokens are in, saying for each text whether crengine keeps it.
---@param tokens function
---@param parent_tag string
---@param keeps_whitespace boolean keeps all whitespace-only text, as a stylesheet with `white-space: pre` does
---@param visit fun(node_index: integer, token: table, is_kept_text: boolean, chunk_offset: integer): boolean
local function walk_children(tokens, parent_tag, keeps_whitespace, visit)
    local node_index = 0
    local previous_sibling = nil
    local has_block_child = false
    -- A comment splits text into several crengine nodes, but a CFI counts it as one chunk.
    local is_in_chunk = false
    local chunk_length = 0
    local last_piece = ""
    -- Whitespace-only text waits for the next sibling to know whether crengine keeps it.
    local pending_whitespace = nil
    local is_stopped = false

    local function settle_whitespace(next_sibling)
        local whitespace = pending_whitespace
        pending_whitespace = nil

        local is_kept = keeps_whitespace or not is_dropped_whitespace(
            parent_tag,
            whitespace.previous_sibling,
            next_sibling,
            has_block_child
        )

        if is_kept then
            previous_sibling = TEXT_SIBLING
        end

        is_stopped = not visit(whitespace.node_index, whitespace.token, is_kept, whitespace.chunk_offset)
        return not is_stopped
    end

    walk_tree(tokens, function(_, token)
        if token.type == "text" then
            if not is_in_chunk then
                node_index = node_index + 1
                is_in_chunk = true
                chunk_length = 0
                last_piece = ""
            end

            -- Only a chunk that a comment splits has earlier pieces to measure.
            if last_piece ~= "" then
                chunk_length = chunk_length + utf16_length(last_piece)
            end

            last_piece = token.text

            local chunk_offset = chunk_length

            -- Empty text is only a CFI slot between two elements; crengine has no node for it.
            if token.text == "" then
                is_stopped = not visit(node_index, token, false, chunk_offset)
                return not is_stopped
            end

            if pending_whitespace ~= nil and not settle_whitespace(TEXT_SIBLING) then
                return false
            end

            if token.text:match("^%s+$") then
                pending_whitespace = {
                    node_index = node_index,
                    token = token,
                    previous_sibling = previous_sibling,
                    chunk_offset = chunk_offset,
                }
                return true
            end

            previous_sibling = TEXT_SIBLING
            is_stopped = not visit(node_index, token, true, chunk_offset)
            return not is_stopped
        end

        is_in_chunk = false

        local next_sibling = token.type == "tag" and token.text or nil

        if pending_whitespace ~= nil and not settle_whitespace(next_sibling) then
            return false
        end

        if token.type == "tag" then
            node_index = node_index + 1
            previous_sibling = token.text
            has_block_child = has_block_child or HTML_BLOCK_ELEMENT_TAGS[token.text] == true

            is_stopped = not visit(node_index, token, false, 0)
            return not is_stopped
        end

        return true
    end)

    if pending_whitespace ~= nil and not is_stopped then
        settle_whitespace(nil)
    end
end

---@param tokens function
---@param parent_tag string
---@param text_index integer crengine's text() index among the parent's children
---@param keeps_whitespace boolean
---@return boolean ok
---@return integer node_index the CFI step of the text's chunk
---@return string text
---@return integer chunk_offset where the text starts in its chunk
local function find_text_child(tokens, parent_tag, text_index, keeps_whitespace)
    local text_counter = 0
    local found_node_index, found_text, found_chunk_offset

    walk_children(tokens, parent_tag, keeps_whitespace, function(node_index, token, is_kept_text, chunk_offset)
        if not is_kept_text then
            return true
        end

        text_counter = text_counter + 1

        if text_counter ~= text_index then
            return true
        end

        found_node_index, found_text, found_chunk_offset = node_index, token.text, chunk_offset
        return false
    end)

    if found_node_index == nil then
        return false, 0, "", 0
    end

    return true, found_node_index, found_text, found_chunk_offset
end

---@param tokens function
---@param parent_tag string
---@param match_index integer
---@param match_text string
---@return boolean ok
---@return integer node_counter
local function count_children(tokens, parent_tag, match_index, match_text)
    local match_counter = 0
    local found_node_index

    walk_children(tokens, parent_tag, false, function(node_index, token)
        if token.type == "tag" and token.text == match_text then
            match_counter = match_counter + 1

            if match_counter == match_index then
                found_node_index = node_index
                return false
            end
        end

        return true
    end)

    if found_node_index == nil then
        return false, 0
    end

    return true, found_node_index
end

---@param tokens function
---@param parent_tag string
---@param child_index integer an even CFI step
---@return boolean ok
---@return string tag
---@return boolean is_void
---@return integer tag_index crengine's index among the siblings with the same tag
local function find_element_child(tokens, parent_tag, child_index)
    local tag_counters = {}
    local target_token

    walk_children(tokens, parent_tag, false, function(node_index, token)
        if token.type == "tag" then
            tag_counters[token.text] = (tag_counters[token.text] or 0) + 1

            if node_index == child_index then
                target_token = token
                return false
            end
        end

        return node_index < child_index
    end)

    if target_token == nil then
        return false, "", false, 0
    end

    return true, target_token.text, target_token.is_void, tag_counters[target_token.text]
end

---@class CFITextPiece
---@field text string
---@field is_kept boolean whether crengine has a text node for it
---@field text_index integer crengine's text() index when kept
---@field chunk_offset integer where it starts in its chunk

---@param tokens function
---@param parent_tag string
---@param child_index integer an odd CFI step
---@return CFITextPiece[] pieces the chunk's text, split where comments are; empty when there is no such chunk
local function find_text_chunk(tokens, parent_tag, child_index)
    local text_counter = 0
    local pieces = {}

    walk_children(tokens, parent_tag, false, function(node_index, token, is_kept_text, chunk_offset)
        if is_kept_text then
            text_counter = text_counter + 1
        end

        if node_index == child_index then
            table.insert(pieces, {
                text = token.text,
                is_kept = is_kept_text,
                text_index = text_counter,
                chunk_offset = chunk_offset,
            })
        end

        return node_index <= child_index
    end)

    return pieces
end

---Finds the crengine text node that holds a CFI offset in a chunk.
---@param pieces CFITextPiece[]
---@param chunk_offset integer | nil
---@return CFITextPiece | nil piece
---@return integer | nil offset the offset within the piece
local function locate_in_chunk(pieces, chunk_offset)
    local located

    for _, piece in ipairs(pieces) do
        if piece.is_kept and (located == nil or (chunk_offset ~= nil and piece.chunk_offset <= chunk_offset)) then
            located = piece
        end
    end

    if located == nil or chunk_offset == nil then
        return located, chunk_offset
    end

    -- An offset in whitespace crengine dropped moves to the nearest end of the text it kept.
    return located, math.max(0, math.min(chunk_offset - located.chunk_offset, utf16_length(located.text)))
end

local function format_cfi(fragment_index, local_path)
    local global_path = "/6/" .. tostring(fragment_index * 2)

    return "epubcfi(" .. global_path .. "!" .. local_path .. ")"
end

---@param text string
---@param character_offset number
---@param ignore_whitespace boolean ignore inconsequential whitespace - true for xpointer, false for CFI
---@return number
local function translate_character_offset(text, character_offset, ignore_whitespace)
    local newline_count = 0
    local ignored_count = 0
    local text_offset = 0
    local is_ignored = true

    while text_offset <= #text do
        if ignore_whitespace and text_offset - newline_count - 1 >= character_offset then
            break
        elseif not ignore_whitespace and text_offset - ignored_count - 1 >= character_offset then
            break
        end

        local char = text:sub(text_offset, text_offset)

        if char == "\n" or char == "\r" then
            is_ignored = true
            newline_count = newline_count + 1
        else
            if char ~= "\t" and char ~= " " then
                is_ignored = false
            end
        end

        if is_ignored then
            ignored_count = ignored_count + 1
        end

        text_offset = text_offset + 1
    end

    if ignore_whitespace then
        return text_offset - ignored_count - 1
    else
        return text_offset - newline_count - 1
    end
end

---@param text string
---@param character_offset number
---@return number
local function translate_character_offset_cfi_to_xpointer(text, character_offset)
    return translate_character_offset(text, character_offset, true)
end

---@param text string
---@param character_offset number
---@return number
local function translate_character_offset_xpointer_to_cfi(text, character_offset)
    return translate_character_offset(text, character_offset, false)
end

---@class XPointerFragmentPart
---@field tag_name string
---@field tag_index integer
---@field character_offset? number

---@return number fragment_index
---@return XPointerFragmentPart[] fragment_path
local function decompose_xpointer(xpointer)
    local fragment_index, serialized_path = xpointer:match("^/body/DocFragment%[(%d+)%](.*)$")

    fragment_index = tonumber(fragment_index) or 1

    if serialized_path == nil then
        serialized_path = "/html/body"
    end

    local fragment_path = {}

    for fragment_path_part in serialized_path:gmatch("[^/]+") do
        local tag_name_no_character_offset, character_offset_str = fragment_path_part:match("(.*)%.(%d+)$")

        local fragment_path_part_cleaned = tag_name_no_character_offset or fragment_path_part

        local tag_name, tag_index_str = fragment_path_part_cleaned:match("([^[]+)%[(%d+)%]")

        if tag_name == nil then
            tag_name = fragment_path_part_cleaned
        end

        local character_offset = nil

        if character_offset_str ~= nil then
            character_offset = tonumber(character_offset_str)
        end

        local tag_index = 1

        if tag_index_str ~= nil then
            tag_index = tonumber(tag_index_str) or 1
        end

        table.insert(
            fragment_path,
            {
                tag_name = tag_name:lower(),
                tag_index = tag_index,
                character_offset = character_offset,
            }
        )
    end

    return fragment_index, fragment_path
end

---@param cfi string
---@return string cfi_start
---@return string cfi_end
local function split_local_range_cfi_path(cfi)
    local root, path_a, path_b = cfi:match("epubcfi%(([^,%)]+),([^,%)]+),([^,%)]+)%)$")

    if root == nil or path_a == nil or path_b == nil then
        error("invalid CFI range")
    end

    return "epubcfi(" .. root .. path_a .. ")", "epubcfi(" .. root .. path_b .. ")"
end

---@param fragment_html any
---@param cfi_local_path any
local function cfi_local_path_to_fragment_path(fragment_html, cfi_local_path)
    local tokens = tokenize_html(fragment_html)

    for token in tokens do
        -- Enter HTML
        if token.type == "tag" and token.text == "html" then
            break
        end
    end

    local last_token_was_void = false
    local fragment_path_parts = {}
    local text_pieces = nil
    local parent_tag = "html"

    for part in cfi_local_path:gmatch("([^/]+)") do
        if last_token_was_void then
            error("impossible CFI for document: attempting to get children of void")
        end

        if text_pieces ~= nil then
            error("impossible CFI for document: attempting to get children of text")
        end

        local part_node_index = tonumber(part:match("^(%d+)"))

        if part_node_index == nil then
            error("could not translate from local path to xpointer")
        end

        if part_node_index % 2 == 1 then
            text_pieces = find_text_chunk(tokens, parent_tag, part_node_index)
        else
            local ok, tag, is_void, tag_index = find_element_child(tokens, parent_tag, part_node_index)

            if not ok then
                error("could not translate from local path to xpointer")
            end

            last_token_was_void = is_void
            parent_tag = tag
            table.insert(fragment_path_parts, tag .. (tag_index ~= 1 and "[" .. tostring(tag_index) .. "]" or ""))
        end
    end

    local character_offset = tonumber(cfi_local_path:match(":(%d+)%)$"))

    if text_pieces ~= nil then
        local piece, piece_offset = locate_in_chunk(text_pieces, character_offset)

        if piece == nil then
            error("could not translate from local path to xpointer")
        end

        local index_suffix = piece.text_index ~= 1 and "[" .. tostring(piece.text_index) .. "]" or ""
        table.insert(fragment_path_parts, "text()" .. index_suffix)

        if piece_offset ~= nil then
            character_offset = translate_character_offset_cfi_to_xpointer(piece.text, piece_offset)
        end
    end

    local character_offset_suffix = ""
    if character_offset ~= nil then
        character_offset_suffix = "." .. tostring(character_offset)
    end

    return "/" .. table.concat(fragment_path_parts, "/") .. character_offset_suffix
end

---@param fragment_html string
---@param fragment_path XPointerFragmentPart[]
---@param keeps_whitespace? boolean
---@return string cfi_local_path
local function fragment_path_to_cfi_local_path(fragment_html, fragment_path, keeps_whitespace)
    if #fragment_path == 0 or #fragment_html == 0 then
        return "/1"
    end

    local tokens = tokenize_html(fragment_html)

    for token in tokens do
        -- Enter HTML
        if token.type == "tag" and token.text == "html" then
            break
        end
    end

    ---@type number[]
    local cfi_steps = {}
    local target_text = nil
    local target_chunk_offset = 0
    local parent_tag = "html"

    for _, part in ipairs(fragment_path) do
        ---@cast part XPointerFragmentPart

        if part.tag_name == "text()" then
            local found_text, text_node_index, text, chunk_offset = find_text_child(
                tokens,
                parent_tag,
                part.tag_index,
                keeps_whitespace == true
            )

            if not found_text then
                -- crengine has more text here than its default styles leave, so the book's stylesheet keeps whitespace.
                if not keeps_whitespace then
                    return fragment_path_to_cfi_local_path(fragment_html, fragment_path, true)
                end

                error("Unable to find XPointer text in document")
            end

            table.insert(cfi_steps, text_node_index)
            target_text = text
            target_chunk_offset = chunk_offset

            break
        end

        local found_ok, tag_counter = count_children(tokens, parent_tag, part.tag_index, part.tag_name)

        if not found_ok then
            error("Unable to find XPointer in document")
        end

        table.insert(cfi_steps, tag_counter)
        parent_tag = part.tag_name
    end

    local character_offset_suffix = ""
    -- If last has a character offset we need to add a suffix for character offsets
    if #fragment_path > 0 then
        local character_offset = fragment_path[#fragment_path].character_offset

        if character_offset ~= nil then
            if target_text ~= nil then
                character_offset = target_chunk_offset
                    + translate_character_offset_xpointer_to_cfi(target_text, character_offset)
            end

            character_offset_suffix = ":" .. tostring(character_offset)
        end
    end

    return "/" .. table.concat(cfi_steps, "/") .. character_offset_suffix
end

---@class GrimmoryCFIResolver
---@field document string
---@field cache Cache
local GrimmoryCFIResolver = {}

---@param document CREDocument
---@param cache? Cache
function GrimmoryCFIResolver:new(document, cache)
    local o = {
        document = document,
        cache = cache or Cache:new({ slots = 8 })
    }
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function GrimmoryCFIResolver:init()
end

---@param cfi_a string
---@param cfi_b string
---@return string
function GrimmoryCFIResolver.asCFIRange(cfi_a, cfi_b)
    local bare_cfi_a = cfi_a:match("^epubcfi%((.+)%)$")
    local bare_cfi_b = cfi_b:match("^epubcfi%((.+)%)$")

    local root = ""

    for step in bare_cfi_a:gmatch("([^/]+)") do
        local next = root .. "/" .. step .. "/"

        if next ~= bare_cfi_b:sub(1, #next) then
            break
        end

        root = root .. "/" .. step
    end

    return "epubcfi(" .. root .. "," .. bare_cfi_a:sub(#root + 1) .. "," .. bare_cfi_b:sub(#root + 1) .. ")"
end

---@private
---@param fragment_index integer
---@return string | nil html
function GrimmoryCFIResolver:getFragmentHTML(fragment_index)
    local html

    html = self.cache:get(fragment_index)
    if html ~= nil then
        return html
    end

    -- There has to be a better way to get this..

    local source
    local fragment_html = self.document:getHTMLFromXPointer("/body/DocFragment[" .. tostring(fragment_index) .. "]")
    for token in tokenize_html(fragment_html) do
        if token.type == "tag" and token.text == "docfragment" then
            source = token.raw:match("Source=\"([^\"]+)\"")
            break
        end
    end

    if source then
        html = self.document:getDocumentFileContent(source)
    end

    self.cache:insert(fragment_index, html)

    return html
end

---@param cfi string
---@return string xpointer
function GrimmoryCFIResolver:cfiToXpointer(cfi)
    -- Split global / local path
    local global_path, local_path = cfi:match("^epubcfi%(([^!]+)!(.+)")

    if global_path == nil then
        global_path = ""
    end

    if local_path == nil then
        local_path = cfi
    end

    -- Look up fragment HTML based on global path
    local fragment_index = 1

    local global_path_fragment_index = tonumber(global_path:match("^/6/(%d+)"))
    if global_path_fragment_index ~= nil then
        fragment_index = math.floor(tonumber(global_path_fragment_index) / 2)
    end

    local fragment_html = self:getFragmentHTML(fragment_index)

    if fragment_html == nil then
        logger:err("Unable to load fragment HTML for CFI:", cfi)
        error("Unable to load fragment HTML for CFI")
    end

    local fragment_path = cfi_local_path_to_fragment_path(fragment_html, local_path)

    return "/body/DocFragment[" .. tostring(fragment_index) .. "]" .. fragment_path
end

---@param cfi string
---@return string xpointer_start
---@return string xpointer_end
function GrimmoryCFIResolver:cfiRangeToXPointers(cfi)
    local cfi_start, cfi_end = split_local_range_cfi_path(cfi)

    return self:cfiToXpointer(cfi_start), self:cfiToXpointer(cfi_end)
end

---@param xpointer string
---@return string cfi
function GrimmoryCFIResolver:xpointerToCFI(xpointer)
    logger:dbg("Converting xpointer to CFI:", xpointer)

    local normalized_xpointer = self.document:getNormalizedXPointer(xpointer)

    if not normalized_xpointer then
        logger:err("XPointer not in document:", xpointer)
        error("XPointer not in document")
    end

    xpointer = normalized_xpointer

    -- Decompose XPointer to parts
    local fragment_index, fragment_path = decompose_xpointer(xpointer)

    -- Read HTML for fragment index
    local fragment_html = self:getFragmentHTML(fragment_index)

    if fragment_html == nil then
        logger:err("Unable to load fragment HTML for XPointer:", xpointer)
        error("Unable to load fragment HTML for XPointer")
    end

    -- DOM to CFI steps
    local local_path = fragment_path_to_cfi_local_path(fragment_html, fragment_path)

    logger:dbg("Local path for CFI:", local_path)

    -- Format
    return format_cfi(fragment_index, local_path)
end

---@param xpointer_start string
---@param xpointer_end string
---@return string cfi
function GrimmoryCFIResolver:xpointerRangeToCFI(xpointer_start, xpointer_end)
    local cfi_start = self:xpointerToCFI(xpointer_start)
    local cfi_end = self:xpointerToCFI(xpointer_end)

    return self.asCFIRange(cfi_start, cfi_end)
end

return GrimmoryCFIResolver