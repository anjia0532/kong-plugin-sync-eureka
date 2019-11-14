package = "kong-plugin-sync-eureka"  -- TODO: rename, must match the info in the filename of this rockspec!
                                  -- as a convention; stick to the prefix: `kong-plugin-`
version = "0.1.0-1"               -- TODO: renumber, must match the info in the filename of this rockspec!
-- The version '0.1.0' is the source code version, the trailing '1' is the version of this rockspec.
-- whenever the source version changes, the rockspec should be reset to 1. The rockspec version is only
-- updated (incremented) when this file changes, but the source remains the same.

-- TODO: This is the name to set in the Kong configuration `plugins` setting.
-- Here we extract it from the package name.
local pluginName = "sync-eureka"

supported_platforms = {"linux", "macosx"}
source = {
  url = "https://github.com/anjia0532/kong-plugin-sync-eureka.git",
  tag = "0.1.0"
}

description = {
  summary = "a plugin of kong to sync from eureka application instances register to kong server",
  detailed = [[
    sync eureka application instances register to kong server
  ]],
  homepage = "https://github.com/anjia0532/kong-plugin-sync-eureka",
  license = "Apache 2.0"
}

dependencies = {
}

build = {
  type = "builtin",
  modules = {
    -- TODO: add any additional files that the plugin consists of
    ["kong.plugins."..pluginName..".handler"] = "kong/plugins/"..pluginName.."/handler.lua",
    ["kong.plugins."..pluginName..".schema"] = "kong/plugins/"..pluginName.."/schema.lua",
  }
}
