#!/usr/bin/env rake
# frozen_string_literal: true

require_relative "config/application"

Rails.application.load_tasks

# Pin every db: task to the writing role when the proxy is active. Without this, a
# migration's `SELECT ... FROM schema_migrations` is an ordinary read and mysql2_proxy
# routes it to the replica, so a lagging replica can make Rails re-run or skip a
# migration. We cannot get this from the gem's railtie (see the Gemfile note on the
# rack middleware), and its adapter-specific DatabaseTasks class never wins anyway:
# DatabaseTasks#class_for_adapter `detect`s in registration order and Rails registers
# /mysql/ first, which already matches "mysql2_proxy".
if ENV["USE_DB_WORKER_REPLICAS"] == "true"
  require "active_record_proxy_adapters/rake"
  ActiveRecordProxyAdapters::Rake.load_tasks
  ActiveRecordProxyAdapters::Rake.enhance_db_tasks
end
