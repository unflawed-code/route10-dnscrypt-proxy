-- get_config.lua: Helper script to extract values from setup.toml
-- Usage: lua get_config.lua <toml_file> <dotted.key>
-- For tables/arrays, prints one item per line.
-- For scalars, prints the value.
-- Exits silently (no output) if key not found.

local toml = require('toml')

local toml_file = arg[1]
local key_path = arg[2]

if not toml_file or not key_path then
    os.exit(1)
end

local status, data = pcall(toml.parse, toml_file)
if not status then
    os.exit(1)
end

-- Strip leading dot if present
key_path = key_path:gsub('^%.', '')

-- Walk the key path
local val = data
for k in key_path:gmatch('[^.]+') do
    if type(val) == 'table' then
        val = val[k]
    else
        val = nil
        break
    end
end

-- Output the result
if type(val) == 'table' then
    for _, item in ipairs(val) do
        print(item)
    end
elseif val ~= nil then
    print(tostring(val))
end
