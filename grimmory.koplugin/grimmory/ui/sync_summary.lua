local _ = require("gettext")
local T = require("ffi/util").template

---@param book_path string | nil
---@return string
local function book_name(book_path)
    if type(book_path) ~= "string" then
        return _("Unknown book")
    end

    local file_name = book_path:match("([^/]+)$") or book_path

    return (file_name:gsub("%.[^.]+$", ""))
end

---@param progress number | nil
---@return string | nil
local function percent_text(progress)
    if type(progress) ~= "number" then
        return nil
    end

    return string.format("%d%%", math.floor(progress + 0.5))
end

---@param from_progress number | nil
---@param to_progress number | nil
---@return string
local function progress_change_text(from_progress, to_progress)
    local to_text = percent_text(to_progress) or "?"
    local from_text = percent_text(from_progress)

    if from_text == nil then
        return to_text
    end

    return T(_("%1 → %2"), from_text, to_text)
end

---@class GrimmorySyncSummaryEntry
---@field name string
---@field detail string

---Collects sync progress messages and renders them for the user.
---@class GrimmorySyncSummary
---@field downloaded_books GrimmorySyncSummaryEntry[]
---@field failed_books GrimmorySyncSummaryEntry[]
---@field pushed_progress GrimmorySyncSummaryEntry[]
---@field pulled_progress GrimmorySyncSummaryEntry[]
---@field available_progress GrimmorySyncSummaryEntry[]
---@field kept_progress GrimmorySyncSummaryEntry[]
---@field failed_progress GrimmorySyncSummaryEntry[]
---@field recorded_sessions GrimmorySyncSummaryEntry[]
---@field failed_sessions GrimmorySyncSummaryEntry[]
---@field failed_annotations GrimmorySyncSummaryEntry[]
---@field checked_book_count integer
---@field private is_kept_book { [string]: boolean }
local GrimmorySyncSummary = {}

function GrimmorySyncSummary:new()
    local o = {
        downloaded_books = {},
        failed_books = {},
        pushed_progress = {},
        pulled_progress = {},
        available_progress = {},
        kept_progress = {},
        is_kept_book = {},
        failed_progress = {},
        recorded_sessions = {},
        failed_sessions = {},
        failed_annotations = {},
        checked_book_count = 0,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

---@param progress table a progress message from the sync subprocess
function GrimmorySyncSummary:record(progress)
    local state = progress.state
    local book_path = progress.book_path or progress.bookPath
    local name = book_name(book_path)

    if state == "book-downloaded" then
        table.insert(self.downloaded_books, { name = name, detail = "" })
    elseif state == "book-pull-metadata" then
        self.checked_book_count = self.checked_book_count + 1
    elseif state == "book-error" then
        table.insert(self.failed_books, {
            name = T(_("Book %1"), tostring(progress.book_id)),
            detail = tostring(progress.message),
        })
    elseif state == "progress-pushed" then
        table.insert(self.pushed_progress, {
            name = name,
            detail = progress_change_text(progress.from_progress, progress.to_progress),
        })
    elseif state == "progress-pulled" then
        table.insert(self.pulled_progress, {
            name = name,
            detail = progress_change_text(progress.from_progress, progress.to_progress),
        })
    elseif state == "progress-available" then
        table.insert(self.available_progress, {
            name = name,
            detail = progress_change_text(progress.from_progress, progress.to_progress),
        })
    elseif state == "progress-kept" and not self.is_kept_book[book_path or name] then
        -- Push and pull can both decline the same book in one sync.
        self.is_kept_book[book_path or name] = true

        table.insert(self.kept_progress, {
            name = name,
            detail = T(
                _("device %1, Grimmory %2"),
                percent_text(progress.local_progress) or "?",
                percent_text(progress.remote_progress) or "?"
            ),
        })
    elseif state == "progress-failed" then
        table.insert(self.failed_progress, { name = name, detail = "" })
    elseif state == "session-recorded" then
        table.insert(self.recorded_sessions, { name = name, detail = "" })
    elseif state == "session-error" then
        table.insert(self.failed_sessions, { name = name, detail = "" })
    elseif state == "annotations-failed" then
        table.insert(self.failed_annotations, { name = name, detail = "" })
    end
end

---@private
---@return { title: string, entries: GrimmorySyncSummaryEntry[] }[]
function GrimmorySyncSummary:getSections()
    return {
        { title = _("Books downloaded"), entries = self.downloaded_books },
        { title = _("Progress sent to Grimmory"), entries = self.pushed_progress },
        { title = _("Progress received from Grimmory"), entries = self.pulled_progress },
        { title = _("Newer progress for the open book"), entries = self.available_progress },
        { title = _("Progress left unchanged (would move back)"), entries = self.kept_progress },
        { title = _("Sessions recorded"), entries = self.recorded_sessions },
        { title = _("Books failed"), entries = self.failed_books },
        { title = _("Progress failed"), entries = self.failed_progress },
        { title = _("Sessions failed"), entries = self.failed_sessions },
        { title = _("Annotations failed"), entries = self.failed_annotations },
    }
end

---A divergence that sync declined to resolve repeats every run, so alone it does not justify the screen.
---@return boolean
function GrimmorySyncSummary:hasDetails()
    local sections = self:getSections()

    for index = 1, #sections do
        local entries = sections[index].entries

        if #entries > 0 and entries ~= self.kept_progress then
            return true
        end
    end

    return false
end

---@return table[] kv_pairs rows for KOReader's KeyValuePage
function GrimmorySyncSummary:toKeyValuePairs()
    local kv_pairs = {}
    local sections = self:getSections()

    for index = 1, #sections do
        local section = sections[index]

        if #section.entries > 0 then
            table.insert(kv_pairs, { section.title, tostring(#section.entries) })

            for entry_index = 1, #section.entries do
                local entry = section.entries[entry_index]

                table.insert(kv_pairs, { "  " .. entry.name, entry.detail })
            end

            kv_pairs[#kv_pairs].separator = true
        end
    end

    if self.checked_book_count > 0 then
        table.insert(kv_pairs, { _("Books already up to date"), tostring(self.checked_book_count) })
    elseif #kv_pairs > 0 then
        kv_pairs[#kv_pairs].separator = nil
    end

    return kv_pairs
end

return GrimmorySyncSummary
