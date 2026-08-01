# frozen_string_literal: true

%w[
  .ruby-version
  .rbenv-vars
  tmp/restart.txt
  tmp/caching-dev.txt
  .env
  .env.local
  .env.development
  .env.development.local
  .env.test
  .env.test.local
].each { |path| Spring.watch(path) }

# Spring preloads once per checkout, so the Redis block leased at boot belongs to the
# server and every command forked from it would inherit the same one. Re-lease per command,
# which also has to repoint the stores that connected at boot.
Spring.after_fork { TestRedisIsolation.reinstall_after_fork! if defined?(TestRedisIsolation) }
