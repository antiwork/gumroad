# Deploying Gumroad on Railway

This guide explains how to deploy the Gumroad application on Railway using managed services.

---

## Prerequisites

Before you begin, ensure you have:

- A Railway account
- Git installed
- A fork of the Gumroad repository
- PostgreSQL database
- Redis instance
- Node.js and Ruby installed locally (for setup)

---

## 1. Create a Railway Project

1. Log in to https://railway.app
2. Click **New Project**
3. Select **Deploy from GitHub Repo**
4. Choose your fork of the Gumroad repository

---

## 2. Add Required Services

### PostgreSQL
- Click **Add Service**
- Select **PostgreSQL**
- Railway will automatically provision a database

### Redis
- Click **Add Service**
- Select **Redis**

---

## 3. Configure Environment Variables

Go to **Project Settings → Variables** and add:

-RAILS_ENV=production
-RACK_ENV=production
-SECRET_KEY_BASE=<generate using rails secret>
-DATABASE_URL=<provided by Railway PostgreSQL>
-REDIS_URL=<provided by Railway Redis>

---

## 4. Configure Build & Start Commands

In **Project Settings → Deploy**:

**Build Command**

-bundle install && yarn install

**Start Command**

---

## 5. Run Database Migrations

After deployment, open the Railway terminal and run:

-bundle exec rails db:migrate

---

## 6. Verify Deployment

- Once deployment completes, Railway will provide a public URL
- Open the URL to verify the application is running

---

## Notes

- Monitor logs from the Railway dashboard
- Ensure all required environment variables are set
- Review Railway pricing before production use

