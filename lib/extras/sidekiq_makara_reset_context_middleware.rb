# frozen_string_literal: true

# There are places in the codebase sticking the DB connection to master instead of replicas.
# Makara, via an included Rack middleware, resets those contexts before each web request (after master_ttl).
# This automatic reset doesn't exist for Sidekiq, so a thread executing many jobs may be stuck on master forever.
# This Sidekiq Middleware ensures that the context is reset before executing each job.
# https://github.com/taskrabbit/makara/blob/dac6be2e01e0511db6715b2b4da65a5490e01cba/README.md#releasing-stuck-connections-clearing-context

class SidekiqMakaraResetContextMiddleware
  def call(worker, job, queue)
    Makara::Context.release_all
    yield
  end
end
