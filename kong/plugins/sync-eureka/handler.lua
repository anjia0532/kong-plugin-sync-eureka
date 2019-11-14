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
local LOG = kong.log.inspect

local SyncEurekaHandler = {}

SyncEurekaHandler.PRIORITY = 1000
SyncEurekaHandler.VERSION = "1.0.0"

local function eureka_apps()
    LOG("start fetch eureka apps")
    if not sync_eureka_plugin then
        return nil, 'failed to query plugin config'
    end
    local config = sync_eureka_plugin["enabled"] and
                       sync_eureka_plugin["config"] or nil

    local httpc = http.new()
    local res, err = httpc:request_uri(config["eureka_url"] .. "/apps", {
        method = METHOD_GET,
        headers = {["Accept"] = "application/json"},
        keepalive_timeout = 60,
        keepalive_pool = 10
    })

    if not res then
        kong.log.err("failed to fetch eureka apps request: ", err)
        return nil
    end
    local apps = cjson.decode(res.body)

    --[[
      convert to app_list
    {
      "demo":{
        "192.168.0.10:8080"=true,
        "health_path"="/health"
      }
    }
  ]]
    local app_list = {}
    for _, item in pairs(apps["applications"]["application"]) do
        local name = string.lower(item["name"])
        app_list[name] = {}
        for _, it in pairs(item["instance"]) do
            local host, _ = ngx_re.split(it["homePageUrl"], "/")
            app_list[name][host[3]] = true
            app_list[name]["health_path"] =
                string.sub(it["healthCheckUrl"], string.len(it["homePageUrl"]))
        end
    end

    LOG("end to fetch eureka apps,total of ", #app_list, "apps")
    return app_list
end
local function get_admin_listen()
    for _, item in pairs(singletons.configuration.admin_listeners) do
        if not item['ssl'] then
            if "0.0.0.0" == item["ip"] then item["ip"] = "127.0.0.1" end
            return "http://" .. item["ip"] .. ":" .. item['port']
        end
    end
    return nil
end
local function admin_client(method, path, body)
    if not admin_host then admin_host = get_admin_listen() end
    local httpc = http.new()

    local req = {
        method = method,
        headers = {["Content-Type"] = "application/json"},
        keepalive_timeout = 60,
        keepalive_pool = 10
    }
    LOG("send admin request,uri:", path, ",method:", method, "body:", body)
    if METHOD_POST == method then req["body"] = cjson.encode(body) end
    return httpc:request_uri(admin_host .. path, req)
end

local function parse_resp(type, res, err, cache_key)
    -- created success status is 201
    -- query success status is 200
    -- 409 is conflict
    -- query routes and targets ,status is 200 ,may be data is empty list
    if res and (res.status <= 201 or res.status == 409) then
        if res.status == 200 then
            local data = cjson.decode(res.body)["data"]
            if data and #data == 0 then return "ok", nil end
        end
        kong_cache:safe_set(cache_key, true, cache_exptime)
        return "ok", nil
    end
    if not res or res.status >= 400 then
        kong.log.err("[" .. type ..
                         "]failed to create kong request: http err msg:", err,
                     ", http code:", res.status, ", cache_key:", cache_key,
                     ",response body:", res.body)
        return nil, "failed to create kong " .. type
    end
    return "ok", nil
end
local function create_service(name)
    local cache_key = "sync_eureka_apps:service:" .. name
    if kong_cache:get(cache_key) then return "ok", nil end

    LOG("[create service]:miss cache,we need to query this service:", name)
    local res, err = admin_client(METHOD_GET, "/services/" .. name, nil)
    parse_resp("service", res, err, cache_key)
    if kong_cache:get(cache_key) then return "ok", nil end

    LOG("[create service]:new service,we need to create this service:", name)
    res, err = admin_client(METHOD_POST, "/services",
                            {name = name, host = name .. eureka_suffix})
    parse_resp("service", res, err, cache_key)
end

local function create_route(name)
    local cache_key = "sync_eureka_apps:route:" .. name
    if kong_cache:get(cache_key) then return "ok", nil end

    LOG("[create route]:miss cache,we need to query this route:", name)
    local res, err = admin_client(METHOD_GET, "/routes/" .. name, nil)
    parse_resp("route", res, err, cache_key)
    if kong_cache:get(cache_key) then return "ok", nil end

    LOG("[create route]:new route,we need to create this route:", name)
    res, err = admin_client(METHOD_POST, "/services/" .. name .. "/routes", {
        name = name,
        protocols = {"http"},
        paths = {"/" .. name}
    })
    parse_resp("route", res, err, cache_key)
end
local function create_upstream(name, item)

    local cache_key = "sync_eureka_apps:upstream:" .. name
    if kong_cache:get(cache_key) then return "ok", nil end

    LOG("[create upstream]:miss cache,we need to query this upstream:", name)
    local res, err = admin_client(METHOD_GET,
                                  "/upstreams/" .. name .. eureka_suffix, nil)
    parse_resp("upstream", res, err, cache_key)

    LOG("[create upstream]:new route,we need to create this upstream:", name)
    res, err = admin_client(METHOD_POST, "/upstreams", {
        name = name .. eureka_suffix,
        healthchecks = {
            active = {
                http_path = item["health_path"],
                timeout = 5,
                healthy = {interval = 10, successes = 3},
                unhealthy = {
                    http_failures = 3,
                    interval = 10,
                    tcp_failures = 3,
                    timeouts = 5
                }
            }
        }
    })
    parse_resp("upstream", res, err, cache_key)
end
local function get_targets(name, target_next)

    local res, err = admin_client(METHOD_GET, target_next, nil)
    local targets = {}
    if res and res.status == 200 then
        local target_resp = cjson.decode(res.body)
        LOG("[get targets]:path:", target_next, " ,length:",
            #target_resp["data"])
        for _, item in pairs(target_resp["data"]) do
            local kong_cache_key = "sync_eureka_apps:kong:target:" .. name ..
                                       ":" .. item["target"]
            targets[item["target"]] = name
            kong_cache:safe_set(kong_cache_key, true, cache_exptime * 30)
        end
        if ngx.null ~= target_resp["next"] then
            LOG("[get targets]: next page, path:", target_resp["next"],
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
local function add_target(name, target)

    local cache_key = "sync_eureka_apps:target:" .. name .. ":" .. target
    local kong_cache_key = "sync_eureka_apps:kong:target:" .. name .. ":" ..
                               target

    local kong_item = kong_cache:get(kong_cache_key)
    if kong_cache:get(cache_key) then
        if not kong_item then
            kong_cache:safe_set(kong_cache_key, true, cache_exptime * 30)
        end
        return "ok", nil
    end
    local res, err
    if not kong_item then
        get_targets(name, "/upstreams/" .. name .. eureka_suffix .. "/targets")
    end
    kong_item = kong_cache:get(kong_cache_key)
    if kong_item then
        kong_cache:safe_set(cache_key, true, cache_exptime)
        return "ok", nil
    end

    LOG("[add target]: name:", name, " ,target:", target)
    res, err = admin_client(METHOD_POST,
                            "/upstreams/" .. name .. eureka_suffix .. "/targets",
                            {target = target})
    parse_resp("target", res, err, cache_key)
end
local function kong_upstreams(upstream_next)

    LOG("[fetch kong's upstream]: path:", upstream_next or "/upstreams")
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

    LOG("[get kong's upstreams]: next page, path:", ups["next"],
        " ,this page size:", #ups["data"])
    return upstreams
end

local function delete_target(name, target)

    local cache_key = "sync_eureka_apps:target:" .. name .. ":" .. target
    local kong_cache_key = "sync_eureka_apps:kong:target:" .. name .. ":" ..
                               target

    kong.log.warn("[delete target]: upstream name :", name .. eureka_suffix,
                  " ,target:", target)
    kong_cache:safe_set(cache_key, nil)
    kong_cache:safe_set(kong_cache_key, nil)

    admin_client(METHOD_DELETE, "/upstreams/" .. name .. eureka_suffix ..
                     "/targets/" .. target, nil)

end
local function cleanup_targets()
    LOG("cron job to cleanup invalid targets")
    sync_eureka_plugin = plugins:select_by_cache_key("plugins:sync_eureka::::")
    if not sync_eureka_plugin then return end
    local app_list = eureka_apps()
    local upstreams = kong_upstreams()
    for up_name, name in pairs(upstreams) do
        local targets =
            get_targets(name, "/upstreams/" .. up_name .. "/targets") or {}
        -- delete all targets by this upstream name
        if not app_list[name] then
            for target, app_name in pairs(targets) do
                delete_target(name, target)
            end
        else
            for target, app_name in pairs(targets) do
                -- delete this target
                if not app_list[name][target] then
                    delete_target(name, target)
                end
            end
        end
    end
end
local function sync_job()
    LOG("cron job to fetch apps from eureka server")
    sync_eureka_plugin = plugins:select_by_cache_key("plugins:sync_eureka::::")
    if not sync_eureka_plugin then return end

    local cache_app_list = kong_cache:get("sync_eureka_apps") or "{}"
    cache_app_list = cjson.decode(cache_app_list)
    local app_list = eureka_apps()
    for name, item in pairs(app_list) do
        if not cache_app_list[name] then
            create_service(name, item)
            create_route(name, item)
            create_upstream(name, item)
        end

        for target, flag in pairs(item) do
            if target ~= "health_path" and flag then
                add_target(name, target)
            end
        end
        cache_app_list[name] = true
    end
    kong_cache:safe_set("sync_eureka_apps", cjson.encode(cache_app_list),
                        cache_exptime)
end
function SyncEurekaHandler:init_worker()
    if 0 ~= ngx.worker.id() then return end

    sync_eureka_plugin = plugins:select_by_cache_key("plugins:sync_eureka::::")
    LOG("init worker,load sync_eureka_plugin:", cjson.encode(sync_eureka_plugin))

    if sync_eureka_plugin and sync_eureka_plugin["enabled"] then
        local ok, err = ngx.timer.every(
                            sync_eureka_plugin["config"]["sync_interval"],
                            sync_job)
        if not ok then
            kong.log.err("failed to create the timer: ", err)
            return
        end
        local ok, err = ngx.timer.every(
                            sync_eureka_plugin["config"]["clean_target_interval"],
                            cleanup_targets)
        if not ok then
            kong.log.err("failed to create the timer: ", err)
            return
        end
    end
end

return SyncEurekaHandler
