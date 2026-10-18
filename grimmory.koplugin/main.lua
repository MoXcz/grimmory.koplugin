--[[--
Grimmory KOReader Plugin

@module koplugin.Grimmory
--]]--
local _ = require("gettext")

local Dispatcher = require("dispatcher")
local FileManager = require("apps/filemanager/filemanager")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local ReadCollection = require("readcollection")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local GrimmoryDocMetadata = require("grimmory/doc_metadata")
local GrimmoryDialogManager = require("grimmory/ui/dialog_manager")
local GrimmoryExecutor = require("grimmory/executor")
local GrimmoryMenu = require("grimmory/ui/menu")
local GrimmorySettings = require("grimmory/settings")
local GrimmorySyncSummary = require("grimmory/ui/sync_summary")
local GrimmoryAPI = require("grimmory/grimmory_api")
local GrimmorySynchronize = require("grimmory/synchronize")
local GrimmoryScheduler = require("grimmory/scheduler")
local GrimmorySelfUpdater = require("grimmory/ota/self_updater")
local GithubAPI = require("grimmory/ota/github_api")
local GrimmoryLogger = require("grimmory/logger")
local GrimmoryReadingRecorder = require("grimmory/reading/recorder")
local GrimmoryLocalRepository = require("grimmory/repository")
local GrimmoryReadingAnnotations = require("grimmory/reading/annotations")
local GrimmoryReadingProgressManager = require("grimmory/reading/progress_manager")


local logger = GrimmoryLogger:new()

-- KOReader creates a plugin instance per file manager and reader screen; this is the one on screen.
local live_instance = nil

-- Set while a sync runs; shared by every instance, since a sync outlives the screen that started it.
local interrupt_running_sync = nil

-- One timer for the whole process: a timer per screen restarted its countdown on every screen switch.
local periodic_sync_scheduler = GrimmoryScheduler:new()
local cancel_periodic_sync = nil
local update_periodic_sync = nil

---@class Grimmory
---@field dialog_manager DialogManager
---@field synchronizer GrimmorySynchronize
---@field ui any This is a ReaderUI
local Grimmory = WidgetContainer:extend{
    name = "grimmory",
    is_doc_only = false,
}

function Grimmory:onDispatcherRegisterActions()
  Dispatcher:registerAction("grimmory_sync_foreground", {
    category = "none",
    event = "GrimmorySyncForegound",
    title = _("Grimmory: Sync Now"),
    general = true,
  })

  Dispatcher:registerAction("grimmory_sync_background", {
    category = "none",
    event = "GrimmorySyncBackground",
    title = _("Grimmory: Sync in Background"),
    general = true,
  })

  Dispatcher:registerAction("grimmory_sync_open_book_foreground", {
    category = "none",
    event = "GrimmorySyncOpenBookForeground",
    title = _("Grimmory: Sync Open Book Now"),
    general = true,
  })

  Dispatcher:registerAction("grimmory_sync_open_book_background", {
    category = "none",
    event = "GrimmorySyncOpenBookBackground",
    title = _("Grimmory: Sync Open Book in Background"),
    general = true,
  })
end

function Grimmory:init()
    self.settings = GrimmorySettings:new()

    self.repository = GrimmoryLocalRepository:new({
        settings = self.settings,
    })

    self.doc_metadata = GrimmoryDocMetadata:new({
        ui = self.ui,
    })

    self.reading_recorder = GrimmoryReadingRecorder:new({
        repository = self.repository,
        settings = self.settings,
        ui = self.ui,
    })

    self.updater = GrimmorySelfUpdater:new({
        github_api = GithubAPI:new(),
        settings = self.settings,
    })

    self.api = GrimmoryAPI:new({
        settings = self.settings
    })

    self.reading_annotations = GrimmoryReadingAnnotations:new(self.doc_metadata)

    self.reading_progress_manager = GrimmoryReadingProgressManager:new({
        ui = self.ui,
        api = self.api,
        settings = self.settings,
        repository = self.repository,
        reading_recorder = self.reading_recorder,
        doc_metadata = self.doc_metadata,
    })

    self.executor = GrimmoryExecutor:new()

    self.dialog_manager = GrimmoryDialogManager:new({
        settings = self.settings,
        api = self.api,
        executor = self.executor,
        updater = self.updater,
        reading_progress_manager = self.reading_progress_manager,
    })

    self.menu = GrimmoryMenu:new({
        ui = self.ui,
        settings = self.settings,
        dialog_manager = self.dialog_manager,
        updater = self.updater,
        get_sync_interrupt = function() return interrupt_running_sync end,
    })

    self.synchronizer = GrimmorySynchronize:new({
        settings = self.settings,
        repository = self.repository,
        api = self.api,
        doc_metadata = self.doc_metadata,
        reading_progress_manager = self.reading_progress_manager,
        reading_annotations = self.reading_annotations,
    })

    self:onGrimmorySettingsChanged()

    self.ui.menu:registerToMainMenu(self.menu)

    live_instance = self

    -- KOReader keeps only the first registration for a row ID, so the buttons must not capture `self`.
    FileManager:addFileDialogButtons(
        "grimmory_actions",
        function(file, is_file)
            if not is_file then
                return nil
            end

            local function sync_file(refresh_book)
                local file_chooser = FileManager.instance.file_chooser

                if file_chooser and file_chooser.file_dialog then
                    UIManager:close(file_chooser.file_dialog)
                end

                if live_instance then
                    live_instance:onGrimmorySync(true, file, refresh_book)
                end
            end

            return {
                {
                    text = _("Sync with Grimmory"),
                    callback = function()
                        sync_file(false)
                    end,
                },
                {
                    text = _("Reload from Grimmory"),
                    callback = function()
                        sync_file(true)
                    end
                }
            }
        end
    )

    self:onDispatcherRegisterActions()

    logger:dbg("Initialized")
end

function Grimmory:onCloseWidget()
    logger:dbg("Closing")

    if live_instance == self then
        live_instance = nil
    end
end

function Grimmory:onExit()
    logger:dbg("Exiting")

    self.executor:clear()
end

function Grimmory:onSuspend()
    logger:dbg("Device is suspending")

    self.reading_recorder:onSessionEnd()

    if self.settings:getSyncOnSuspend() then
       self:onGrimmorySync(false)
    end
end

function Grimmory:onResume()
    logger:dbg("Device is resuming")

    if self.settings:getSyncReadingProgress() then
        self:pullProgressForOpenBook()
    end

    self.reading_recorder:onSessionStart()
end

function Grimmory:onPowerOff()
    logger:dbg("Device is powering off")

    self.reading_recorder:onSessionEnd()

    if self.settings:getSyncOnPowerOff() then
       self:onGrimmorySync(false)
    end
end

function Grimmory:onReaderReady()
    logger:dbg("Document open and ready")

    if self.settings:getSyncReadingProgress() then
        self:pullProgressForOpenBook()
    end

    self.reading_recorder:onSessionStart()
end

function Grimmory:onPageUpdate(page)
    logger:dbg("Page Update", page)

    -- Run after everything else does for a page event.
    -- This prevents issues like the previous page's xpointer being
    -- returned for a given page.
    UIManager:nextTick(function()
        self.reading_recorder:onPageUpdate()
    end)
end

function Grimmory:onCloseDocument()
    logger:dbg("Document closing")

    self.reading_recorder:onSessionEnd()

    if self.settings:getSyncOnCloseDocument() then
        -- Do not block the UI thread
        UIManager:nextTick(function()
            self:onGrimmorySync(false)
        end)
    end
end

function Grimmory:onAnnotationsModified(annotation_info)
    logger:dbg("Annotations modified", annotation_info)

    local annotation = annotation_info[1]

    local is_modified = false
    if annotation_info.index_modified == nil then
        self.reading_recorder:onAnnotationUpdated()
        is_modified = true
    elseif annotation_info.index_modified < 0 then
        self.reading_recorder:onAnnotationRemoved()
        is_modified = true
    else
        self.reading_recorder:onAnnotationAdded()
    end

    if is_modified and self.ui ~= nil and self.ui.document ~= nil and self.ui.document.file ~= nil then
        if annotation ~= nil and annotation.grimmory_id ~= nil then
            self.doc_metadata:appendModifiedGrimmoryAnnotation(
                self.ui.document.file,
                annotation.grimmory_id
            )
        end
    end
end

function Grimmory:onGrimmorySettingsChanged()
    logger:dbg("Settings Changed")

    self:onSchedulePeriodicPush()
end

function Grimmory:onSchedulePeriodicPush()
    if self.settings:getSyncPeriodically() then
        local frequency_seconds = self.settings:getSyncFrequency() * 60

        if update_periodic_sync then
            update_periodic_sync(frequency_seconds)
        else
            cancel_periodic_sync, update_periodic_sync = periodic_sync_scheduler:interval(
                frequency_seconds,
                function()
                    if live_instance then
                        live_instance:onGrimmorySync(false)
                    end
                end
            )
        end
    else
        if cancel_periodic_sync then
            cancel_periodic_sync()
        end

        cancel_periodic_sync = nil
        update_periodic_sync = nil
    end
end

function Grimmory:pullProgressForOpenBook()
    if self.ui == nil or self.ui.document == nil or self.ui.document.file == nil then
        return
    end

    local book_path = self.ui.document.file

    -- Tell everything to flush so we have data available for our sync
    UIManager:broadcastEvent(Event:new("FlushSettings"))

    self.executor:background(
        function(run)
            local ok, latest_progress = run(
                function()
                    local decision, _, remote_progress = self.reading_progress_manager:getPullDecision(book_path)

                    if decision == "apply" then
                        return remote_progress
                    end

                    return nil
                end
            )

            if not ok or not latest_progress then
                return
            end

            self.dialog_manager:showApplyProgressConfirmation(latest_progress)
        end,
        self.settings:getSyncEnableWifi()
    )
end

---@return boolean ready
---@return string | nil refusal_message
function Grimmory:isReadyToSync()
    if self.settings:getBaseUri() == "" then
        logger:info("BaseURI is not configured, cannot sync")
        return false, _("Grimmory connection is not configured")
    end

    if interrupt_running_sync then
        logger:info("Synchronization is already happening, not ready to sync again")
        return false, _("Grimmory synchronization is already running")
    end

    return true
end

function Grimmory:onGrimmorySyncForegound()
    return self:onGrimmorySync(true)
end

function Grimmory:onGrimmorySyncBackground()
    return self:onGrimmorySync(false)
end

function Grimmory:onGrimmorySyncOpenBookForeground()
    return self:onGrimmorySyncOpenBook(true)
end

function Grimmory:onGrimmorySyncOpenBookBackground()
    return self:onGrimmorySyncOpenBook(false)
end

function Grimmory:onGrimmorySyncOpenBook(verbose)
    if self.ui == nil or self.ui.document == nil or self.ui.document.file == nil then
        logger:info("No open book, skipping sync")
        return
    end

    local book_path = self.ui.document.file

    return self:onGrimmorySync(verbose, book_path)
end

---Reloads the open book when it is `book_path`; any other sync cannot have changed it, and a reload interrupts reading.
---@param book_path string | nil the book that was synced, nil for a full sync
---@param after_refresh? function runs once the UI is back, after the reload if there is one
function Grimmory:refreshUI(book_path, after_refresh)
    if book_path == nil or not self.reading_progress_manager:isOpenBook(book_path) then
        logger:dbg("The synced book is not open, not reloading")

        if after_refresh then
            after_refresh()
        end

        return
    end

    local settings = self.doc_metadata:getDocSettings(self.ui.document.file, true)

    if self.ui.annotation then
        -- Refresh annotations for any open document
        self.ui.annotation.annotations = settings:readSetting("annotations")
        pcall(self.ui.annotation.updateAnnotations, self.ui.annotation, true, true)
    end

    local after_open
    if after_refresh then
        -- KOReader runs after_open inside ReaderUI:init, before showing the new reader on top of everything.
        after_open = function() UIManager:nextTick(after_refresh) end
    end

    self.ui:reloadDocument(nil, nil, after_open)
end

function Grimmory:onGrimmorySync(verbose, book_path, refresh_book)
    -- Tell everything to flush so we have data available for our sync
    UIManager:broadcastEvent(Event:new("FlushSettings"))

    local function background_callback(run, terminate)
        local ready, refusal_message = self:isReadyToSync()
        if not ready then
            if verbose then
                self.dialog_manager:toast(refusal_message)
            end

            return
        end

        logger:info("Synchronizing to Grimmory")

        local terminated_early = false

        local queue_terminate = function()
            logger:dbg("Terminate requested")
            terminated_early = true
            terminate()
        end

        local update_callback, close_callback
        if verbose then
            update_callback, close_callback = self.dialog_manager:showProgressDialog(
                _("Synchronizing to Grimmory"),
                queue_terminate,
                _("Continue synchronization?")
            )
        end

        local last_progress_step = 0
        local book_download_count = 0
        local summary = GrimmorySyncSummary:new()

        local update_progress_step = function(progress_step)
            if progress_step <= last_progress_step then
                return
            end

            last_progress_step = progress_step

            if update_callback ~= nil then
                pcall(update_callback, progress_step, 10)
            end
        end

        -- In the future, we should limit what we sync
        -- to current or recent books.  For now, we sync everything.

        interrupt_running_sync = queue_terminate

        -- pcall so the shared flag is reset even when the run throws; stuck, it would refuse every later sync.
        local run_ok, ok, result = pcall(
            run,
            function(progress_callback)
                if book_path then
                    self.synchronizer:synchronizeBook(book_path, refresh_book, progress_callback)
                else
                    self.synchronizer:synchronizeAll(progress_callback)
                end
            end,
            function(progress)
                if type(progress) ~= "table" then
                    return
                end

                if progress.state == "book-push-metadata" then
                    local pushed_books = progress.pushed_books or 0
                    local total_books = progress.total_books or 0

                    if total_books == 0 then
                        pushed_books = 1
                        total_books = 1
                    end

                    -- Pushing sessions is 1, 2, and 3
                    update_progress_step(math.floor((pushed_books / total_books) * 3))
                end

                if progress.state:find("^shelf-") ~= nil then
                    -- If we are still seeing shelves we are at step 3
                    -- Because complete with shelves is step 4.
                    update_progress_step(3)
                end

                if (
                    progress.state == "book-downloaded" or
                    progress.state == "book-error" or
                    progress.state == "book-pull-metadata"
                ) then
                    local viewed_books = progress.viewed_books or 0
                    local total_books = progress.total_books or 0

                    if total_books == 0 then
                        viewed_books = 1
                        total_books = 1
                    end

                    -- Step 5, 6, 7, 8, 9 are all pulling books down
                    update_progress_step(4 + math.floor((viewed_books / total_books) * 5))
                end

                summary:record(progress)

                if progress.state == "book-downloaded" then
                    book_download_count = book_download_count + 1

                    if book_download_count % 20 == 0 then
                        -- If we're updating a lot of books we should
                        -- emit a refresh event every once in a while
                        -- so background refresh sees these come
                        -- through quickly
                        UIManager:broadcastEvent(Event:new("RefreshContent"))

                        -- Also refresh collections in this process
                        ReadCollection:_read()
                    end
                end
            end
        )

        interrupt_running_sync = nil

        if not run_ok then
            ok, result = false, ok
        end

        if close_callback then
            pcall(close_callback)
        end

        if not ok then
            if terminated_early then
                logger:info("Sync was interrupted by user")

                if verbose then
                    self.dialog_manager:toast(
                        _("Grimmory synchronization has been interrupted")
                    )
                end
            elseif result == GrimmoryExecutor.NO_CONNECTIVITY then
                logger:err("Cannot sync without connectivity")

                if verbose then
                    self.dialog_manager:toast(
                        _("Failed to Synchronize with Grimmory: No Connectivity")
                    )
                end
            else
                logger:err("Failed sync", result)

                if verbose then
                    self.dialog_manager:toast(
                        _("Failed to Synchronize with Grimmory")
                    )
                end
            end

            return
        end

        -- If we have any books downloaded we need to emit a refresh
        -- event so the file manager knows it should refresh
        UIManager:broadcastEvent(Event:new("RefreshContent"))

        -- Also force refresh collections in this process
        ReadCollection.last_read_time = 0
        ReadCollection:_read()

        if book_path ~= nil then
            logger:info("Invalidating cache for book:", book_path)

            UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", book_path))

            if self.ui and self.ui.file_chooser then
                self.ui.file_chooser.resetBookInfoCache(book_path)
                self.ui.file_chooser:init()
            end
        end

        if verbose then
            local function show_summary()
                if summary:hasDetails() then
                    self.dialog_manager:showSyncSummary(summary:toKeyValuePairs())
                else
                    self.dialog_manager:toast(_("Completed Grimmory sync\nNothing to update"))
                end
            end

            self:refreshUI(book_path, show_summary)
        else
            self:refreshUI(book_path)
        end
    end

    self.executor:background(
        background_callback,
        self.settings:getSyncEnableWifi()
    )
end

return Grimmory