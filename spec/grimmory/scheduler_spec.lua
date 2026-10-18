local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

local scheduled_tasks = {}

package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, _, action, ...)
            table.insert(scheduled_tasks, { action = action, args = { ... } })
        end,
        unschedule = function(_, action)
            for index = #scheduled_tasks, 1, -1 do
                if scheduled_tasks[index].action == action then
                    table.remove(scheduled_tasks, index)
                end
            end
        end,
    }
end

local uuid_counter = 0

package.preload["random"] = function()
    return {
        uuid = function()
            uuid_counter = uuid_counter + 1
            return "uuid-" .. uuid_counter
        end,
    }
end

package.preload["grimmory/logger"] = function()
    local quiet = function() end

    return {
        new = function()
            return { err = quiet, warn = quiet, info = quiet, dbg = quiet }
        end
    }
end

local GrimmoryScheduler = require("grimmory/scheduler")

-- CI runs busted on Lua 5.4, which has no global unpack.
local unpack_args = table.unpack or unpack

local function run_due_tasks()
    local due_tasks = scheduled_tasks
    scheduled_tasks = {}

    for _, task in ipairs(due_tasks) do
        task.action(unpack_args(task.args))
    end
end

describe("GrimmoryScheduler", function()
    before_each(function()
        scheduled_tasks = {}
    end)

    it("keeps firing an interval until it is cleared", function()
        local scheduler = GrimmoryScheduler:new()
        local fired = 0

        scheduler:interval(60, function() fired = fired + 1 end)

        run_due_tasks()
        run_due_tasks()
        scheduler:clear()
        run_due_tasks()

        assert.are.equal(2, fired)
    end)

    it("leaves another scheduler's intervals running when one is cleared", function()
        local closed_scheduler = GrimmoryScheduler:new()
        local live_scheduler = GrimmoryScheduler:new()
        local closed_fired, live_fired = 0, 0

        closed_scheduler:interval(60, function() closed_fired = closed_fired + 1 end)
        live_scheduler:interval(60, function() live_fired = live_fired + 1 end)

        closed_scheduler:clear()
        run_due_tasks()

        assert.are.equal(0, closed_fired)
        assert.are.equal(1, live_fired)
    end)
end)
