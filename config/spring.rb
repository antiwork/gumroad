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

# Spring preloads the app once per checkout and forks each command from it, so every
# command inherits the one Redis block config/test_redis_isolation.rb leased at preload.
# A fork cannot re-lease: the stores connected before it existed. Registering here makes a
# second concurrent command say so instead of silently flushing the first one's keys.
Spring.after_fork do
  TestRedisIsolation.register_command! if defined?(TestRedisIsolation)
end
