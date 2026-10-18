local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

local installed_version = "1.4.0"

package.preload["gettext"] = function()
    return function(text) return text end
end

package.preload["ffi/util"] = function()
    return { template = function(text) return text end }
end

package.preload["ffi/archiver"] = function()
    return {}
end

package.preload["datastorage"] = function()
    return { getDataDir = function() return "/data" end }
end

package.preload["ui/network/manager"] = function()
    return {}
end

package.preload["util"] = function()
    return {}
end

package.preload["ffi/sha2"] = function()
    return {}
end

package.preload["grimmory/plugin_metadata"] = function()
    return {
        getPluginPath = function() return "/plugins/grimmory.koplugin" end,
        getVersion = function() return installed_version end,
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

local GrimmorySelfUpdater = require("grimmory/ota/self_updater")

-- Preloads outlive this file under busted; drop the fake so plugin_metadata_spec loads the real module.
package.preload["grimmory/plugin_metadata"] = nil

---@param installed string
---@param latest string
local function is_update_available(installed, latest)
    installed_version = installed

    return GrimmorySelfUpdater:new({ latest_known_version = latest }):isUpdateAvailable()
end

describe("GrimmorySelfUpdater", function()
    describe("isUpdateAvailable", function()
        it("offers a newer patch, minor or major release", function()
            assert.is_true(is_update_available("1.4.0", "v1.4.1"))
            assert.is_true(is_update_available("1.4.9", "v1.5.0"))
            assert.is_true(is_update_available("1.9.9", "v2.0.0"))
        end)

        it("does not offer an older release", function()
            assert.is_false(is_update_available("1.4.0", "v1.3.9"))
            assert.is_false(is_update_available("2.0.0", "v1.5.0"))
        end)

        it("does not offer the installed release", function()
            assert.is_false(is_update_available("1.4.0", "v1.4.0"))
        end)

        it("offers the release of an installed prerelease", function()
            assert.is_true(is_update_available("1.4.0-beta", "v1.4.0"))
            assert.is_true(is_update_available("0.0.0-snapshot", "v1.0.0"))
        end)

        it("does not offer a prerelease of the installed release", function()
            assert.is_false(is_update_available("1.4.0", "v1.4.0-beta"))
        end)

        it("ranks prereleases by their dot-separated identifiers", function()
            assert.is_true(is_update_available("1.0.0-alpha", "v1.0.0-beta"))
            assert.is_true(is_update_available("1.0.0-rc.9", "v1.0.0-rc.10"))
            assert.is_false(is_update_available("1.0.0-rc.10", "v1.0.0-rc.9"))
            assert.is_true(is_update_available("1.0.0-alpha", "v1.0.0-alpha.1"))
            assert.is_true(is_update_available("1.0.0-alpha.1", "v1.0.0-alpha.beta"))
            assert.is_false(is_update_available("1.0.0-alpha.beta", "v1.0.0-alpha.1"))
        end)
    end)
end)
