---Converts between Grimmory's ISO 8601 times and KOReader's local annotation times.
local GrimmoryDatetime = {}

---Computed from the calendar alone: os.time would read the fields in the device's zone, DST gaps included.
---@param fields table date fields as os.time takes them, meant as UTC
---@return number timestamp
local function utc_fields_to_timestamp(fields)
    -- Howard Hinnant's days_from_civil, with years starting in March so leap days come last.
    local year = fields.month <= 2 and fields.year - 1 or fields.year
    local era = math.floor(year / 400)
    local year_of_era = year - era * 400
    local month_from_march = (fields.month + 9) % 12
    local day_of_year = math.floor((153 * month_from_march + 2) / 5) + fields.day - 1
    local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4) - math.floor(year_of_era / 100) + day_of_year
    local days = era * 146097 + day_of_era - 719468

    return days * 86400 + fields.hour * 3600 + fields.min * 60 + fields.sec
end

---@param year string
---@param month string
---@param day string
---@param hour string
---@param min string
---@param sec string
---@return table fields
local function date_fields(year, month, day, hour, min, sec)
    return {
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec),
    }
end

---Times without an offset are read as UTC, the zone Grimmory's container runs in unless TZ is changed.
---@param value string
---@return number | nil timestamp nil when `value` is not an ISO 8601 date-time
function GrimmoryDatetime.fromIso8601(value)
    local year, month, day, hour, min, sec, zone = value:match(
        "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)[%.%d]*(.*)$"
    )

    if year == nil then
        return nil
    end

    local timestamp = utc_fields_to_timestamp(date_fields(year, month, day, hour, min, sec))

    if zone == "" or zone == "Z" then
        return timestamp
    end

    local sign, offset_hours, offset_minutes = zone:match("^([+-])(%d%d):?(%d%d)$")
    if sign == nil then
        return nil
    end

    local offset_seconds = (tonumber(offset_hours) * 60 + tonumber(offset_minutes)) * 60

    if sign == "+" then
        return timestamp - offset_seconds
    end

    return timestamp + offset_seconds
end

---@param timestamp number | nil
---@return string | nil value UTC, like 2026-10-18T12:00:00Z
function GrimmoryDatetime.toIso8601(timestamp)
    if timestamp == nil then
        return nil
    end

    return os.date("!%Y-%m-%dT%H:%M:%SZ", timestamp)
end

---@param timestamp number | nil
---@return string | nil value local time in KOReader's annotation format, like 2026-10-18 14:00:00
function GrimmoryDatetime.toAnnotationDatetime(timestamp)
    if timestamp == nil then
        return nil
    end

    return os.date("%Y-%m-%d %H:%M:%S", timestamp)
end

---Also reads the UTC form with a trailing Z that earlier plugin versions wrote.
---@param value string | nil
---@return number | nil timestamp nil when `value` is not an annotation date-time
function GrimmoryDatetime.fromAnnotationDatetime(value)
    if value == nil then
        return nil
    end

    local year, month, day, hour, min, sec, zone = value:match(
        "^(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)(Z?)$"
    )

    if year == nil then
        return nil
    end

    local fields = date_fields(year, month, day, hour, min, sec)

    if zone == "Z" then
        return utc_fields_to_timestamp(fields)
    end

    return os.time(fields)
end

return GrimmoryDatetime
