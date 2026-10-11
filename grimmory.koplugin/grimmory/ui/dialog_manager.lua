local _ = require("gettext")
local T = require("ffi/util").template

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local PathChooser = require("ui/widget/pathchooser")
local ProgressbarDialog = require("ui/widget/progressbardialog")

local GrimmoryLogger = require("grimmory/logger")

local logger = GrimmoryLogger:new()

---@class DialogManager
---@field settings GrimmorySettings
---@field api GrimmoryAPI
---@field executor GrimmoryExecutor
---@field private is_running_in_background boolean | nil
---@field updater GrimmorySelfUpdater
---@field reading_progress_manager ReadingProgressManager
local DialogManager = {}

function DialogManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function DialogManager:toast(text, timeout)
    if self.info_message then
        UIManager:close(self.info_message)
    end

    if timeout == nil then
        timeout = 2
    elseif timeout <= 0 then
        timeout = nil
    end

    local info_message = InfoMessage:new({
        text = text,
        timeout = timeout,
    })

    UIManager:show(info_message)
    self.info_message = info_message

    return function() UIManager:close(info_message) end
end

---Runs a blocking network call in a subprocess so the UI stays responsive.
---@param busy_text string
---@param runnable fun(): any must return a JSON-serializable value
---@param on_done fun(ok: boolean, result: any)
function DialogManager:runInBackground(busy_text, runnable, on_done)
    -- A second tap while waiting would fork again and orphan the busy message.
    if self.is_running_in_background then
        return
    end

    self.is_running_in_background = true

    local close_busy_message = self:toast(busy_text, 0)

    self.executor:background(
        function(run)
            local run_ok, ok, result = pcall(run, runnable, function() end)

            self.is_running_in_background = false
            pcall(close_busy_message)

            if run_ok then
                on_done(ok, result)
            else
                on_done(false, ok)
            end
        end,
        false
    )
end

function DialogManager:showConnectionSettings()
    local dialog
    dialog = MultiInputDialog:new({
        title = _("Grimmory Connection"),
        fields = {
            {
                text = self.settings:getBaseUri(),
                description = _("Server URL"),
                hint = _("http://example.com:port"),
            },
            {
                text = self.settings:getUsername(),
                description = _("Username"),
            },
            {
                text = self.settings:getPassword(),
                description = _("Password"),
                text_type = "password",
            },
        },
        buttons = {
            {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Test"),
                callback = function()
                    local fields = dialog:getFields()

                    self:runInBackground(
                        _("Testing connection"),
                        function()
                            local ok, version_or_error = self.api:testConnection(
                                fields[1],
                                fields[2],
                                fields[3]
                            )

                            return { ok = ok, message = tostring(version_or_error) }
                        end,
                        function(run_ok, result)
                            if run_ok and type(result) == "table" and result.ok then
                                self:toast(T(_("Connection successful\nGrimmory (%1)"), result.message))
                            else
                                local error_message = type(result) == "table" and result.message or tostring(result)
                                self:toast(T(_("Unable to connect to Grimmory\nError: %1"), error_message))
                            end
                        end
                    )
                end,
            },
            {
                text = _("Apply"),
                callback = function()
                    local fields = dialog:getFields()

                    self.settings:setBaseUri(fields[1])
                    self.settings:setUsername(fields[2])
                    self.settings:setPassword(fields[3])

                    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                    UIManager:close(dialog)
                end,
            },
            },
        },
    })

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

---@param on_change? function called after the target shelves change
function DialogManager:showTargetShelvesSettings(on_change)
    self:runInBackground(
        _("Loading shelves"),
        function()
            local ok, shelves_or_error = self.api:getShelves()

            if not ok or type(shelves_or_error) ~= "table" then
                return { error = tostring(shelves_or_error) }
            end

            return { shelves = shelves_or_error }
        end,
        function(run_ok, result)
            if not run_ok or type(result) ~= "table" or result.shelves == nil then
                local error_message = type(result) == "table" and result.error or tostring(result)

                logger:err("Something went wrong loading shelves", error_message)
                self:toast(T(_("Could not load shelves: %1"), error_message))
                return
            end

            self:showTargetShelvesDialog(result.shelves, on_change)
        end
    )
end

---@param shelves GrimmoryTargetShelf[]
---@param on_change? function called after the target shelves change
function DialogManager:showTargetShelvesDialog(shelves, on_change)
    local dialog

    local is_selected_by_id = {}
    for _, target_shelf in ipairs(self.settings:getDownloadTargetShelves()) do
        is_selected_by_id[tostring(target_shelf.id)] = true
    end

    local function apply_target_shelves(target_shelves)
        self.settings:setDownloadTargetShelves(target_shelves)

        UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

        UIManager:close(dialog)

        if on_change then
            on_change()
        end
    end

    local buttons = {
        {
            {
                text = _("All Shelves"),
                callback = function()
                    apply_target_shelves({})
                end,
            }
        }
    }

    local selectable_shelves = {}
    local is_name_used = {}

    for _, shelf in ipairs(shelves) do
        local shelf_name = shelf.name or tostring(shelf.id)
        local unique_shelf_name = shelf_name
        local unique_shelf_index = 0
        while is_name_used[unique_shelf_name] do
            unique_shelf_index = unique_shelf_index + 1
            unique_shelf_name = shelf_name .. " " .. unique_shelf_index
        end
        is_name_used[unique_shelf_name] = true

        local shelf_key = tostring(shelf.id)
        table.insert(selectable_shelves, { id = shelf.id, name = unique_shelf_name })

        table.insert(
            buttons,
            {
                {
                    text = unique_shelf_name,
                    checked_func = function()
                        return is_selected_by_id[shelf_key] == true
                    end,
                    callback = function()
                        is_selected_by_id[shelf_key] = not is_selected_by_id[shelf_key]
                    end,
                }
            }
        )
    end

    table.insert(
        buttons,
        {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Apply"),
                callback = function()
                    local target_shelves = {}
                    for _, shelf in ipairs(selectable_shelves) do
                        if is_selected_by_id[tostring(shelf.id)] then
                            table.insert(target_shelves, shelf)
                        end
                    end

                    apply_target_shelves(target_shelves)
                end,
            },
        }
    )

    dialog = ButtonDialog:new({
        title = _("Source Shelves"),
        buttons = buttons,
    })

    UIManager:show(dialog)
end

---@param on_change? function called after the frequency changes
function DialogManager:showSyncFrequencySettings(on_change)
    local dialog
    dialog = MultiInputDialog:new({
        title = _("Periodic Sync Frequency"),
        fields = {
            {
                text = self.settings:getSyncFrequency(),
                description = _("Minutes between synchronization"),
                input_type = "number"
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Apply"),
                    callback = function()
                        local fields = dialog:getFields()

                        self.settings:setSyncFrequency(math.max(1, fields[1]))

                        UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                        UIManager:close(dialog)

                        if on_change then
                            on_change()
                        end
                    end,
                },
            },
        },
    })

    UIManager:show(dialog)
end

function DialogManager:showSessionThresholdSettings()
    local dialog
    dialog = MultiInputDialog:new({
        title = _("Session Thresholds"),
        fields = {
            {
                text = self.settings:getSessionThresholdSeconds(),
                description = _("Minimum Session Seconds"),
                input_type = "number",
            },
            {
                text = self.settings:getSessionThresholdPages(),
                description = _("Minimum Session Pages"),
                input_type = "number",
            },
        },
        buttons = {
            {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Apply"),
                callback = function()
                    local fields = dialog:getFields()

                    self.settings:setSessionThresholdSeconds(math.max(0, fields[1]))
                    self.settings:setSessionThresholdPages(math.max(0, fields[2]))

                    UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

                    UIManager:close(dialog)
                end,
            },
            },
        },
    })

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

---@param on_change? function called after the download directory changes
function DialogManager:showDownloadDirectorySettings(on_change)
    local dialog
    dialog = PathChooser:new({
        title = _("Download Directory"),
        select_file = false,
        show_files = false,
        path = self.settings:getDownloadDirectory(),
        onConfirm = function(newPath)
            self.settings:setDownloadDirectory(newPath)

            UIManager:broadcastEvent(Event:new("GrimmorySettingsChanged"))

            if on_change then
                on_change()
            end
        end,
    })

    UIManager:show(dialog)
end

function DialogManager:showPluginUpdateCheck()
    self:runInBackground(
        _("Checking for Updates"),
        function()
            return self.updater:lookupLatestVersion()
        end,
        function(run_ok, latest_version)
            if run_ok and latest_version then
                self.updater:setLatestKnownVersion(latest_version)
            end

            self:showPluginUpdateDialog()
        end
    )
end

function DialogManager:showPluginUpdateDialog()
    local dialog
    local latest_version = self.updater:getLatestReleaseVersion()
    local is_update_available = self.updater:isUpdateAvailable()

    local update_button_text = _("No update available")
    local title = _("Grimmory.koplugin is currently up-to-date.")

    if is_update_available then
        update_button_text = T(_("Update to %1"), latest_version)
        title = _("Update available for Grimmory.koplugin.")
    end

    dialog = ButtonDialog:new({
        title = title,
        buttons = {
            {
                {
                    text = update_button_text,
                    callback = function()
                        if is_update_available then
                            UIManager:close(dialog)

                            self:showPluginUpdater()
                        end
                    end,
                },
                {
                    text = _("Check for Updates"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showPluginUpdateCheck()
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    })

    UIManager:show(dialog)
end

function DialogManager:showPluginUpdater()
    local dialog = ProgressbarDialog:new({
        title = _("Updating Grimmory Plugin"),
        progress_max = 100,
        refresh_time_seconds = 3,
        dismissable = false,
    })

    UIManager:show(dialog)

    UIManager:nextTick(function()
        self.updater:update(
            function(state, progress, message)
                dialog:reportProgress(progress)

                if state == "complete" then
                    UIManager:close(dialog)

                    UIManager:askForRestart(_("Grimmory plugin update will apply on next Restart."))
                elseif state == "failed" then
                    UIManager:close(dialog)

                    self:toast(T(_("Failed to update\n%1"), message), 0)
                end
            end
        )
    end)
end

function DialogManager:showProgressDialog(title, dismiss_callback, dismiss_text)
    local dialog
    local is_external_closing = false

    if dismiss_text == nil then
        dismiss_text = _("Terminate this task?")
    end

    dialog = ProgressbarDialog:new({
        title = title,
        progress_max = 100,
        refresh_time_seconds = 3,
        dismiss_text = dismiss_text,
        dismissable = dismiss_callback ~= nil,
        dismiss_callback = function ()
            if not is_external_closing then
                -- Only call the dismiss callback if we are closing
                -- from the progress bar dialog itself.
                pcall(dismiss_callback)
            end
        end
    })

    dialog:show()

    local close_callback = function()
        is_external_closing = true
        dialog:close()
    end

    local function update_callback(progress, total_progress)
        dialog.progress_max = total_progress
        dialog:reportProgress(progress)
    end

    return update_callback, close_callback
end

---@param progress ReadingSessionProgress
function DialogManager:showApplyProgressConfirmation(progress)
    -- TODO:

    -- Reading Progress is Available from Grimmory
    -- Go to page 25 from 25 minutes ago?

    local dialog = ConfirmBox:new({
        text = T(
            _("Go to latest location %1% from Grimmory?"),
            tostring(progress.end_progress)
        ),
        ok_callback = function()
            self.reading_progress_manager:applyProgress(progress)
        end,
    })

    UIManager:show(dialog)
end

return DialogManager