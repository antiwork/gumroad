# frozen_string_literal: true

class ExpireTranscodedVideosJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 5

  BATCH_SIZE = 100

  def perform
    recentness_limit = $redis.get(RedisKey.transcoded_videos_recentness_limit_in_months)
    recentness_limit ||= 12 * 100 # 100 years => do not expire by default
    recentness_limit = recentness_limit.to_i.months

    loop do
      ReplicaLagWatcher.watch
      records = TranscodedVideo.alive.where(last_accessed_at: .. recentness_limit.ago).limit(BATCH_SIZE).load
      break if records.empty?
      records.each(&:mark_deleted!)
    end
  end
end
