kong-plugin-sync-eureka
---

Move to
---

https://github.com/anjia0532/discovery-syncer

Prerequisites
---
- [Kong >=1.4.0](https://github.com/Kong/kong/releases/tag/1.4.0)
- Eureka v1 endpoint( `curl -H "Accept:application/json" http://eureka:8761/eureka/apps` )

Quickstart
---

```bash
$ luarocks install kong-plugin-sync-eureka

$ export plugins=bundled,sync-eureka
$ kong restart
$ curl -H "Content-Type: application/json" -X POST  --data '{"config":{"sync_interval":10,"eureka_url":"http://eureka:8761/eureka","clean_target_interval":86400},"name":"sync-eureka"}' http://127.0.0.1:8001/plugins
$ curl -H "Content-Type: application/json" -X GET http://127.0.0.1:8001/plugins/

# wait and check

$ curl -H "Content-Type: application/json" -X GET http://127.0.0.1:8001/services/
$ curl -H "Content-Type: application/json" -X GET http://127.0.0.1:8001/routes/
$ curl -H "Content-Type: application/json" -X GET http://127.0.0.1:8001/upstreams/
$ curl -H "Content-Type: application/json" -X GET http://127.0.0.1:8001/upstreams/{upstream host:port or id}/targets/


# since v1.1.0
# /eureka/sync/ sync all apps
# /eureka/sync/app_name sync one
$ curl -H "Content-Type: application/json" -X POST http://127.0.0.1:8001/eureka/sync/[{app}]
# clean invalid targets
$ curl -H "Content-Type: application/json" -X POST http://127.0.0.1:8001/eureka/clean-targets

```

Note
---
plugin config
- sync_interval : Interval between sync applications from eureka server (in seconds) default 10 sec
- eureka_url : eureka server url, e.g. http://127.0.0.1:8761/eureka
- clean_target_interval : Interval between cleanup invalid upstream's target default 86400 sec (1 day)

References
---

[Plugin Development - (un)Installing your plugin](https://docs.konghq.com/1.4.x/plugin-development/distribution/)

[Kong/kong-plugin](https://github.com/Kong/kong-plugin)

[Kong/kong-vagrant](https://github.com/Kong/kong-vagrant)

[微服务 API 网关 Kong 插件开发 - 安装/卸载插件](https://git.102no.com/2019/05/05/kong-plugin-distribution/)

[quancheng-ec/eureka-kong-register](https://github.com/quancheng-ec/eureka-kong-register)

[048-使用Kong替换Zuul(从Eureka同步列表)](https://juejin.im/post/5dd25fcff265da0bbe51093f)

[049-Kong1.4 vs SC Gateway2.2 vs Zuul1.3 性能测试](https://juejin.im/post/5dd26053f265da0bbe510940)

Copyright and License
---

This module is licensed under the BSD license.

Copyright (C) 2017-, by AnJia <anjia0532@gmail.com>.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
