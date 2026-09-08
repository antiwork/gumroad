# frozen_string_literal: true

# Be sure to restart your server when you modify this file.
#
# This file eases your Rails 7.2 framework defaults upgrade.
#
# Uncomment each configuration one by one to switch to the new default.
# Once your application is ready to run with all new defaults, you can remove
# this file and set the `config.load_defaults` to `7.2`.
#
# Read the Guide for Upgrading Ruby on Rails for more info on each option.
# https://guides.rubyonrails.org/upgrading_ruby_on_rails.html
#
# `config.load_defaults` is still `7.0` (see new_framework_defaults_7_1.rb, which is
# also unfinished). These are every behaviour change `load_defaults 7.2` would make on
# top of 7.1 — the Postgres one is omitted, we are MySQL only.

###
# Enable YJIT.
#
# Worth real throughput, but it trades it for resident memory, and the web hosts have
# no headroom to trade: puma's cgroup limit sits at 6000MB on a 7769MB box and the last
# raise past that cost us the page cache (gumroad-deployment#76). Measure RSS per worker
# on a canary before turning this on.
#++
# Rails.application.config.yjit = true

###
# Enqueue Active Job jobs after the current transaction commits, per the adapter's
# preference.
#
# Not a no-op: sidekiq 7.3.0 does not define `enqueue_after_transaction_commit?`, so
# Rails' own SidekiqAdapter is in play and inherits AbstractAdapter's `true`. Scope is
# tiny — `app/jobs/send_membership_price_update_email_job.rb` is the only Active Job
# class in the repo; everything else is `Sidekiq::Job.perform_async`, which Active Job
# does not touch. Deferring to after-commit is the safer behaviour, so this is a
# candidate to enable on its own once someone confirms that job's callers.
#++
# Rails.application.config.active_job.enqueue_after_transaction_commit = :default

###
# The content types Active Storage will serve as-is instead of converting to PNG when
# processing a variant.
#
# This *widens* the list: the current default (activestorage engine.rb) is png/jpeg/gif,
# and 7.2 adds image/webp. So a WebP thumbnail would start being served as WebP rather
# than converted. That changes bytes a buyer receives for existing product thumbnails
# and previews, so it needs the before/after any visual change needs.
#++
# Rails.application.config.active_storage.web_image_content_types = %w( image/png image/jpeg image/gif image/webp )

###
# Raise on a migration whose version timestamp is in the future.
#
# Do not enable this without a cleanup first: the repo already contains future-dated
# migration versions, which is why new migrations cannot simply use `date -u +%Y%m%d%H%M%S`
# and why `bin/check-migration-versions` exists. Turning this on makes `db:migrate` refuse
# to run at all.
#++
# Rails.application.config.active_record.validate_migration_timestamps = true
