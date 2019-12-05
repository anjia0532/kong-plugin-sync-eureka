local cjson = require "cjson"
local http = require "resty.http"
local singletons = require "kong.singletons"
local ngx_re = require "ngx.re"

local admin_host = nil
local plugins = kong.db.plugins
local kong_cache = ngx.shared.kong

local METHOD_POST = "POST"
local METHOD_DELETE = "DELETE"
local METHOD_GET = "GET"
local cache_exptime = 120
local eureka_suffix = ".eureka.internal"
local sync_eureka_plugin = {}
local LOG_INFO = kong.log.info
local LOG_DEBUG = kong.log.debug
local LOG_ERROR = kong.log.err
local LOG_WARN = kong.log.warn

local SyncEurekaHandler = {}
-- https://github.com/Netflix/eureka/wiki/Eureka-REST-operations
local status_weitht = {
    ["UP"] = 100,
    ["DOWN"] = 1,
    ["STARTING"] = 0,
    ["OUT_OF_SERVICE"] = 0,
    ["UNKNOWN"] = 1
}

SyncEurekaHandler.PRIORITY = 1000
SyncEurekaHandler.VERSION = "1.0.0"

--- fetch eureka applications info
local function eureka_apps(app_name)
    LOG_INFO("start fetch eureka apps [ ", app_name or "all", " ]")
    if not sync_eureka_plugin then
        return nil, 'failed to query plugin config'
    end
    local config = sync_eureka_plugin["enabled"] and
                       sync_eureka_plugin["config"] or nil

    local httpc = http.new()
    local res, err = httpc:request_uri(config["eureka_url"] .. "/apps/" ..
                                           (app_name or ''), {
        method = METHOD_GET,
        headers = {["Accept"] = "application/json"},
        keepalive_timeout = 60,
        keepalive_pool = 10
    })

    if not res then
        LOG_ERROR("failed to fetch eureka apps request: ", err)
        return nil
    end
    local apps = cjson.decode(res.body)

    --[[
      convert to app_list
      -- https://github.com/Netflix/eureka/wiki/Eureka-REST-operations
    {
      "demo":{
        "192.168.0.10:8080"="UP",
        "health_path"="/health"
      }
    }
  ]]

    if app_name then
        apps = {["applications"] = {["application"] = {apps["application"]}}}
    end

    local app_list = {}
    for _, item in pairs(apps["applications"]["application"]) do
        local name = string.lower(item["name"])
        app_list[name] = {}
        for _, it in pairs(item["instance"]) do
            local host, _ = ngx_re.split(it["homePageUrl"], "/")
            app_list[name][host[3]] = it['status']
            app_list[name]["health_path"] =
                string.sub(it["healthCheckUrl"], string.len(it["homePageUrl"]))
        end
    end

    LOG_DEBUG("end to fetch eureka apps,total of ", #app_list, " apps")
    return app_list
end

--- get kong admin api listeners default is 127.0.0.1:8001
local function get_admin_listen()
    for _, item in pairs(singletons.configuration.admin_listeners) do
        if not item['ssl'] then
            if "0.0.0.0" == item["ip"] then item["ip"] = "127.0.0.1" end
            return "http://" .. item["ip"] .. ":" .. item['port']
        end
    end
    return nil
end

--- http client of kong admin api
---@param method string http method like GET,POST,PUT,DELETE ...
---@param path string uri of path like /test
---@param body table request body
local function admin_client(method, path, body)
    if not admin_host then admin_host = get_admin_listen() end
    local httpc = http.new()

    local req = {
        method = method,
        headers = {["Content-Type"] = "application/json"},
        keepalive_timeout = 60,
        keepalive_pool = 10
    }
    LOG_DEBUG("send admin request,uri:", path, ",method:", method, "body:", body)
    if METHOD_POST == method and body then req["body"] = cjson.encode(body) end
    return httpc:request_uri(admin_host .. path, req)
end

--- parse response
---@param type string type of operation
---@param resp table response of request
---@param err string error message
---@param cache_key string cache key
local function parse_resp(type, resp, err, cache_key)
    -- created success status is 201
    -- query success status is 200
    -- 409 is conflict
    -- query routes and targets ,status is 200 ,may be data is empty list
    if resp and (resp.status <= 201 or resp.status == 409) then
        if resp.status == 200 then
            local data = cjson.decode(resp.body)["data"]
            if data and #data == 0 then return "ok", nil end
        end
        kong_cache:safe_set(cache_key, true, cache_exptime)
        return "ok", nil
    end
    if not resp or resp.status >= 400 then
        LOG_ERROR(resp.body)
        LOG_ERROR(
            "[" .. type .. "]failed to create kong request: http err msg:", err,
            ", http code:", resp.status, ", cache_key:", cache_key,
            ",response body:", resp.body)
        return nil, "failed to create kong " .. type
    end
    return "ok", nil
end

--- create service by app name
---@param name string app name
local function create_service(name)
    local cache_key = "sync_eureka_apps:service:" .. name
    if kong_cache:get(cache_key) then return "ok", nil end

    LOG_DEBUG("[create service]:miss cache,we need to query this service:", name)
    local res, err = admin_client(METHOD_GET, "/services/" .. name, nil)
    LOG_ERROR("res", res, err)
    parse_resp("service", res, err, cache_key)
    if kong_cache:get(cache_key) then return "ok", nil end

    LOG_DEBUG("[create service]:new service,we need to create this service:",
              name)
    res, err = admin_client(METHOD_POST, "/services",
                            {name = name, host = name .. eureka_suffix})
    parse_resp("service", res, err, cache_key)
end

--- create route by app name
---@param name string app name
local function create_route(name)
    local cache_key = "sync_eureka_apps:route:" .. name
    if kong_cache:get(cache_key) then return "ok", nil end

    LOG_DEBUG("[create route]:miss cache,we need to query this route:", name)
    local res, err = admin_client(METHOD_GET, "/routes/" .. name, nil)
    parse_resp("route", res, err, cache_key)
    if kong_cache:get(cache_key) then return "ok", nil end

    LOG_DEBUG("[create route]:new route,we need to create this route:", name)
    res, err = admin_client(METHOD_POST, "/services/" .. name .. "/routes", {
        name = name,
        protocols = {"http"},
        paths = {"/" .. name}
    })
    parse_resp("route", res, err, cache_key)
end

--- create upstream by appname
---@param name string app name
---@param item table object of eureka's instance
local function create_upstream(name, item)

    local cache_key = "sync_eureka_apps:upstream:" .. name
    if kong_cache:get(cache_key) then return "ok", nil end

    LOG_DEBUG("[create upstream]:miss cache,we need to query this upstream:",
              name)
    local res, err = admin_client(METHOD_GET,
                                  "/upstreams/" .. name .. eureka_suffix, nil)
    parse_resp("upstream", res, err, cache_key)
    if kong_cache:get(cache_key) then return "ok", nil end

    LOG_DEBUG("[create upstream]:new route,we need to create this upstream:",
              name)
    res, err = admin_client(METHOD_POST, "/upstreams", {
        name = name .. eureka_suffix,
        healthchecks = {
            -- passive check
            passive = {
                unhealthy = {
                    http_failures = 10,
                    timeouts = 40,
                    http_statuses = {503, 504}
                },
                healthy = {successes = 3}
            }

        }
    })
    parse_resp("upstream", res, err, cache_key)
end

--- get targets by upstream name
---@param name string upstream name
---@param target_next string url of next targets page
local function get_targets(name, target_next)

    local res, err = admin_client(METHOD_GET, target_next, nil)
    local targets = {}
    if res and res.status == 200 then
        local target_resp = cjson.decode(res.body)
        LOG_DEBUG("[get targets]:path:", target_next, " ,length:",
                  #target_resp["data"])
        for _, item in pairs(target_resp["data"]) do
            local kong_cache_key = "sync_eureka_apps:target:" .. name .. ":" ..
                                       item["target"]
            targets[item["target"]] = item["weight"]
            kong_cache:safe_set(kong_cache_key, true, cache_exptime * 30)
        end
        if ngx.null ~= target_resp["next"] then
            LOG_DEBUG("[get targets]: next page, path:", target_resp["next"],
                      " ,this page size:", #target_resp["data"])
            local next_targets = get_targets(name, target_resp["next"])
            for key, value in pairs(next_targets) do
                targets[key] = value
            end
        end
    else
        return nil, err
    end
    return targets, nil
end

---delete unhealthy instance target
---@param name string app name
---@param target string app host:port
local function delete_target(name, target)

    local cache_key = "sync_eureka_apps:target:" .. name .. ":" .. target

    LOG_WARN("[delete target]: upstream name :", name .. eureka_suffix,
             " ,target:", target)
    kong_cache:safe_set(cache_key, nil)

    admin_client(METHOD_DELETE, "/upstreams/" .. name .. eureka_suffix ..
                     "/targets/" .. target, nil)

end

--- add target to upstream
---@param name string app name
---@param target string app host:port
---@param weight integer 0-1000 default 100 
---@param tags table tags  
local function put_target(name, target, weight, tags)

    -- get_targets use(fetch targets)
    local cache_key = "sync_eureka_apps:target:" .. name .. ":" .. target

    local targets = get_targets(name, "/upstreams/" .. name .. eureka_suffix ..
                                    "/targets")
    if not targets then return nil, "targets is nil" end
    weight = weight or 0
    local kong_weight = targets[target] or 0
    
    if weight ~= kong_weight then
      -- kong not have this target
        if kong_weight ~= 0 then delete_target(name, target) end
        -- weight == 0 means starting and out_of_service
        -- kong_weight == 0 means this target not in kong upstream
        -- weight == 100 means eureka status is up
        if weight == 0 or (kong_weight == 0 and weight ~= 100) then
            return "ok", nil
        end
    else
        return "ok", nil
    end

    LOG_DEBUG("[add target]: name:", name, " ,target:", target)
    local res, err = admin_client(METHOD_POST, "/upstreams/" .. name ..
                                      eureka_suffix .. "/targets", {
        target = target,
        weight = weight or 1,
        tags = tags or {}
    })
    parse_resp("target", res, err, cache_key)
end

--- fetch kong's upstream
---@param upstream_next string url of next upstream page
local function kong_upstreams(upstream_next)

    LOG_DEBUG("[fetch kong's upstream]: path:", upstream_next or "/upstreams")
    local res, err =
        admin_client(METHOD_GET, upstream_next or "/upstreams", nil)
    if not res or res.status ~= 200 then
        return nil, "failed to fetch kong's upstreams" .. err
    end
    local ups = cjson.decode(res.body)
    local upstreams = {}
    for _, item in pairs(ups["data"]) do
        if string.sub(item["name"], -string.len(eureka_suffix)) == eureka_suffix then
            upstreams[item["name"]] = string.sub(item["name"], 1,
                                                 #item["name"] - #eureka_suffix)
        end
    end
    if ngx.null ~= ups["next"] then
        local next_ups = kong_upstreams(ups["next"])
        for key, value in pairs(next_ups) do upstreams[key] = value end
    end

    LOG_DEBUG("[get kong's upstreams]: next page, path:", ups["next"],
              " ,this page size:", #ups["data"])
    return upstreams
end

--- cron job to cleanup invalid targets
SyncEurekaHandler.cleanup_targets = function()
    LOG_DEBUG("cron job to cleanup invalid targets")
    sync_eureka_plugin = plugins:select_by_cache_key("plugins:sync-eureka::::")
    if not sync_eureka_plugin then return end
    local app_list = eureka_apps()
    local upstreams = kong_upstreams() or {}
    for up_name, name in pairs(upstreams) do
        local targets =
            get_targets(name, "/upstreams/" .. up_name .. "/targets") or {}
        -- delete all targets by this upstream name
        if not app_list[name] then
            for target, _ in pairs(targets) do
                delete_target(name, target)
            end
        else
            for target, _ in pairs(targets) do
                -- delete this target
                if app_list[name][target] ~= "UP" then
                    delete_target(name, target)
                end
            end
        end
    end
end

--- cron job to fetch apps from eureka server
SyncEurekaHandler.sync_job = function(app_name)
    LOG_INFO("cron job to fetch apps from eureka server [ ", app_name or "all",
             " ]")
    sync_eureka_plugin = plugins:select_by_cache_key("plugins:sync-eureka::::")
    if not sync_eureka_plugin then return end

    local cache_app_list = kong_cache:get("sync_eureka_apps") or "{}"
    cache_app_list = cjson.decode(cache_app_list)
    local app_list = eureka_apps(app_name)
    for name, item in pairs(app_list) do
        if not cache_app_list[name] then
            create_service(name)
            create_route(name)
            create_upstream(name)
        end

        cache_app_list[name] = true
        for target, status in pairs(item) do
            if target ~= "health_path" then
                put_target(name, target, status_weitht[status], {status})
            end
        end
    end
    kong_cache:safe_set("sync_eureka_apps", cjson.encode(cache_app_list),
                        cache_exptime)
end

--- init worker
function SyncEurekaHandler:init_worker()
    if 0 ~= ngx.worker.id() then return end

    sync_eureka_plugin = plugins:select_by_cache_key("plugins:sync-eureka::::")
    LOG_INFO("init worker,load sync_eureka_plugin:",
             cjson.encode(sync_eureka_plugin))

    if sync_eureka_plugin and sync_eureka_plugin["enabled"] then
        local ok, err = ngx.timer.every(
                            sync_eureka_plugin["config"]["sync_interval"],
                            SyncEurekaHandler.sync_job)
        if not ok then
            LOG_ERROR("failed to create the timer: ", err)
            return
        end
        local ok, err = ngx.timer.every(
                            sync_eureka_plugin["config"]["clean_target_interval"],
                            SyncEurekaHandler.cleanup_targets)
        if not ok then
            LOG_ERROR("failed to create the timer: ", err)
            return
        end
    end
end

return SyncEurekaHandler
