# frozen_string_literal: true

class HealthcheckController < ApplicationController
  def index
    render plain: "healthcheck"
  end

  def sidekiq
    enqueued_jobs_above_limit = SIDEKIQ_QUEUE_LIMITS.any? do |queue, limit|
      Sidekiq::Queue.new(queue).size > limit
    end

    enqueued_jobs_above_limit ||= Sidekiq::RetrySet.new.size > SIDEKIQ_RETRIES_LIMIT
    enqueued_jobs_above_limit ||= Sidekiq::DeadSet.new.size > SIDEKIQ_DEAD_LIMIT

    status = enqueued_jobs_above_limit ? :service_unavailable : :ok

    render plain: "Sidekiq: #{status}", status:
  end

  SIDEKIQ_QUEUE_LIMITS = { critical: 12_000 }
  SIDEKIQ_RETRIES_LIMIT = 20_000
  SIDEKIQ_DEAD_LIMIT = 10_000
  private_constant :SIDEKIQ_QUEUE_LIMITS, :SIDEKIQ_RETRIES_LIMIT, :SIDEKIQ_DEAD_LIMIT
end
