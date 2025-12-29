# Deploying to Heroku

Heroku is a popular Platform as a Service (PaaS) that enables developers to build, run, and operate applications entirely in the cloud. Deploying this Rails application to Heroku is straightforward.

## Prerequisites

- [Heroku CLI](https://devcenter.heroku.com/articles/heroku-cli) installed.
- A Heroku account.
- `git` installed and initialized in your project.

## Step 1: Create a Heroku App

Navigate to your project directory and create a new Heroku application:

```bash
heroku create my-gumroad-clone
```

Replace `my-gumroad-clone` with a unique name for your application.

## Step 2: Add Buildpacks

This application requires both Ruby and Node.js (for assets). Set the buildpacks:

```bash
heroku buildpacks:set heroku/ruby
heroku buildpacks:add --index 1 heroku/nodejs
```

## Step 3: provisioning Add-ons

You will need a database and a Redis instance (for Sidekiq and caching).

### PostgreSQL

```bash
heroku addons:create heroku-postgresql:essential-0
```

### Redis

```bash
heroku addons:create heroku-redis:mini
```

## Step 4: Configure Environment Variables

Set the necessary environment variables. Refer to `.env.example` or your local `.env` file for required keys. Important ones often include:

```bash
heroku config:set RAILS_ENV=production
heroku config:set RAILS_MASTER_KEY=<your-master-key>
# Add other keys as needed, e.g., AWS buckets, Stripe keys, etc.
```

## Step 5: Deploy

Push your code to Heroku:

```bash
git push heroku main
```

## Step 6: Database Setup

Once the deployment finishes, run the migrations:

```bash
heroku run rails db:migrate
```

## Step 7: Scaling Workers

To process background jobs with Sidekiq, you need to scale up the worker dyno:

```bash
heroku ps:scale worker=1
```

## Step 8: Verify Deployment

Open your application in the browser:

```bash
heroku open
```

## Troubleshooting

If something goes wrong, check the logs:

```bash
heroku logs --tail
```
