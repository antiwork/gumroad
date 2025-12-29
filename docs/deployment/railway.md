# Deploying to Railway

Railway is a modern infrastructure platform that builds and deploys your code. It works great for Rails applications.

## Prerequisites

- [Railway CLI](https://docs.railway.app/guides/cli) installed (optional, can also use the web dashboard).
- A [Railway account](https://railway.app/).
- A GitHub repository with your application code.

## Step 1: Create a New Project

1. Go to your [Railway Dashboard](https://railway.app/dashboard).
2. Click **+ New Project**.
3. Select **Deploy from GitHub repo**.
4. Choose your repository.

## Step 2: Add Services (Database & Redis)

Railway allows you to add plugins easily.

1. In your project view, click **New**.
2. Select **Database** -> **Add PostgreSQL**.
3. Click **New** again.
4. Select **Database** -> **Add Redis**.

These will be automatically linked to your environment variables usually, but verifiy the variable names matches what Rails expects (e.g. `DATABASE_URL` and `REDIS_URL`).

## Step 3: Configure Environment Variables

1. Click on your application service (the Rails app).
2. Go to the **Variables** tab.
3. Add the required environment variables:
   - `RAILS_ENV`: `production`
   - `RAILS_MASTER_KEY`: Your master key contents.
   - `DATABASE_URL`: `${PostgreSQL.DATABASE_URL}` (Railway's variable reference syntax).
   - `REDIS_URL`: `${Redis.REDIS_URL}`.
   - Add any other secrets (AWS, Stripe, etc).

## Step 4: Configure Start Command

In the **Settings** tab of your application service, ensure the **Start Command** is set correct. For a standard Rails app using a web server and Sidekiq, you might need a `Procfile` based deployment or specify the command.

If deploying just the web process:
```bash
bin/rails server -b 0.0.0.0 -p $PORT
```

To run Sidekiq alongside (or ideally as a separate service in Railway), define a separate service with the start command:
```bash
bundle exec sidekiq
```

## Step 5: Build and Deploy

Railway automatically builds and deploys when you push to your connected GitHub branch. You can monitor the **Deployments** tab for logs.

## Step 6: Database Migration

Once the build is successful, you need to run migrations.

1. Go to the **Settings** tab (or accessible via CLI).
2. You can set a **Deploy Command** (runs before start) or manually run via CLI:
   ```bash
   railway run rails db:migrate
   ```

*Note: It is recommended to add the build command `rails db:migrate` to the deploy phase if safe, or execute manually for the first run.*

## Troubleshooting

View logs in the dashboard by clicking on the deployment query.

```bash
railway logs
```
