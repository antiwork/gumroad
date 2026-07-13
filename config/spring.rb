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
