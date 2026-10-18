local assert = require 'luassert'

package.path = "grimmory.koplugin/?.lua;" .. package.path

local dkjson = require("dkjson")

package.preload["gettext"] = function()
    return function(text) return text end
end

package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/settings" end }
end

-- Settings files by path, kept across LuaSettings:open calls like files on disk.
local stored_files = {}

package.preload["luasettings"] = function()
    return {
        open = function(_, path)
            stored_files[path] = stored_files[path] or {}
            local data = stored_files[path]

            return {
                readSetting = function(_, key) return data[key] end,
                saveSetting = function(_, key, value) data[key] = value end,
                delSetting = function(_, key) data[key] = nil end,
                flush = function() end,
            }
        end,
    }
end

package.preload["json"] = function()
    return {
        encode = dkjson.encode,
        decode = setmetatable({ simple = {} }, {
            __call = function(_, text) return dkjson.decode(text) end,
        }),
    }
end

package.preload["ltn12"] = function()
    return {
        source = { string = function(text) return text end },
        sink = {
            table = function(chunks)
                return function(chunk)
                    if chunk then
                        table.insert(chunks, chunk)
                    end

                    return 1
                end
            end,
        },
    }
end

local requests = {}
local valid_tokens = {}
local login_count = 0
local refresh_count = 0
local rejects_every_token = false
local rejects_refresh = false

local function fake_request(request)
    table.insert(requests, request.url)

    local code, body

    if request.url:match("/api/v1/auth/login$") then
        login_count = login_count + 1
        local token = "token-" .. login_count
        valid_tokens[token] = true
        code, body = 200, { accessToken = token, refreshToken = "refresh-" .. login_count, expires = 7200 }
    elseif request.url:match("/api/v1/auth/refresh$") and rejects_refresh then
        code, body = 401, { message = "Unauthorized" }
    elseif request.url:match("/api/v1/auth/refresh$") then
        refresh_count = refresh_count + 1
        local token = "refreshed-" .. refresh_count
        valid_tokens[token] = true
        code, body = 200, { accessToken = token, refreshToken = "rotated-" .. refresh_count, expires = 7200 }
    else
        local token = (request.headers["Authorization"] or ""):match("^Bearer (.+)$")
        if not valid_tokens[token] or rejects_every_token then
            code, body = 401, { message = "Unauthorized" }
        else
            code, body = 200, { current = "1.0.0" }
        end
    end

    request.sink(dkjson.encode(body))
    request.sink(nil)

    return 1, code, {}
end

package.preload["socket.http"] = function()
    return { request = fake_request }
end

package.preload["ssl.https"] = function()
    return { request = fake_request }
end

package.preload["grimmory/plugin_metadata"] = function()
    return {
        getVersion = function() return "1.0.0" end,
        getRepository = function() return "grimmory-tools/grimmory.koplugin" end,
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

local GrimmoryAPI = require("grimmory/grimmory_api")

local TOKEN_STORE_PATH = "/settings/grimmory_tokens.lua"

---@return string[] kinds the requests made so far, by the last segment of their path
local function request_kinds()
    local kinds = {}

    for _, url in ipairs(requests) do
        table.insert(kinds, url:match("([%a-]+)[^/]*$"))
    end

    return kinds
end

-- Preloads outlive this file under busted; drop the fake so other specs load the real module.
package.preload["grimmory/plugin_metadata"] = nil

---@param username? string
local function new_api(username)
    return GrimmoryAPI:new({
        settings = {
            getBaseUri = function() return "https://grimmory.example" end,
            getUsername = function() return username or "reader" end,
            getPassword = function() return "secret" end,
            getExtraHeaders = function() return {} end,
        },
    })
end

describe("GrimmoryAPI", function()
    before_each(function()
        stored_files = {}
        requests = {}
        valid_tokens = {}
        login_count = 0
        refresh_count = 0
        rejects_every_token = false
        rejects_refresh = false
    end)

    describe("request", function()
        it("reuses a token from an earlier run instead of logging in again", function()
            assert.is_true((new_api():getServerVersion()))
            assert.is_true((new_api():getServerVersion()))

            assert.are.equal(1, login_count)
        end)

        it("logs in again when the stored token belongs to another account", function()
            new_api("reader"):getServerVersion()
            new_api("someone-else"):getServerVersion()

            assert.are.equal(2, login_count)
        end)

        it("retries once with a fresh login when a stored token was revoked", function()
            new_api():getServerVersion()
            valid_tokens = {}

            local ok, version = new_api():getServerVersion()

            assert.is_true(ok)
            assert.are.equal("1.0.0", version)
            assert.are.same({ "login", "version", "version", "login", "version" }, request_kinds())
        end)

        it("stores the tokens a refresh returns", function()
            stored_files[TOKEN_STORE_PATH] = {
                tokens = {
                    account = "https://grimmory.example\nreader",
                    access_token = "expired",
                    refresh_token = "refresh-0",
                    expiry = 0,
                },
            }

            assert.is_true((new_api():getServerVersion()))

            assert.are.equal(0, login_count)
            assert.are.equal("refreshed-1", stored_files[TOKEN_STORE_PATH].tokens.access_token)
            assert.are.equal("rotated-1", stored_files[TOKEN_STORE_PATH].tokens.refresh_token)
        end)

        -- Each file would be used if its missing field went unchecked: the expired one refreshed, the others sent.
        for _, case in ipairs({
            { missing = "access_token", expiry = 0 },
            { missing = "refresh_token", expiry = os.time() + 3600 },
            { missing = "expiry", expiry = os.time() + 3600 },
        }) do
            it("ignores a stored token without its " .. case.missing, function()
                valid_tokens["stored"] = true
                local tokens = {
                    account = "https://grimmory.example\nreader",
                    access_token = "stored",
                    refresh_token = "refresh-0",
                    expiry = case.expiry,
                }
                tokens[case.missing] = nil
                stored_files[TOKEN_STORE_PATH] = { tokens = tokens }

                assert.is_true((new_api():getServerVersion()))
                assert.are.same({ "login", "version" }, request_kinds())
            end)
        end

        it("logs in again once the stored tokens are forgotten", function()
            local api = new_api()
            api:getServerVersion()

            api:forgetStoredTokens()

            assert.is_nil(stored_files[TOKEN_STORE_PATH].tokens)
            assert.is_true((api:getServerVersion()))
            assert.are.equal(2, login_count)
        end)

        it("does not retry the token a login returns after a failed refresh", function()
            stored_files[TOKEN_STORE_PATH] = {
                tokens = {
                    account = "https://grimmory.example\nreader",
                    access_token = "expired",
                    refresh_token = "revoked",
                    expiry = 0,
                },
            }
            rejects_refresh = true
            rejects_every_token = true

            local ok = new_api():getServerVersion()

            assert.is_false(ok)
            assert.are.same({ "refresh", "login", "version" }, request_kinds())
        end)

        it("does not replay a download rejected for its stored token", function()
            new_api():getServerVersion()
            valid_tokens = {}

            local ok = new_api():request("GET", "/api/v1/books/1/download", nil, nil, function() return 1 end)

            assert.is_false(ok)
            assert.are.equal(1, login_count)
            assert.is_nil(stored_files[TOKEN_STORE_PATH].tokens)
        end)

        it("does not retry a fresh token the server rejects", function()
            rejects_every_token = true

            local ok = new_api():getServerVersion()

            assert.is_false(ok)
            assert.are.same({ "login", "version" }, request_kinds())
        end)

        it("gives up after one retry", function()
            new_api():getServerVersion()

            rejects_every_token = true

            local ok = new_api():getServerVersion()

            assert.is_false(ok)
            assert.are.equal(2, login_count)
        end)
    end)
end)
