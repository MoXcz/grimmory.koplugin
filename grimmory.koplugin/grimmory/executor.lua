local _ = require("gettext")
local ffiutil = require("ffi/util")
local ffi = require("ffi")
local json = require("json")
local Device = require("device")
local NetworkManager = require("ui/network/manager")
local UIManager = require("ui/uimanager")

local GrimmoryLogger = require("grimmory/logger")
local GrimmoryMessageReader = require("grimmory/message_reader")

local logger = GrimmoryLogger:new()

---@return string | nil chunk the bytes waiting on `fd`, or nil when there are none
local function readAvailable(fd)
    local available = ffiutil.getNonBlockingReadSize(fd)
    if available == 0 then
        return nil
    end

    -- nil means the size is unknown, so read a chunk like KOReader does.
    available = available or 4096

    local chunk = ffi.new("char[?]", available)
    local bytes_read = tonumber(ffi.C.read(fd, chunk, available))

    if bytes_read < 0 then
        logger:err("Failed reading from subprocess:", ffi.string(ffi.C.strerror(ffi.errno())))
        return nil
    end

    if bytes_read == 0 then
        return nil
    end

    return ffi.string(chunk, bytes_read)
end

local function writeToFD(fd, data)
    local size = #data
    local ptr = ffi.cast("uint8_t *", data)

    ffi.C.write(fd, ptr, size)
    ffi.C.fdatasync(fd)
end

local function writeObjectToFD(fd, obj)
    -- Encode with JSON so we can delineate "entries" with null bytes.
    local ok, str = pcall(json.encode, obj)

    if not ok then
        logger:err("Could not serialize progress state from subprocess:", str)
        return false, str
    end

    local write_ok, write_result = pcall(writeToFD, fd, str .. "\0")

    if not write_ok then
        logger:err("Could not write progress state back from subprocess:", write_result)
        return false, write_result
    end

    return true, nil
end

---@class GrimmoryExecutor
---@field private running_subprocesses any[]
local GrimmoryExecutor = {
    -- Returned as the result when there is no network, so callers can tell it from a failed run.
    NO_CONNECTIVITY = _("No network connection"),
}

function GrimmoryExecutor:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function GrimmoryExecutor:init()
    self.running_subprocesses = self.running_subprocesses or {}
end

function GrimmoryExecutor:clear()
    while true do
        local subprocess_pid = table.remove(self.running_subprocesses)

        if not subprocess_pid then
            break
        end

        ffiutil.terminateSubProcess(subprocess_pid)
    end
end

local function wrap_coroutine(func)
    -- Catch and log any error happening in func (an error happening
    -- in a coroutine just aborts silently the coroutine)
    local pcalled_func = function()
        -- we use xpcall as it can give a whole stacktrace, unlike pcall
        local ok, err = xpcall(func, debug.traceback)

        if not ok then
            logger:warn("error in wrapped function:", err)
            return false
        end
        return true
        -- As a coroutine, we will return at first coroutine.yield(),
        -- and the above true/false won't probably be caught by
        -- any code, but let's do it anyway.
    end
    local co = coroutine.create(pcalled_func)
    return coroutine.resume(co)
end

---@return boolean connected true as well when the check itself fails, so a broken check never blocks a sync
local function is_connected()
    local ok, connected = pcall(NetworkManager.isConnected, NetworkManager)

    if not ok then
        logger:err("Something went wrong checking wifi connectivity", connected)
        return true
    end

    return connected
end

---@return boolean wifi_on false as well when the check itself fails
local function is_wifi_on()
    local ok, wifi_on = pcall(NetworkManager.isWifiOn, NetworkManager)

    if not ok then
        logger:err("Something went wrong checking wifi state", wifi_on)
        return false
    end

    return wifi_on
end

---"Restore Wi-Fi on resume" reads wifi_was_on, which KOReader rewrites when WiFi comes up or a turn-on fails.
---@param wifi_was_on boolean
local function restore_wifi_was_on(wifi_was_on)
    NetworkManager.wifi_was_on = wifi_was_on

    local koreader_settings = _G.G_reader_settings
    if koreader_settings then
        if wifi_was_on then
            koreader_settings:makeTrue("wifi_was_on")
        else
            koreader_settings:makeFalse("wifi_was_on")
        end
    end
end

---@return boolean wifi_was_enabled true when this call turned WiFi on, so it should be turned off afterwards
---@return boolean wifi_was_on KOReader's wifi_was_on from before the turn-on, to restore afterwards
local function enable_wifi(timeout)
    if timeout == nil then
        timeout = 45
    end

    if is_wifi_on() and is_connected() then
        logger:dbg("WiFi is already Active")
        return false
    end

    -- Android can only open its WiFi settings, which no background sync should pop up.
    if not Device:hasSeamlessWifiToggle() then
        logger:err("Requested with wifi but cannot enable")
        return false
    end

    local running_coroutine = coroutine.running()

    local check_connectivity
    check_connectivity = function(iteration)
        if iteration > timeout * 4 then
            logger:dbg("Aborted connection check waiting")
            coroutine.resume(running_coroutine)
            return
        end

        if not is_connected() then
            UIManager:scheduleIn(0.25, check_connectivity, iteration + 1)
        else
            logger:dbg("Connection succesful")
            coroutine.resume(running_coroutine)
        end
    end

    logger:dbg("Connecting to WiFi")

    local wifi_was_enabled = false
    local wifi_was_on = NetworkManager.wifi_was_on == true

    if not is_wifi_on() then
        -- requestToTurnOnWifi alone leaves NetworkMgr.pending_connection set; enableWifi schedules the check
        -- that clears it.
        local ok, result = pcall(NetworkManager.enableWifi, NetworkManager)

        if not ok or result == false then
            logger:err("Failed to turn on wifi", result)

            if not ok then
                -- It may have marked a connection as pending before it threw.
                pcall(NetworkManager.disableWifi, NetworkManager)
            end

            restore_wifi_was_on(wifi_was_on)
            return false, wifi_was_on
        end

        -- nil means another attempt is already pending: wait for it, but leave WiFi to whoever started it.
        wifi_was_enabled = result == true
    end

    UIManager:scheduleIn(0.25, check_connectivity, 0)
    logger:dbg("Waiting...")
    coroutine.yield()

    logger:dbg("Continuing after wifi")
    return wifi_was_enabled, wifi_was_on
end

-- Shared by every executor: runs overlap (a progress pull and a sync), so WiFi turned on
-- for one of them stays up until the last run that uses the network ends.
local network_runs = 0
local is_wifi_ours = false
local wifi_was_on_before = false

---@param with_wifi boolean turn WiFi on when it is off
local function acquire_network(with_wifi)
    network_runs = network_runs + 1

    if with_wifi and not is_wifi_ours then
        logger:dbg("Execution requested WiFi")

        local wifi_was_enabled, wifi_was_on = enable_wifi()

        if wifi_was_enabled then
            is_wifi_ours = true
            wifi_was_on_before = wifi_was_on
        end
    end
end

local function release_network()
    network_runs = network_runs - 1

    if network_runs > 0 or not is_wifi_ours then
        return
    end

    is_wifi_ours = false

    logger:dbg("Disabling WiFi after execution")

    local ok, err = pcall(NetworkManager.disableWifi, NetworkManager)
    if not ok then
        logger:err("Failed to turn off wifi", err)
    end

    restore_wifi_was_on(wifi_was_on_before)
end

---@alias GrimmoryRunnableProgressCallback function(state: any, terminate: function): bool
---@alias GrimmoryRunnable function(callback: BackgroundRunnableProgressCallback)
---@alias GrimmoryBackgroundStart function(runnable: GrimmoryRunnable, progress: GrimmoryRunnableProgressCallback)

---@param callback function(run_in_background: GrimmoryBackgroundStart)
---@param with_wifi bool
---@return boolean ok
---@return any result
function GrimmoryExecutor:background(callback, with_wifi)
    return wrap_coroutine(function()
        local subprocess_pid = nil
        local was_terminated = false

        local terminate = function()
            -- runInSubProcess returns false when the fork fails.
            if subprocess_pid then
                ffiutil.terminateSubProcess(subprocess_pid)
            end

            was_terminated = true
        end

        local function run_in_background(runnable, on_progress)
            UIManager:preventStandby()
            acquire_network(with_wifi)

            local function finish(ok, result)
                UIManager:allowStandby()
                release_network()

                return ok, result
            end

            if was_terminated then
                return finish(false, "Terminated before starting subprocess")
            end

            -- Checked here in the parent: NetworkManager aborts Android builds when called from the subprocess.
            if not is_connected() then
                logger:err("Cannot run without connectivity")
                return finish(false, GrimmoryExecutor.NO_CONNECTIVITY)
            end

            local running_coroutine = coroutine.running()

            local new_subprocess_pid, read_fd_or_error = ffiutil.runInSubProcess(
                function(my_pid, child_write_fd)
                    ---@type GrimmoryRunnableProgressCallback
                    local function progress_callback(state)
                        local write_ok, write_result = writeObjectToFD(child_write_fd, state)

                        if not write_ok then
                            logger:err("Could not write progress state back from subprocess:", write_result)
                        end

                        return true
                    end

                    local runnable_ok, runnable_result = pcall(runnable, progress_callback)

                    local runnable_state = {
                        __runnable_ok = runnable_ok,
                        __runnable_result = runnable_result,
                    }

                    local write_ok, write_result = writeObjectToFD(child_write_fd, runnable_state)

                    if not write_ok then
                        logger:err("Could not write final state back from subprocess:", write_result)
                    end

                    -- Close the handle manually.
                    pcall(ffi.C.close, child_write_fd)

                    -- Kill the subprocess because nothing else seems to stop
                    -- it when we are using the `runInSubProcess` helper.
                    ffi.C.kill(my_pid, 9)
                end,
                true
            )

            subprocess_pid = new_subprocess_pid

            local subprocess_ok = false
            local subprocess_result = nil

            if subprocess_pid then
                local parent_read_fd = read_fd_or_error
                local has_final_state = false

                table.insert(self.running_subprocesses, subprocess_pid)

                local reader = GrimmoryMessageReader:new({
                    read_chunk = function() return readAvailable(parent_read_fd) end,
                })

                while true do
                    -- Checked before reading: once the child has exited, all it wrote is already in the pipe.
                    local is_subprocess_done = ffiutil.isSubProcessDone(subprocess_pid)
                    local messages_received = 0

                    local message = reader:next()
                    while message do
                        local decode_ok, state = pcall(json.decode, message)
                        if decode_ok then
                            if type(state) == "table" and state.__runnable_ok ~= nil then
                                has_final_state = true
                                subprocess_ok = state.__runnable_ok
                                subprocess_result = state.__runnable_result
                            else
                                pcall(on_progress, state)
                            end
                        else
                            logger:err("Failed to decode state data received from subprocess:", state)
                        end

                        messages_received = messages_received + 1

                        if messages_received >= 100 then
                            -- Hand back to the UI so a chatty subprocess cannot freeze it.
                            break
                        end

                        message = reader:next()
                    end

                    if is_subprocess_done and messages_received == 0 then
                        break
                    end

                    pcall(on_progress, nil)

                    local continue_func = function() coroutine.resume(running_coroutine) end
                    UIManager:scheduleIn(0.1, continue_func)

                    coroutine.yield()
                end

                ffi.C.close(parent_read_fd)

                if not has_final_state then
                    logger:err("Subprocess ended without reporting a result")
                    subprocess_result = "Subprocess ended without reporting a result"
                end

                for i, running_subprocess_id in ipairs(self.running_subprocesses) do
                    if running_subprocess_id == subprocess_pid then
                        table.remove(self.running_subprocesses, i)
                        break
                    end
                end
            else
                logger:err("Could not start subprocess:", read_fd_or_error)
                subprocess_result = read_fd_or_error
            end

            return finish(subprocess_ok, subprocess_result)
        end

        callback(run_in_background, terminate)
    end)
end


return GrimmoryExecutor