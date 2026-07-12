- [Deploying](#deploying)
  - [⛔ Blockers](#-blockers)
  - [Prerequisites](#prerequisites)
  - [Automatic way](#automatic-way)
  - [Manual way](#manual-way)
  - [Hotfixes](#hotfixes)
  - [Step 1: Hotfix branch creation](#step-1-hotfix-branch-creation)
  - [Step 2: Make changes in the branch as required](#step-2-make-changes-in-the-branch-as-required)
  - [Step 3: Actual deployment](#step-3-actual-deployment)
  - [When deployment goes bad](#when-deployment-goes-bad)
  - [Logs](#logs)
  - [Hotfixing workers only](#hotfixing-workers-only)
- [Deploying to a preview app](#deploying-to-a-preview-app)
  - [Rails console on a preview app](#rails-console-on-a-preview-app)
  - [Seeding QA state with `preview_qa` rake tasks](#seeding-qa-state-with-preview_qa-rake-tasks)
- [Deploying to staging](#deploying-to-staging)

---

## Deploying

Deployments are automated. When Buildkite builds the `main` branch, it will automatically deploy it to production. The rest of this section explains how deployments can be performed outside of this automated process.

### Prerequisites

Before deploying, make sure you have the `nomad/.env` environment variables file with [these credentials](https://antiwork.1password.com/vaults/xecpqop3ylrsq6zz53klqaaoxq/allitems/qyenwnmcuidk6gzvppa4weagmm).

Also, install [awscli](https://github.com/aws/aws-cli) and configure it with your IAM credentials.

Deployments to staging happen as part of the Buildkite workflow. Whenever a new commit is merged into the main branch, and the tests pass, it gets merged into the staging branch and deployed. You can deploy manually if the Buildkite workflow is broken for some reason, like some test failure, and you need to deploy to staging.

Make sure you read through `nomad/README.md` to get a general understanding of what you're doing, and prerequisite software you'll have to install.

### Automatic way

If you're doing a simple deployment of verified commits, just run `bin/deploy` and follow the instructions. It doesn't matter which branch you're on when you run this, and you'll be prompted to confirm which commits will be deployed.

### Manual way

Rebase the `staging` branch into `production`, and deploy production:

```bash
cd nomad/production && dotenv -f ../.env ./deploy_unattended.sh
```

If everything goes accordingly, you should check the Nomad-UI jobs list to make sure that your specific docker image for production `production-<git short sha>` was deployed.

### Deployment lock

Deployment is automatically locked when it is in progress.

Manually lock the deployment:

```bash
cd nomad/production && ./lock_deployment.sh
```

Manually unlock the deployment:

```bash
cd nomad/production && ./unlock_deployment.sh
```

### Hotfixes

This section is written to facilitate deployments that add commits to the production application without going through the normal branching process(feature branch -> main -> staging -> `production-release` tag).

#### Step 1: Hotfix branch creation

The strategy of creating the hotfix branch will change depending on how the latest code was deployed to production(normally or as a hotfix).

This is how the hotfix branch should be created if the latest deployed code is in the `production-release` tag:

```bash
# Delete existing tag
git tag -d production-release

# Fetch the tag from origin
git fetch origin tag production-release

# Create a new branch from the tag
git checkout -b comp-assets-hotfix-branch-name production-release
```

This is how the hotfix branch should be created if the latest deployed code is not in the `production-release` tag (meaning the latest deployment was a hotfix itself):
Find the tag that was last deployed to production from the Slack channel #releases.

Example of a message in the channel:

> Ershad Kunnakkadan has finished deploying `production-d6b4605`

Find the git tag for that commit from the [tags page on GitHub](https://github.com/antiwork/gumroad/tags). Let's say the tag name is `production-d6b4605/2018-05-02-13-16-03`.
Execute the following command to create a new branch from the tag:

```bash
git fetch --tags && git checkout -b comp-assets-hotfix-branch-name production-d6b4605/2018-05-02-13-16-03
```

Make sure that the branch name starts with `comp-assets-`. The branch name is important because unless it matches with this pattern docker images won't be built for the branch.

#### Step 2: Make changes in the branch as required

After the branch is created by following one of the approaches described above add new commits to this branch as required.

#### Step 3: Actual deployment

Wait for Buildkite to finish running the `docker_asset_compile` job.

Run `git rev-parse --short=12 HEAD` while in the new branch. Let's say this displays `491255bb0a4d`.

Post a message to Slack #releases channel that you're doing a hotfix deployment, then deploy to production:

```bash
export DEPLOY_TAG="production-xxxxxxx"
cd nomad/production && dotenv -f ../.env ./deploy_unattended.sh
```

#### When deployment goes bad

To kill the running containers (like the container that runs database migration), visit <http://localhost:8080> between the deployment and kill the container in `Allocations` page (or use the nomad command). If `localhost:8080` throws an error, please connect to the server by running `cd nomad && source nomad_proxy_functions.sh && proxy_on production`.

To rollback a deployment, get the previous revision from `#releases` channel in Slack and set the environment variable `export DEPLOY_TAG=production-<revision>` and proceed with normal deployment.

#### Logs

All logs generated in the production docker containers (which includes db migration, web servers, Sidekiq) are being pushed to <https://logs.gumroad.com>. It's a Kibana instance connected to Elasticsearch. To view deployment/application logs, please search with the 7-letter SHA of the revision - <https://logs.gumroad.com/app/kibana#/discover>

### Hotfixing workers only

Ershad Kunnakkadan: The easiest way would be to do something like this and proceed with manual deployment with ./deploy_unattended.sh

```diff
diff --git a/nomad/common.sh b/nomad/common.sh
index bb60a7a598..d128504bca 100644
--- a/nomad/common.sh
+++ b/nomad/common.sh
@@ -138,26 +138,26 @@ function create_release_tag() {
 }

 function gr_deploy() {
-  check_for_deployment_lock
+  # check_for_deployment_lock

-  run_job database_migration
+  # run_job database_migration

-  logger "Waiting for db:migrate to complete"
+  # logger "Waiting for db:migrate to complete"

-  wait_for_db_migrate
+  # wait_for_db_migrate

-  run_job rpush
+  # run_job rpush
   run_job sidekiq_worker

-  if (production_deployment); then
-    scale_up_web_server_clusters
-    deploy_to_web_servers
-  else
-    deploy_to_web_servers
-  fi
+  # if (production_deployment); then
+  #   scale_up_web_server_clusters
+  #   deploy_to_web_servers
+  # else
+  #   deploy_to_web_servers
+  # fi

-  run_job post_deployment
+  # run_job post_deployment

   create_release_tag
 }
```

Or, (for Sidekiq only) we can do this:

```bash
$ export DEPLOY_TAG=<>
$ cd nomad
$ source nomad_proxy_functions.sh
$ cd production
$ alias  nomad=nomad_insecure_wrapper
$ dotenv -f ../.env erb sidekiq_worker.nomad.erb > sidekiq_worker.nomad
$ nomad run sidekiq_worker.nomad
```

## Deploying to a preview app

Add the `preview` label to a pull request to deploy its branch to a preview app. This works for any branch except `main` and `comp-assets-*`.

Adding the label triggers a Buildkite build that deploys the branch. Each subsequent push to a labeled branch redeploys automatically.

The preview app URL is posted on the pull request as a GitHub deployment: look for the "View deployment" button (and the Deployments section), which shows the deploy in progress and links to the running app once it is ready.

Deployments are removed automatically when the associated branch is deleted in the repository.

### Rails console on a preview app

Preview apps have Rails console access — see [Connect to Rails console](https://github.com/antiwork/gumroad-deployment/blob/main/docs/ssh.md#connect-to-rails-console) in the deployment repo. The `console.sh` script there resolves the preview instance from the `BRANCH=<branch name>` environment variable (it falls back to the deployment repo's own checked-out branch, so always set it explicitly) and opens `rails c` in the running container. It also supports `COMMAND=...` for one-shot commands — the value is executed directly as the container command, so it must be a runnable program like `bundle exec rake "..."`, not a bare Ruby snippet — and a standalone `-w` flag for a writable database connection (the default is a read-only replica).

### Seeding QA state with `preview_qa` rake tasks

Use the permanent tasks in `lib/tasks/preview_qa.rake` to seed edge-case state on a preview app instead of adding temporary, param-gated seed hooks to your PR ("TEMP: revert before merge" commits). The tasks only run on preview apps, development, and the test suite — they are unavailable in production and on shared staging (staging.gumroad.com), where mutating records would interfere with other people's testing.

Run them through the preview app's Rails console (see the section above for how `console.sh` resolves the branch and the `-w` writable flag — the seeding tasks write, so they need `-w`).

The simplest path is to open an interactive writable console and shell out to rake from the prompt (rake tasks aren't preloaded in a console session, so `bundle exec rake` in a subprocess is the entrypoint):

```shell
cd nomad/staging/deploy_branch && BRANCH=<branch name> ./console.sh -w
# then, at the console prompt:
system 'bundle exec rake "preview_qa:backdate_purchase[<purchase external_id>]"'
```

Alternatively, run a task as a one-shot. `COMMAND` is executed directly in the container as a shell command (not evaluated as Ruby), so it must be a full `bundle exec rake` invocation:

```shell
cd nomad/staging/deploy_branch && \
  BRANCH=<branch name> \
  COMMAND='bundle exec rake "preview_qa:backdate_purchase[<purchase external_id>]"' \
  ./console.sh -w
```

The available tasks (all need the writable connection except `inspect_subscription`, which is read-only):

```shell
# Backdate a subscription purchase past its billing period so a renewal charge is due
bundle exec rake "preview_qa:backdate_purchase[<purchase external_id>]"

# Remove the e-mandate linkage from the card charged for a subscription (Indian card QA)
bundle exec rake "preview_qa:clear_mandate[<subscription external_id>]"

# Seed a job into the Sidekiq dead set (morgue)
bundle exec rake "preview_qa:seed_dead_job[RecurringChargeWorker,123]"

# Run a worker inline, e.g. to force a renewal charge attempt
bundle exec rake "preview_qa:run_worker[RecurringChargeWorker,123]"

# Inspect a subscription after a QA run: renewal timing, mandate linkage, recent charges (read-only)
bundle exec rake "preview_qa:inspect_subscription[<subscription external_id>]"
```

Record ids can be passed as either database ids or external ids. If a QA scenario you need isn't covered, add a task to the namespace (with specs) rather than shipping a temporary hook in your feature PR.
