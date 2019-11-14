kong-plugin-sync-eureka
---

Prerequisites
---
- [Kong >=1.4.0](https://github.com/Kong/kong/releases/tag/1.4.0)
- Eureka v1 endpoint( curl -H "Accept:application/json" http://eureka:8761/eureka/apps )

Quickstart
---

```bash
$ luarocks install kong-plugin-sync-eureka
$ export plugins = bundled,sync-eureka
$ kong restart
$ 
```


References
---

[Plugin Development - (un)Installing your plugin](https://docs.konghq.com/1.4.x/plugin-development/distribution/)

[Kong/kong-plugin](https://github.com/Kong/kong-plugin)

[Kong/kong-vagrant](https://github.com/Kong/kong-vagrant)