# frozen_string_literal: true

class Radar::RemoveValueListItemJob
  include Sidekiq::Job

  # Not critical: that queue is receipt email only, and seconds of latency is nothing against the
  # 24h this replaces. Locked because unblock_buyer! clears the same email row up to four times.
  sidekiq_options queue: "default", retry: 5, lock: :until_executed

  def perform(platform_block_id)
    platform_block = PlatformBlock.find_by(id: platform_block_id)
    return if platform_block.nil?

    Radar::ValueListSyncService.new.remove_block(platform_block)
  end
end
