# frozen_string_literal: true

class ExpireStampedPdfsJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 5

  RECENTNESS_LIMIT = 3.months
  BATCH_SIZE = 100

  def perform
    loop do
      ReplicaLagWatcher.watch
      records = StampedPdf.alive.includes(:url_redirect, :product_file).where(created_at: .. RECENTNESS_LIMIT.ago).limit(BATCH_SIZE).load
      break if records.empty?
      records.each(&:mark_deleted!)
    end
  end
end
