rockspec_format = "3.0"
package = "kong-plugin-sync-eureka"

version = "1.1.0-3"

local pluginName = "sync-eureka"

supported_platforms = {"linux", "macosx"}
source = {
  url = "git://github.com/anjia0532/kong-plugin-sync-eureka",
  tag = "1.1.0"
}

description = {
  summary = "a plugin of kong to sync from eureka application instances register to kong server",
  detailed = [[
    sync eureka application instances register to kong server
  ]],
  homepage = "https://github.com/anjia0532/kong-plugin-sync-eureka",
  license = "BSD",
  labels = { "kong", "kong-plugin", "openresty" , "eureka"}
}

dependencies = {
}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins."..pluginName..".handler"] = "kong/plugins/"..pluginName.."/handler.lua",
    ["kong.plugins."..pluginName..".schema"] = "kong/plugins/"..pluginName.."/schema.lua",
    ["kong.plugins."..pluginName..".api"] = "kong/plugins/"..pluginName.."/api.lua",
  }
}
