local assert = require 'luassert'
local stub = require 'luassert.stub'

package.path = "grimmory.koplugin/?.lua;" .. package.path

local GrimmoryDatetime = require("grimmory/datetime")

-- 2026-10-18T12:00:00Z
local NOON_UTC = 1792324800

describe("GrimmoryDatetime", function()
    describe("fromIso8601", function()
        local os_time

        -- CI runs in UTC, where a conversion through the device's zone would also pass; this one cannot.
        before_each(function()
            os_time = stub(os, "time", function() error("depends on the device's zone") end)
        end)

        after_each(function()
            os_time:revert()
        end)

        it("reads a time without an offset as UTC", function()
            assert.are.equal(NOON_UTC, GrimmoryDatetime.fromIso8601("2026-10-18T12:00:00"))
        end)

        it("reads the Z suffix and fractional seconds", function()
            assert.are.equal(NOON_UTC, GrimmoryDatetime.fromIso8601("2026-10-18T12:00:00.123456Z"))
        end)

        it("applies an explicit offset", function()
            assert.are.equal(NOON_UTC, GrimmoryDatetime.fromIso8601("2026-10-18T14:00:00+02:00"))
            assert.are.equal(NOON_UTC, GrimmoryDatetime.fromIso8601("2026-10-18T07:00:00-0500"))
        end)

        it("reads a time in a daylight saving gap of the device's zone", function()
            assert.are.equal(1774749600, GrimmoryDatetime.fromIso8601("2026-03-29T02:00:00Z"))
        end)

        it("reads leap days and times before the epoch", function()
            assert.are.equal(1709251199, GrimmoryDatetime.fromIso8601("2024-02-29T23:59:59Z"))
            assert.are.equal(-1, GrimmoryDatetime.fromIso8601("1969-12-31T23:59:59Z"))
        end)

        it("is nil for something that is not a date-time", function()
            assert.is_nil(GrimmoryDatetime.fromIso8601("yesterday"))
            assert.is_nil(GrimmoryDatetime.fromIso8601("2026-10-18T12:00:00+02"))
            assert.is_nil(GrimmoryDatetime.fromIso8601("2026-10-18T12:00:00+02:00[Europe/Paris]"))
        end)
    end)

    describe("toIso8601", function()
        it("writes UTC", function()
            assert.are.equal("2026-10-18T12:00:00Z", GrimmoryDatetime.toIso8601(NOON_UTC))
        end)
    end)

    describe("annotation datetimes", function()
        it("round-trips KOReader's local format", function()
            local datetime = GrimmoryDatetime.toAnnotationDatetime(NOON_UTC)

            assert.are.equal(os.date("%Y-%m-%d %H:%M:%S", NOON_UTC), datetime)
            assert.are.equal(NOON_UTC, GrimmoryDatetime.fromAnnotationDatetime(datetime))
        end)

        it("reads the UTC form earlier plugin versions wrote", function()
            local os_time = stub(os, "time", function() error("depends on the device's zone") end)

            local timestamp = GrimmoryDatetime.fromAnnotationDatetime("2026-10-18 12:00:00Z")

            os_time:revert()
            assert.are.equal(NOON_UTC, timestamp)
        end)

        it("passes a missing time through", function()
            assert.is_nil(GrimmoryDatetime.toAnnotationDatetime(nil))
            assert.is_nil(GrimmoryDatetime.toIso8601(nil))
        end)
    end)
end)
