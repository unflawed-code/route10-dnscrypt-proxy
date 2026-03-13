local toml = require('toml')
local data = toml.parse('/tmp/setup.toml')
print('Version: ' .. data.dnscrypt.version)
print('Filter Dir: ' .. data.settings.filter_dir)
print('Sources:')
for _, s in ipairs(data.sources.blocked_names) do
    print(' - ' .. s)
end
