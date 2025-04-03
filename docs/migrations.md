(Gumroad-specific, go crazy with the other repos)

1. Submit migrations in separate PRs, except for:
   - Creating new tables
   - Adding columns/indexes to normal tables
   - Backward-compatible changes
2. Use `change_table(table, bulk: true)` for multiple changes to a table.
3. Avoid new foreign key constraints due to performance and logistical issues.
4. Make one change per migration to prevent partial commits on failure.
5. Consider alternatives to adding columns/indexes to large tables.
6. Make new boolean columns `NOT NULL` when possible.
7. Don't directly rename columns or tables. Instead:
   - Add new column
   - Update code to use new column
   - Deploy
   - Copy data
   - Remove old column references
   - Remove old column
   - Deploy
8. Before removing a column:
   - Remove all usages in code
   - Add to `ignored_columns`
   - Deploy
   - Remove column and `ignored_columns` entry

### Deploying

1. Be present during deployment of your migration.
2. Monitor:
   - Bugsnag for recent production errors
   - Cloudwatch Web dashboard (errors rate, successful purchases)
3. Use `./logs.sh` in `nomad/production` to view migration logs.
4. For large table migrations, ensure experienced support is available.
5. Be aware of PT-OSC (pt-online-schema-change) process:
   - Creates duplicate table
   - Adds triggers for data sync
   - Copies data in batches
   - Renames tables
6. If migration gets stuck:
   - Check for queries "waiting for table metadata lock"
   - Kill long-running queries if necessary
7. To cancel a migration:
   - Remove added triggers
   - Empty and remove the temporary table
8. Use `DISABLE_ALTERITY=1` to bypass PT-OSC if needed.

### Long-running tasks

- For long-running tasks, we can use `web_server_generic` to run the script in production. Please ask in `#engineering` Slack channel to make sure nobody else is using that instance before redeploying it. As of now, only one `web_server_generic` instance can run at a time.

```bash
export DEPLOY_TAG=production-<revision>
cd nomad/production && ./start_generic_web.sh
```

This will output an URL. Open the URL and note the client IP address from the hostname:

![Untitled](https://s3-us-west-2.amazonaws.com/secure.notion-static.com/c3806a61-90ab-45e7-b5d9-2b25f1dff077/Untitled.png)

SSH into the server and open the Rails console as follows:

```bash
INSTANCE_IP=10.1.x.x COMMAND="screen -adrAR" ./console.sh
bundle exec rails c
```

This will stay running even if your connection is interrupted or if somebody deploys to production in between. If you get disconnected, run the same `INSTANCE_IP=10.1.x.x COMMAND="screen -adrAR" ./console.sh` command again to reconnect to the terminal.

Once the task is finished running, you can stop the `web_server_generic` instance as follows:

```bash
cd nomad
source nomad_proxy_functions.sh
proxy_off production; proxy_on production
nomad_insecure_wrapper stop -purge web_server_generic
proxy_off production
```

### How to add, change, remove a column or index

[Maintaining production databases](https://www.notion.so/Maintaining-production-databases-07f3d5b2719c479ea93e73a04355370d?pvs=21)
