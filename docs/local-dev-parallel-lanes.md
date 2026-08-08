# Parallel local development lanes

The default development configuration uses one set of ports, databases, Redis DBs, and Elasticsearch indices. Use a lane to run up to four isolated development environments on the same machine:

```shell
bin/dev-lane 1
```

Lane 0 preserves the existing `bin/dev` values. Lanes 1–3 derive isolated values from the lane number.

| Lane | Rails port | Vite port | Database | Redis DBs | ES suffix | Mongo database | AnyCable WS / RPC |
| --- | ---: | ---: | --- | --- | --- | --- | --- |
| 0 | 3000 | 3036 | `gumroad_development` | 0–3 | none | `gumroad_log_development` | 8080 / 50051 |
| 1 | 3001 | 3038 | `gumroad_development_lane1` | 4–5 | `_lane1` | `gumroad_log_development_lane1` | 8081 / 50052 |
| 2 | 3002 | 3040 | `gumroad_development_lane2` | 6–7 | `_lane2` | `gumroad_log_development_lane2` | 8082 / 50053 |
| 3 | 3003 | 3042 | `gumroad_development_lane3` | 8–9 | `_lane3` | `gumroad_log_development_lane3` | 8083 / 50054 |

Vite ports step by two so no lane collides with 3037, the test environment's Vite port. Extra lanes get two Redis databases (app+rpush, sidekiq+rack-attack — the namespaced stores share) because databases 10 and above belong to the test suite: 10–13 are `.env.test`'s fallback block and `config/test_redis_isolation.rb` leases from 14 up, both flushed before every example. That test-suite boundary is also why lanes stop at 3.

## First-time setup

Run setup commands inside a subshell so the lane environment cannot leak into the rest of your session (`bin/dev-lane` also exports `DISABLE_SPRING=1`, so a warm Spring server preloaded with another lane's database can never serve these commands):

```shell
(
  set -a
  eval "$(bin/dev-lane 1 --print-env)"
  set +a
  bin/rails db:create db:migrate db:seed
  bin/rails runner "DevTools.delete_all_indices_and_reindex_all"
)
```

Never run the test suite from a shell holding lane environment: the exported `*_REDIS_HOST` / `MONGO_DATABASE_NAME` values outrank `.env.test` (dotenv does not override existing variables), so specs would flush the lane's Redis databases and write into its Mongo database.

The test suite already isolates per run through `TEST_DATABASE_NAME` and Redis database leasing (`config/test_redis_isolation.rb`); development lanes extend the same idea to the dev server stack.
