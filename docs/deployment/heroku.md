# Deploying Gumroad on Heroku

This guide explains how to deploy the Gumroad application on Heroku using common managed services.

---

## Prerequisites

Before you begin, make sure you have:

- A Heroku account
- Heroku CLI installed
- Git installed
- A fork of the Gumroad repository
- PostgreSQL / MySQL database credentials
- Redis instance credentials

---

## 1. Create a Heroku App

```bash
heroku create gumroad-app
```

---

## 2. Configure Environment Variables

```bash
heroku config:set RAILS_ENV=production
heroku config:set RACK_ENV=production
heroku config:set SECRET_KEY_BASE=$(rails secret)
```

---

## 3. Add Required Add-ons

```bash
heroku addons:create heroku-postgresql
heroku addons:create heroku-redis
```

---

## 4. Deploy the Application

```bash
git push heroku main
```

---

## 5. Run Database Migrations

```bash
heroku run rails db:migrate
```

---

## 6. Verify Deployment

```bash
heroku open
```

---

## Notes

- Monitor logs using `heroku logs --tail`
- Check Heroku pricing before production use

