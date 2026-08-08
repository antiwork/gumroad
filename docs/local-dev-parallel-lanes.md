# Parallel local development lanes

The default development configuration uses one set of ports, databases, Redis DBs, and Elasticsearch indices. Use a lane to run up to four isolated development environments on the same machine:

```shell
bin/dev-lane 1
```

Lane 0 preserves the existing `bin/dev` values. Lanes 1–3 derive isolated values from the lane number.

| Lane | Rails port | Vite port | Database | Redis DBs | ES suffix | Mongo database | AnyCable WS / RPC |
| --- | ---: | ---: | --- | --- | --- | --- | --- |
| 0 | 3000 | 3036 | `gumroad_development` | 0–3 | none | `gumroad_log_development` | 8080 / 50051 |
| 1 | 3001 | 3038 | `gumroad_development_lane1` | 4–7 | `_lane1` | `gumroad_log_development_lane1` | 8081 / 50052 |
| 2 | 3002 | 3040 | `gumroad_development_lane2` | 8–11 | `_lane2` | `gumroad_log_development_lane2` | 8082 / 50053 |
| 3 | 3003 | 3042 | `gumroad_development_lane3` | 12–15 | `_lane3` | `gumroad_log_development_lane3` | 8083 / 50054 |

Vite ports step by two so no lane collides with 3037, the test environment's Vite port.

## First-time setup

Load a lane's environment before running setup commands:

```shell
set -a
eval "$(bin/dev-lane 1 --print-env)"
set +a
bin/rails db:create db:migrate db:seed
bin/rails console
```

Then create and populate that lane's Elasticsearch indices in the console:

```ruby
DevTools.delete_all_indices_and_reindex_all
```

The test suite already follows the same per-run isolation convention through `LANE` and database-name environment variables; development lanes extend that convention to all local services.

Redis defaults to 16 databases, and each lane consumes four. For that reason, `bin/dev-lane` accepts only lanes 0–3.
