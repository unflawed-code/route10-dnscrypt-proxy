local tinytoml = {}

local TOML_VERSION = "1.1.0"
tinytoml._VERSION = "tinytoml 1.0.0"
tinytoml._TOML_VERSION = TOML_VERSION
tinytoml._DESCRIPTION = "a single-file pure Lua TOML parser"
tinytoml._URL = "https://github.com/FourierTransformer/tinytoml"
tinytoml._LICENSE = "MIT"

local sbyte = string.byte
local chars = {
   SINGLE_QUOTE = sbyte("'"),
   DOUBLE_QUOTE = sbyte('"'),
   OPEN_BRACKET = sbyte("["),
   CLOSE_BRACKET = sbyte("]"),
   BACKSLASH = sbyte("\\"),
   COMMA = sbyte(","),
   POUND = sbyte("#"),
   DOT = sbyte("."),
   CR = sbyte("\r"),
   LF = sbyte("\n"),
   EQUAL = sbyte("="),
   OPEN_BRACE = sbyte("{"),
   CLOSE_BRACE = sbyte("}"),
}

local function replace_control_chars(s)
   return string.gsub(s, "[%z\001-\008\011-\031\127]", function(c)
      return string.format("\\x%02x", string.byte(c))
   end)
end

local function _error(sm, message, anchor)
   local error_message = {}

   if sm.filename then
      error_message = { "\n\nIn '", sm.filename, "', line ", sm.line_number, ":\n\n  " }

      local _, end_line = sm.input:find(".-\n", sm.line_number_char_index)
      error_message[#error_message + 1] = sm.line_number
      error_message[#error_message + 1] = " | "
      error_message[#error_message + 1] = replace_control_chars(sm.input:sub(sm.line_number_char_index, end_line))
      error_message[#error_message + 1] = (end_line and "\n" or "\n\n")
   end

   error_message[#error_message + 1] = message
   error_message[#error_message + 1] = "\n"

   if anchor ~= nil then
      error_message[#error_message + 1] = "\nSee https://toml.io/en/v"
      error_message[#error_message + 1] = TOML_VERSION
      error_message[#error_message + 1] = "#"
      error_message[#error_message + 1] = anchor
      error_message[#error_message + 1] = " for more details"
   end

   error(table.concat(error_message))
end

local _unpack = unpack or table.unpack
local _tointeger = math.tointeger or tonumber

local _utf8char = utf8 and utf8.char or function(cp)
   if cp < 128 then
      return string.char(cp)
   end
   local suffix = cp % 64
   local c4 = 128 + suffix
   cp = (cp - suffix) / 64
   if cp < 32 then
      return string.char(192 + (cp), (c4))
   end
   suffix = cp % 64
   local c3 = 128 + suffix
   cp = (cp - suffix) / 64
   if cp < 16 then
      return string.char(224 + (cp), c3, c4)
   end
   suffix = cp % 64
   cp = (cp - suffix) / 64
   return string.char(240 + (cp), 128 + (suffix), c3, c4)
end

local function validate_utf8(input, toml_sub)
   local i, len, line_number, line_number_start = 1, #input, 1, 1
   local byte, second, third, fourth = 0, 129, 129, 129
   toml_sub = toml_sub or false
   while i <= len do
      byte = sbyte(input, i)

      if byte <= 127 then
         if toml_sub then
            if byte < 9 then return false, line_number, line_number_start, "TOML only allows some control characters, but they must be escaped in double quoted strings"
            elseif byte == chars.CR and sbyte(input, i + 1) ~= chars.LF then return false, line_number, line_number_start, "TOML requires all '\\r' be followed by '\\n'"
            elseif byte == chars.LF then
               line_number = line_number + 1
               line_number_start = i + 1
            elseif byte >= 11 and byte <= 31 and byte ~= 13 then return false, line_number, line_number_start, "TOML only allows some control characters, but they must be escaped in double quoted strings"
            elseif byte == 127 then return false, line_number, line_number_start, "TOML only allows some control characters, but they must be escaped in double quoted strings" end
         end
         i = i + 1

      elseif byte >= 194 and byte <= 223 then
         second = sbyte(input, i + 1)
         i = i + 2

      elseif byte == 224 then
         second = sbyte(input, i + 1); third = sbyte(input, i + 2)

         if second ~= nil and second >= 128 and second <= 159 then return false, line_number, line_number_start, "Invalid UTF-8 Sequence" end
         i = i + 3

      elseif byte == 237 then
         second = sbyte(input, i + 1); third = sbyte(input, i + 2)

         if second ~= nil and second >= 160 and second <= 191 then return false, line_number, line_number_start, "Invalid UTF-8 Sequence" end
         i = i + 3

      elseif (byte >= 225 and byte <= 236) or byte == 238 or byte == 239 then
         second = sbyte(input, i + 1); third = sbyte(input, i + 2)
         i = i + 3
      elseif byte == 240 then
         second = sbyte(input, i + 1); third = sbyte(input, i + 2); fourth = sbyte(input, i + 3)

         if second ~= nil and second >= 128 and second <= 143 then return false, line_number, line_number_start, "Invalid UTF-8 Sequence" end
         i = i + 4

      elseif byte == 241 or byte == 242 or byte == 243 then
         second = sbyte(input, i + 1); third = sbyte(input, i + 2); fourth = sbyte(input, i + 3)
         i = i + 4

      elseif byte == 244 then
         second = sbyte(input, i + 1); third = sbyte(input, i + 2); fourth = sbyte(input, i + 3)

         if second ~= nil and second >= 160 and second <= 191 then return false, line_number, line_number_start, "Invalid UTF-8 Sequence" end
         i = i + 4

      else
         return false, line_number, line_number_start, "Invalid UTF-8 Sequence"
      end

      if second == nil or second < 128 or second > 191 then return false, line_number, line_number_start, "Invalid UTF-8 Sequence" end
      if third == nil or third < 128 or third > 191 then return false, line_number, line_number_start, "Invalid UTF-8 Sequence" end
      if fourth == nil or fourth < 128 or fourth > 191 then return false, line_number, line_number_start, "Invalid UTF-8 Sequence" end
   end
   return true
end

local function find_newline(sm)
   sm._, sm.end_seq = sm.input:find("\r?\n", sm.i)

   if sm.end_seq == nil then
      sm._, sm.end_seq = sm.input:find(".-$", sm.i)
   end
   sm.line_number = sm.line_number + 1
   sm.i = sm.end_seq + 1
   sm.line_number_char_index = sm.i
end

local escape_sequences = {
   ['b'] = '\b',
   ['t'] = '\t',
   ['n'] = '\n',
   ['f'] = '\f',
   ['r'] = '\r',
   ['e'] = '\027',
   ['\\'] = '\\',
   ['"'] = '"',
}

local function handle_backslash_escape(sm)
   if sm.multiline_string then
      if sm.input:find("^\\\\[ \t]-\r?\n", sm.i) then
         sm._, sm.end_seq = sm.input:find("%S", sm.i + 1)
         sm.i = sm.end_seq - 1
         return "", false
      end
   end

   sm._, sm.end_seq, sm.match = sm.input:find('^([\\btrfne"])', sm.i + 1)
   local escape = escape_sequences[sm.match]
   if escape then
      sm.i = sm.end_seq
      if sm.match == '"' then
         return escape, true
      else
         return escape, false
      end
   end

   sm._, sm.end_seq, sm.match, sm.ext = sm.input:find("^(x)([0-9a-fA-F][0-9a-fA-F])", sm.i + 1)
   if sm.match then
      local codepoint_to_insert = _utf8char(tonumber(sm.ext, 16))
      if not validate_utf8(codepoint_to_insert) then
         _error(sm, "Escaped UTF-8 sequence not valid UTF-8 character: '\\" .. sm.match .. sm.ext .. "'", "string")
      end
      sm.i = sm.end_seq
      return codepoint_to_insert, false
   end

   sm._, sm.end_seq, sm.match, sm.ext = sm.input:find("^(u)([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])", sm.i + 1)
   if not sm.match then
      sm._, sm.end_seq, sm.match, sm.ext = sm.input:find("^(U)([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])", sm.i + 1)
   end
   if sm.match then
      local codepoint_to_insert = _utf8char(tonumber(sm.ext, 16))
      if not validate_utf8(codepoint_to_insert) then
         _error(sm, "Escaped UTF-8 sequence not valid UTF-8 character: '\\" .. sm.match .. sm.ext .. "'", "string")
      end
      sm.i = sm.end_seq
      return codepoint_to_insert, false
   end

   return nil
end

local function close_string(sm)
   local escape
   local reset_quote
   local start_field, end_field = sm.i + 1, 0
   local second, third = sbyte(sm.input, sm.i + 1), sbyte(sm.input, sm.i + 2)
   local quote_count = 0
   local output = {}
   local found_closing_quote = false
   sm.multiline_string = false

   if second == chars.DOUBLE_QUOTE and third == chars.DOUBLE_QUOTE then
      if sm.mode == "table" then _error(sm, "Cannot have multiline strings as table keys", "table") end
      sm.multiline_string = true
      start_field = sm.i + 3

      second, third = sbyte(sm.input, sm.i + 3), sbyte(sm.input, sm.i + 4)
      if second == chars.LF then
         start_field = start_field + 1
      elseif second == chars.CR and third == chars.LF then
         start_field = start_field + 2
      end
      sm.i = start_field - 1
   end

   while found_closing_quote == false and sm.i <= sm.input_length do
      sm.i = sm.i + 1
      sm.byte = sbyte(sm.input, sm.i)
      if sm.byte == chars.BACKSLASH then
         output[#output + 1] = sm.input:sub(start_field, sm.i - 1)
         escape, reset_quote = handle_backslash_escape(sm)
         if reset_quote then quote_count = 0 end

         if escape ~= nil then
            output[#output + 1] = escape
         else
            sm._, sm._, sm.match = sm.input:find("(.-[^'\"])", sm.i + 1)
            _error(sm, "TOML only allows specific escape sequences. Invalid escape sequence found: '\\" .. sm.match .. "'", "string")
         end

         start_field = sm.i + 1

      elseif sm.multiline_string then
         if sm.byte == chars.DOUBLE_QUOTE then
            quote_count = quote_count + 1
            if quote_count == 5 then
               end_field = sm.i - 3
               output[#output + 1] = sm.input:sub(start_field, end_field)
               found_closing_quote = true
               break
            end
         else
            if quote_count >= 3 then
               end_field = sm.i - 4
               output[#output + 1] = sm.input:sub(start_field, end_field)
               found_closing_quote = true
               sm.i = sm.i - 1
               break
            else
               quote_count = 0
            end
         end

      else
         if sm.byte == chars.DOUBLE_QUOTE then
            end_field = sm.i - 1
            output[#output + 1] = sm.input:sub(start_field, end_field)
            found_closing_quote = true
            break
         elseif sm.byte == chars.CR or sm.byte == chars.LF then
            _error(sm, "String does not appear to be closed. Use multi-line (triple quoted) strings if non-escaped newlines are desired.", "string")
         end
      end
   end

   if not found_closing_quote then
      if sm.multiline_string then
         _error(sm, "Unable to find closing triple-quotes for multi-line string", "string")
      else
         _error(sm, "Unable to find closing quote for string", "string")
      end
   end

   sm.i = sm.i + 1
   sm.value = table.concat(output)
   sm.value_type = "string"
end

local function close_literal_string(sm)
   sm.byte = 0
   local start_field, end_field = sm.i + 1, 0
   local second, third = sbyte(sm.input, sm.i + 1), sbyte(sm.input, sm.i + 2)
   local quote_count = 0
   sm.multiline_string = false

   if second == chars.SINGLE_QUOTE and third == chars.SINGLE_QUOTE then
      if sm.mode == "table" then _error(sm, "Cannot have multiline strings as table keys", "table") end
      sm.multiline_string = true
      start_field = sm.i + 3

      second, third = sbyte(sm.input, sm.i + 3), sbyte(sm.input, sm.i + 4)
      if second == chars.LF then
         start_field = start_field + 1
      elseif second == chars.CR and third == chars.LF then
         start_field = start_field + 2
      end
      sm.i = start_field
   end

   while end_field ~= 0 or sm.i <= sm.input_length do
      sm.i = sm.i + 1
      sm.byte = sbyte(sm.input, sm.i)
      if sm.multiline_string then
         if sm.byte == chars.SINGLE_QUOTE then
            quote_count = quote_count + 1
            if quote_count == 5 then
               end_field = sm.i - 3
               break
            end
         else
            if quote_count >= 3 then
               end_field = sm.i - 4
               sm.i = sm.i - 1
               break
            else
               quote_count = 0
            end
         end

      else
         if sm.byte == chars.SINGLE_QUOTE then
            end_field = sm.i - 1
            break
         elseif sm.byte == chars.CR or sm.byte == chars.LF then
            _error(sm, "String does not appear to be closed. Use multi-line (triple quoted) strings if non-escaped newlines are desired.", "string")
         end
      end
   end

   if end_field == 0 then
      if sm.multiline_string then
         _error(sm, "Unable to find closing triple quotes for multi-line literal string", "string")
      else
         _error(sm, "Unable to find closing quote for literal string", "string")
      end
   end

   sm.i = sm.i + 1
   sm.value = sm.input:sub(start_field, end_field)
   sm.value_type = "string"
end

local function close_bare_string(sm)
   sm._, sm.end_seq, sm.match = sm.input:find("^([a-zA-Z0-9-_]+)", sm.i)
   if sm.match then
      sm.i = sm.end_seq + 1
      sm.multiline_string = false
      sm.value = sm.match
      sm.value_type = "string"
   else
      _error(sm, "Bare keys can only contain 'a-zA-Z0-9-_'. Invalid bare key found: " .. sm.input:sub(sm.i, sm.i), "keys")
   end
end

local function remove_underscores_number(sm, number, anchor)
   if number:find("_") then
      if number:find("__") then _error(sm, "Numbers cannot have consecutive underscores. Found " .. anchor .. ": '" .. number .. "'", anchor) end
      if number:find("^_") or number:find("_$") then _error(sm, "Underscores are not allowed at beginning or end of a number. Found " .. anchor .. ": '" .. number .. "'", anchor) end
      if number:find("%D_%d") or number:find("%d_%D") then _error(sm, "Underscores must have digits on either side. Found " .. anchor .. ": '" .. number .. "'", anchor) end
      number = number:gsub("_", "")
   end
   return number
end

local integer_match = {
   ["b"] = { "^0b([01_]+)$", 2 },
   ["o"] = { "^0o([0-7_]+)$", 8 },
   ["x"] = { "^0x([0-9a-fA-F_]+)$", 16 },
}

local function validate_integer(sm, value)
   sm._, sm._, sm.match = value:find("^([-+]?[%d_]+)$")
   if sm.match then
      if sm.match:find("^[-+]?0[%d_]") then _error(sm, "Integers can't start with a leading 0. Found integer: '" .. sm.match .. "'", "integer") end
      sm.match = remove_underscores_number(sm, sm.match, "integer")
      sm.value = _tointeger(sm.match)
      sm.value_type = "integer"
      return true
   end

   if value:find("^0[box]") then
      local pattern_bits = integer_match[value:sub(2, 2)]
      sm._, sm._, sm.match = value:find(pattern_bits[1])
      if sm.match then
         sm.match = remove_underscores_number(sm, sm.match, "integer")
         sm.value = tonumber(sm.match, pattern_bits[2])
         sm.value_type = "integer"
         return true
      end
   end
end

local function validate_float(sm, value)
   sm._, sm._, sm.match, sm.ext = value:find("^([-+]?[%d_]+%.[%d_]+)(.*)$")
   if sm.match then
      if sm.match:find("%._") or sm.match:find("_%.") then _error(sm, "Underscores in floats must have a number on either side. Found float: '" .. sm.match .. sm.ext .. "'", "float") end
      if sm.match:find("^[-+]?0[%d_]") then _error(sm, "Floats can't start with a leading 0. Found float: '" .. sm.match .. sm.ext .. "'", "float") end
      sm.match = remove_underscores_number(sm, sm.match, "float")
      if sm.ext ~= "" then
         if sm.ext:find("^[eE][-+]?[%d_]+$") then
            sm.ext = remove_underscores_number(sm, sm.ext, "float")
            sm.value = tonumber(sm.match .. sm.ext)
            sm.value_type = "float"
            return true
         end
      else
         sm.value = tonumber(sm.match)
         sm.value_type = "float"
         return true
      end
   end

   sm._, sm._, sm.match = value:find("^([-+]?[%d_]+[eE][-+]?[%d_]+)$")
   if sm.match then
      if sm.match:find("_[eE]") or sm.match:find("[eE]_") then _error(sm, "Underscores in floats cannot be before or after the e. Found float: '" .. sm.match .. sm.ext .. "'", "float") end
      sm.match = remove_underscores_number(sm, sm.match, "float")
      sm.value = tonumber(sm.match)
      sm.value_type = "float"
      return true
   end
end

local max_days_in_month = { 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local function validate_seconds(sm, sec, anchor)
   if sec > 60 then _error(sm, "Seconds must be less than 61. Found second: " .. sec .. " in: '" .. sm.match .. "'", anchor) end
end

local function validate_hours_minutes(sm, hour, min, anchor)
   if hour > 23 then _error(sm, "Hours must be less than 24. Found hour: " .. hour .. " in: '" .. sm.match .. "'", anchor) end
   if min > 59 then _error(sm, "Minutes must be less than 60. Found minute: " .. min .. " in: '" .. sm.match .. "'", anchor) end
end

local function validate_month_date(sm, year, month, day, anchor)
   if month == 0 or month > 12 then _error(sm, "Month must be between 01-12. Found month: " .. month .. " in: '" .. sm.match .. "'", anchor) end
   if day == 0 or day > max_days_in_month[month] then
      local months = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }
      _error(sm, "Too many days in the month. Found " .. day .. " days in " .. months[month] .. ", which only has " .. max_days_in_month[month] .. " days in: '" .. sm.match .. "'", anchor)
   end
   if month == 2 then
      local leap_year = (year % 4 == 0) and not (year % 100 == 0) or (year % 400 == 0)
      if leap_year == false then
         if day > 28 then _error(sm, "Too many days in month. Found " .. day .. " days in February, which only has 28 days if it's not a leap year in: '" .. sm.match .. "'", anchor) end
      end
   end
end

local function assign_time_local(sm, match, hour, min, sec, msec)
   sm.value_type = "time-local"
   if sm.options.parse_datetime_as == "string" then
      sm.value = sm.match .. sm.ext
   else
      sm.value = { hour = hour, min = min, sec = sec, msec = msec }
   end
end

local function assign_date_local(sm, match, year, month, day)
   sm.value_type = "date-local"
   if sm.options.parse_datetime_as == "string" then
      sm.value = match
   else
      sm.value = { year = year, month = month, day = day }
   end
end

local function assign_datetime_local(sm, match, year, month, day, hour, min, sec, msec)
   sm.value_type = "datetime-local"
   if sm.options.parse_datetime_as == "string" then
      sm.value = match
   else
      sm.value = { year = year, month = month, day = day, hour = hour, min = min, sec = sec, msec = msec or 0 }
   end
end

local function assign_datetime(sm, match, year, month, day, hour, min, sec, msec, tz)
   sm.value_type = "datetime"
   if sm.options.parse_datetime_as == "string" then
      sm.value = match
   else
      sm.value = { year = year, month = month, day = day, hour = hour, min = min, sec = sec, msec = msec or 0, time_offset = tz or "00:00" }
   end
end

local function validate_datetime(sm, value)
   local hour_s, min_s, sec_s, msec_s
   local hour, min, sec
   sm._, sm._, sm.match, hour_s, min_s, sm.ext = value:find("^((%d%d):(%d%d))(.*)$")
   if sm.match then
      hour, min = _tointeger(hour_s), _tointeger(min_s)
      validate_hours_minutes(sm, hour, min, "local-time")
      if sm.ext ~= "" then
         sm._, sm._, sec_s = sm.ext:find("^:(%d%d)$")
         if sec_s then
            sec = _tointeger(sec_s)
            validate_seconds(sm, sec, "local-time")
            assign_time_local(sm, sm.match .. sm.ext, hour, min, sec, 0)
            return true
         end
         sm._, sm._, sec_s, msec_s = sm.ext:find("^:(%d%d)%.(%d+)$")
         if sec_s then
            sec = _tointeger(sec_s)
            validate_seconds(sm, sec, "local-time")
            assign_time_local(sm, sm.match .. sm.ext, hour, min, sec, _tointeger(msec_s))
            return true
         end
      else
         assign_time_local(sm, sm.match .. ":00", hour, min, 0, 0)
         return true
      end
   end

   local year_s, month_s, day_s
   local year, month, day
   sm._, sm._, sm.match, year_s, month_s, day_s = value:find("^((%d%d%d%d)%-(%d%d)%-(%d%d))$")
   if sm.match then
      year, month, day = _tointeger(year_s), _tointeger(month_s), _tointeger(day_s)
      validate_month_date(sm, year, month, day, "local-date")
      assign_date_local(sm, sm.match, year, month, day)
      if sm.input:find("^ %d", sm.i) then
         sm._, sm.end_seq, sm.match = sm.input:find("^ ([%S]+)", sm.i)
         value = value .. " " .. sm.match
         sm.i = sm.end_seq + 1
      else
         return true
      end
   end

   sm._, sm._, sm.match, year_s, month_s, day_s, hour_s, min_s, sm.ext =
   value:find("^((%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d))(.*)$")
   if sm.match then
      hour, min = _tointeger(hour_s), _tointeger(min_s)
      validate_hours_minutes(sm, hour, min, "local-time")
      year, month, day = _tointeger(year_s), _tointeger(month_s), _tointeger(day_s)
      validate_month_date(sm, year, month, day, "local-date-time")
      local temp_ext
      sm._, sm._, sec_s, temp_ext = sm.ext:find("^:(%d%d)(.*)$")
      if sec_s then
         sec = _tointeger(sec_s)
         validate_seconds(sm, sec, "local-time")
         sm.match = sm.match .. ":" .. sec_s
         sm.ext = temp_ext
      else
         sm.match = sm.match .. ":00"
      end
      if sm.ext ~= "" then
         sm.match = sm.match .. sm.ext
         if sm.ext:find("^%.%d+[Zz]$") then
            sm._, sm._, msec_s = sm.ext:find("^%.(%d+)[Zz]$")
            assign_datetime(sm, sm.match, year, month, day, hour, min, sec, _tointeger(msec_s))
            return true
         elseif sm.ext:find("^%.%d+[+-]%d%d:%d%d$") then
            local tz_s
            sm._, sm._, msec_s, tz_s = sm.ext:find("^%.(%d+)([+-]%d%d:%d%d)$")
            assign_datetime(sm, sm.match, year, month, day, hour, min, sec, _tointeger(msec_s), tz_s)
            return true
         elseif sm.ext:find("^[Zz]$") then
            assign_datetime(sm, sm.match, year, month, day, hour, min, sec)
            return true
         elseif sm.ext:find("^[+-]%d%d:%d%d$") then
            local tz_s
            sm._, sm._, tz_s = sm.ext:find("^([+-]%d%d:%d%d)$")
            assign_datetime(sm, sm.match, year, month, day, hour, min, sec, 0, tz_s)
            return true
         end
      else
         assign_datetime_local(sm, sm.match, year, month, day, hour, min, sec)
         return true
      end
   end
end

local validators = { validate_integer, validate_float, validate_datetime }
local exact_matches = {
   ["true"] = { true, "bool" }, ["false"] = { false, "bool" },
   ["+inf"] = { math.huge, "float" }, ["inf"] = { math.huge, "float" }, ["-inf"] = { -math.huge, "float" },
   ["+nan"] = { (0/0), "float" }, ["nan"] = { (0/0), "float" }, ["-nan"] = { (0/0), "float" },
}

local function close_other_value(sm)
   sm._, sm.end_seq, sm.match = sm.input:find("^([^ #\r\n,%[{%]}]+)", sm.i)
   if sm.match == nil then _error(sm, "Value expected", "keyvalue-pair") end
   sm.i = sm.end_seq + 1
   local value = sm.match
   if exact_matches[value] then
      sm.value = exact_matches[value][1]; sm.value_type = exact_matches[value][2]; return
   end
   for _, validator in ipairs(validators) do
      if validator(sm, value) then return end
   end
   _error(sm, "Unable to determine type of value for: '" .. value .. "'", "keyvalue-pair")
end

local function create_array(sm)
   sm.nested_arrays = sm.nested_arrays + 1
   sm.arrays[sm.nested_arrays] = {}
   sm.i = sm.i + 1
end

local function add_array_comma(sm)
   if sm.value ~= nil then table.insert(sm.arrays[sm.nested_arrays], sm.value) end
   sm.value = nil
   sm.i = sm.i + 1
end

local function close_array(sm)
   if sm.value ~= nil then table.insert(sm.arrays[sm.nested_arrays], sm.value) end
   sm.value = sm.arrays[sm.nested_arrays]
   sm.value_type = "array"
   sm.nested_arrays = sm.nested_arrays - 1
   sm.i = sm.i + 1
   if sm.nested_arrays == 0 then return "assign" else return "inside_array" end
end

local function create_table(sm)
   sm.tables = {}
   if sbyte(sm.input, sm.i + 1) == chars.OPEN_BRACKET then
      sm.i = sm.i + 2; sm.table_type = "arrays_of_tables"
   else
      sm.i = sm.i + 1; sm.table_type = "table"
   end
end

local function add_table_dot(sm)
   sm.tables[#sm.tables + 1] = sm.value; sm.i = sm.i + 1
end

local function close_table(sm)
   if sm.table_type == "arrays_of_tables" then sm.i = sm.i + 2 else sm.i = sm.i + 1 end
   sm.tables[#sm.tables + 1] = sm.value
   local out = sm.output
   for i = 1, #sm.tables - 1 do
      if not out[sm.tables[i]] then out[sm.tables[i]] = {} end
      out = out[sm.tables[i]]
      if sm.table_type == "arrays_of_tables" and i == #sm.tables - 1 then
         if not out[#out] or type(out[#out]) ~= "table" then table.insert(out, {}) end
         out = out[#out]
      end
   end
   local final = sm.tables[#sm.tables]
   if sm.table_type == "table" then
      if not out[final] then out[final] = {} end
      sm.current_table = out[final]
   else
      if not out[final] then out[final] = {} end
      table.insert(out[final], {})
      sm.current_table = out[final][#out[final]]
   end
end

local function assign_key(sm)
   sm.keys[#sm.keys + 1] = sm.value; sm.value = nil; sm.i = sm.i + 1
end

local function assign_value(sm)
   local out = sm.current_table
   for i = 1, #sm.keys - 1 do
      if not out[sm.keys[i]] then out[sm.keys[i]] = {} end
      out = out[sm.keys[i]]
   end
   out[sm.keys[#sm.keys]] = sm.value
   sm.keys = {}; sm.value = nil
end

local function create_inline_table(sm)
   sm.nested_inline_tables = sm.nested_inline_tables + 1
   sm.inline_table_backup[sm.nested_inline_tables] = {
      previous_state = sm.mode, current_table = sm.current_table, keys = { _unpack(sm.keys) }
   }
   sm.current_table = {}; sm.keys = {}; sm.i = sm.i + 1
end

local function close_inline_table(sm)
   if sm.value ~= nil then assign_value(sm) end
   local res = sm.current_table
   local restore = sm.inline_table_backup[sm.nested_inline_tables]
   sm.keys = restore.keys; sm.current_table = restore.current_table
   sm.nested_inline_tables = sm.nested_inline_tables - 1
   sm.value = res; sm.value_type = "inline-table"; sm.i = sm.i + 1
   if restore.previous_state == "array" then return "inside_array" else return "assign" end
end

local transitions = {
   ["start_of_line"] = {
      [chars.POUND] = { find_newline, "start_of_line" },
      [chars.CR] = { find_newline, "start_of_line" },
      [chars.LF] = { find_newline, "start_of_line" },
      [chars.DOUBLE_QUOTE] = { close_string, "inside_key" },
      [chars.SINGLE_QUOTE] = { close_literal_string, "inside_key" },
      [chars.OPEN_BRACKET] = { create_table, "table" },
      [0] = { close_bare_string, "inside_key" },
   },
   ["table"] = {
      [chars.DOUBLE_QUOTE] = { close_string, "inside_table" },
      [chars.SINGLE_QUOTE] = { close_literal_string, "inside_table" },
      [0] = { close_bare_string, "inside_table" },
   },
   ["inside_table"] = {
      [chars.DOT] = { add_table_dot, "table" },
      [chars.CLOSE_BRACKET] = { close_table, "start_of_line" },
   },
   ["key"] = {
      [chars.DOUBLE_QUOTE] = { close_string, "inside_key" },
      [chars.SINGLE_QUOTE] = { close_literal_string, "inside_key" },
      [chars.LF] = { find_newline, "key" },
      [chars.CR] = { find_newline, "key" },
      [chars.POUND] = { find_newline, "key" },
      [0] = { close_bare_string, "inside_key" },
   },
   ["inside_key"] = {
      [chars.DOT] = { assign_key, "key" },
      [chars.EQUAL] = { assign_key, "value" },
   },
   ["value"] = {
      [chars.SINGLE_QUOTE] = { close_literal_string, "assign" },
      [chars.DOUBLE_QUOTE] = { close_string, "assign" },
      [chars.OPEN_BRACKET] = { create_array, "array" },
      [chars.OPEN_BRACE] = { create_inline_table, "key" },
      [0] = { close_other_value, "assign" },
   },
   ["array"] = {
      [chars.SINGLE_QUOTE] = { close_literal_string, "inside_array" },
      [chars.DOUBLE_QUOTE] = { close_string, "inside_array" },
      [chars.OPEN_BRACKET] = { create_array, "array" },
      [chars.CLOSE_BRACKET] = { close_array, "?" },
      [chars.POUND] = { find_newline, "array" },
      [chars.CR] = { find_newline, "array" },
      [chars.LF] = { find_newline, "array" },
      [0] = { close_other_value, "inside_array" },
   },
   ["inside_array"] = {
      [chars.COMMA] = { add_array_comma, "array" },
      [chars.CLOSE_BRACKET] = { close_array, "?" },
      [chars.POUND] = { find_newline, "inside_array" },
      [chars.CR] = { find_newline, "inside_array" },
      [chars.LF] = { find_newline, "inside_array" },
   },
   ["assign"] = {
      [0] = { assign_value, "start_of_line" },
   }
}

function tinytoml.parse(filename, options)
   local sm = { i = 1, line_number = 1, line_number_char_index = 1, nested_arrays = 0, nested_inline_tables = 0, keys = {}, arrays = {}, inline_table_backup = {} }
   local file = io.open(filename, "r")
   if not file then error("Unable to open file: " .. filename) end
   sm.input = file:read("*all"); file:close()
   sm.input_length = #sm.input; sm.output = {}; sm.current_table = sm.output; sm.mode = "start_of_line"
   while sm.i <= sm.input_length do
      local b = sbyte(sm.input, sm.i)
      if b == 32 or b == 9 then sm.i = sm.i + 1
      else
         local transition = transitions[sm.mode][b] or transitions[sm.mode][0]
         if not transition then error("Unexpected character at line " .. sm.line_number) end
         if transition[2] == "?" then sm.mode = transition[1](sm) else transition[1](sm); sm.mode = transition[2] end
      end
   end
   if sm.mode == "assign" then assign_value(sm) end
   return sm.output
end

return tinytoml
