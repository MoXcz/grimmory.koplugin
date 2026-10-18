local DocumentRegistry = require("document/documentregistry")

local GrimmoryCFIResolver = require("grimmory/cfi_resolver")
local GrimmoryDatetime = require("grimmory/datetime")
local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

---@param document_path string
---@param callback (fun(resolver: GrimmoryCFIResolver): nil)
---@return boolean ok false when the document could not be opened or `callback` failed
local function with_cfi_resolver(document_path, callback)
    local document = (
        DocumentRegistry:hasProvider(document_path) and
        DocumentRegistry:openDocument(document_path)
    )

    if not document then
        logger:err("Could not open document for annotations:", document_path)
        return false
    end

    local ok, err = pcall(function()
        if document.loadDocument and not document:loadDocument(true) then
            error("Could not load document")
        end

        callback(GrimmoryCFIResolver:new(document))
    end)

    document:close()

    if not ok then
        logger:err("Could not resolve annotations for:", document_path, err)
    end

    return ok
end

local KOREADER_COLOR_MAP = {
    yellow = "#FFC107",
    green = "#4ADE80",
    cyan = "#38BDF8",
    pink = "#F472B6",
    orange = "#FB923C",
    red = "#FB523C",
    purple = "#F452FC",
    blue = "#0248F8",
    gray = "#AAAAAA",
    white = "#FAFAFA",
}

local GRIMMORY_COLOR_MAP = {
    ["#FFC107"] = "yellow",
    ["#4ADE80"] = "green",
    ["#38BDF8"] = "cyan",
    ["#F472B6"] = "pink",
    ["#FB923C"] = "orange",
    ["#FB523C"] = "red",
    ["#F452FC"] = "purple",
    ["#0248F8"] = "blue",
    ["#AAAAAA"] = "gray",
    ["#FAFAFA"] = "white",
}

local KOREADER_STYLE_MAP = {
    lighten    = "highlight",
    underscore = "underline",
    strikeout  = "strikethrough",
}

local GRIMMORY_STYLE_MAP = {
    highlight = "lighten",
    underline = "underscore",
    strikethrough = "strikeout",
}

local DEFAULT_KOREADER_COLOR = "yellow"
local DEFAULT_KOREADER_STYLE = "lighten"
local DEFAULT_GRIMMORY_COLOR = KOREADER_COLOR_MAP[DEFAULT_KOREADER_COLOR]
local DEFAULT_GRIMMORY_STYLE = KOREADER_STYLE_MAP[DEFAULT_KOREADER_STYLE]

---@class GrimmoryReadingAnnotations
---@field doc_metadata GrimmoryDocMetadata
local GrimmoryReadingAnnotations = {}

function GrimmoryReadingAnnotations:new(doc_metadata)
    local o = {
        doc_metadata = doc_metadata,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

local function normalize_xpointer(xpointer)
    if xpointer == nil then
        return ""
    end

    -- /p[1]/ -> /p/
    xpointer = xpointer:gsub("%[1%]", "")

    -- /text().0 -> /text()
    xpointer = xpointer:gsub("%.0$", "")

    return xpointer
end

---@param a string
---@param b string
---@return bool
local function is_same_xpointer(a, b)
    return normalize_xpointer(a) == normalize_xpointer(b)
end

---@param is_remote_id { [string]: boolean } every Grimmory ID on the server, placeable or not
---@param is_pending_id { [string]: boolean } IDs whose local edit or removal has not reached Grimmory yet
local function merge_annotations(local_annotations, remote_annotations, is_remote_id, is_pending_id)
    local remote_grimmory_ids = {}
    for _, a in ipairs(remote_annotations) do
        if a.grimmory_id ~= nil and not is_pending_id[tostring(a.grimmory_id)] then
            remote_grimmory_ids[tostring(a.grimmory_id)] = a
        end
    end

    local local_grimmory_ids = {}
    local new_annotations = {}

    -- Filter out existing records with Grimmory IDs that do not
    -- exist on the Grimmory side anymore.
    for _, a in ipairs(local_annotations) do
        local key = a.grimmory_id ~= nil and tostring(a.grimmory_id) or nil

        if key ~= nil then
            local_grimmory_ids[key] = a
        end

        if key == nil or is_remote_id[key] or is_pending_id[key] then
            table.insert(new_annotations, a)
        end
    end

    for grimmory_id, annotation in pairs(remote_grimmory_ids) do
        if local_grimmory_ids[grimmory_id] == nil then
            local found_annotation = false
            for _, existing_annotation in ipairs(new_annotations) do
                if (
                    existing_annotation.grimmory_id == nil and
                    existing_annotation.pos0 ~= nil and
                    existing_annotation.pos1 ~= nil and
                    is_same_xpointer(existing_annotation.pos0, annotation.pos0) and
                    is_same_xpointer(existing_annotation.pos1, annotation.pos1)
                ) then
                    found_annotation = true

                    -- Just apply, don't think too hard about it.
                    existing_annotation.grimmory_id = annotation.grimmory_id
                    existing_annotation.datetime = annotation.datetime
                    existing_annotation.datetime_updated = annotation.datetime_updated
                    existing_annotation.color = annotation.color
                    existing_annotation.drawer = annotation.drawer
                    existing_annotation.chapter = annotation.chapter
                    existing_annotation.text = annotation.text
                    existing_annotation.page = annotation.page
                    existing_annotation.note = annotation.note
                end
            end

            if not found_annotation then
                -- This is a new annotation and can be added to the table
                table.insert(new_annotations, annotation)
            end
        else
            local existing_annotation = local_grimmory_ids[grimmory_id]

            -- Grimmory never moves an annotation, so only what it can change is taken; the local position
            -- stays exact instead of going through the CFI round trip.
            existing_annotation.datetime_updated = annotation.datetime_updated
            existing_annotation.color = annotation.color
            existing_annotation.drawer = annotation.drawer
            existing_annotation.note = annotation.note
        end
    end

    -- TODO: Merge overlapping annotations
    -- If there are annotations that overlap exactly, select the "latest"
    -- and delete the older ones
    -- For imperfect overlap, combine and prioritize the later ones.

    return new_annotations
end

---@param cfi_resolver GrimmoryCFIResolver
---@param annotation GrimmoryAnnotation
---@return table koreader_annotation
local function to_koreader_annotation(cfi_resolver, annotation)
    local xpointer_start, xpointer_end = cfi_resolver:cfiRangeToXPointers(annotation.cfi)

    return {
        grimmory_id = annotation.id,

        datetime = GrimmoryDatetime.toAnnotationDatetime(annotation.created_at),
        datetime_updated = GrimmoryDatetime.toAnnotationDatetime(annotation.updated_at),

        color = GRIMMORY_COLOR_MAP[annotation.color] or DEFAULT_KOREADER_COLOR,
        drawer = GRIMMORY_STYLE_MAP[annotation.style] or DEFAULT_KOREADER_STYLE,

        chapter = annotation.chapter,
        text = annotation.text,
        -- A note cleared on a device reaches Grimmory as empty; KOReader expects none.
        note = annotation.note ~= "" and annotation.note or nil,

        page = xpointer_start,

        pos0 = xpointer_start,
        pos1 = xpointer_end,
    }
end

---@param book_path string
---@param annotations GrimmoryAnnotation[]
---@param held_back_cfis? { [string]: boolean } CFIs of local annotations a failed push left unlinked
---@return boolean ok false when the book could not be read, leaving its annotations untouched
function GrimmoryReadingAnnotations:applyAnnotations(book_path, grimmory_annotations, held_back_cfis)
    local remote_annotations = {}
    local is_remote_id = {}
    held_back_cfis = held_back_cfis or {}

    local resolved = with_cfi_resolver(
        book_path,
        function (cfi_resolver)
            for _, annotation in ipairs(grimmory_annotations) do
                is_remote_id[tostring(annotation.id)] = true

                -- Probably what the failed create stored; importing it would duplicate the local annotation.
                local koreader_annotation = not held_back_cfis[annotation.cfi]
                    and to_koreader_annotation(cfi_resolver, annotation)

                if koreader_annotation then
                    table.insert(remote_annotations, koreader_annotation)
                end
            end
        end
    )

    -- Without the document every remote annotation would look deleted and take its local copy with it.
    if not resolved then
        return false
    end

    local is_pending_id = {}
    for _, modified_id in ipairs(self.doc_metadata:getModifiedGrimmoryAnnotations(book_path)) do
        is_pending_id[tostring(modified_id)] = true
    end

    local local_annotations = self.doc_metadata:getAnnotations(book_path)

    local new_annotations = merge_annotations(local_annotations, remote_annotations, is_remote_id, is_pending_id)

    self.doc_metadata:setAnnotations(book_path, new_annotations)

    return true
end

---@return boolean ok false when the book cannot be read
---@return GrimmoryAnnotation[] | nil annotations
function GrimmoryReadingAnnotations:getAnnotations(book_path)
    local annotations = self.doc_metadata:getAnnotations(book_path)

    local grimmory_annotations = {}

    local resolved = with_cfi_resolver(
        book_path,
        function(cfi_resolver)
            for index, annotation in ipairs(annotations) do
                -- Annotations without pos0 / pos1 are bookmarks
                if annotation.pos0 ~= nil and annotation.pos1 ~= nil then
                    ---@type GrimmoryAnnotation
                    local grimmory_annotation = {
                        id = annotation.grimmory_id,
                        book_id = -1,
                        local_index = index,
                        created_at = GrimmoryDatetime.fromAnnotationDatetime(annotation.datetime),
                        updated_at = GrimmoryDatetime.fromAnnotationDatetime(annotation.datetime_updated),
                        cfi = cfi_resolver:xpointerRangeToCFI(annotation.pos0, annotation.pos1),
                        chapter = annotation.chapter,
                        text = annotation.text,
                        note = annotation.note,
                        color = KOREADER_COLOR_MAP[annotation.color] or DEFAULT_GRIMMORY_COLOR,
                        style = KOREADER_STYLE_MAP[annotation.drawer] or DEFAULT_GRIMMORY_STYLE,
                    }

                    table.insert(grimmory_annotations, grimmory_annotation)
                end
            end
        end
    )

    if not resolved then
        return false, nil
    end

    return true, grimmory_annotations
end

---@param book_path string
---@param updates { index: integer, grimmory_id: integer }[] `index` is a GrimmoryAnnotation's local_index
function GrimmoryReadingAnnotations:setGrimmoryIds(book_path, updates)
    local annotations = self.doc_metadata:getAnnotations(book_path)

    for _, update in ipairs(updates) do
        local annotation = annotations[update.index]

        if annotation then
            annotation.grimmory_id = update.grimmory_id
        end
    end

    self.doc_metadata:setAnnotations(book_path, annotations)
end

return GrimmoryReadingAnnotations