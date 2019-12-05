local eureka = require "kong.plugins.sync-eureka.handler"
local write = kong.response.exit
return {
    ["/eureka/sync(/:app)"] = {
        POST = function(self)
            eureka.sync_job(self.params.app)
            return write(200, {
                message = "sync eureka " .. (self.params.app or "all") ..
                    " now ..."
            })
        end
    },
    ["/eureka/clean-targets"] = {
        POST = function()
            eureka.cleanup_targets()
            return write(200, {message = "cleanup invalid targets ..."})
        end
    }
}
