# frozen_string_literal: true

class Radar::RemoveValueListItemJob
  include Sidekiq::Job

  # `default`, not `critical`: the admin mass-unblock page fans out one job per matching row, each
  # making up to three sequential Stripe calls, and `critical` is reserved for receipt emails.
  # Seconds of queue latency against the 24h this replaces.
  sidekiq_options queue: "default", retry: 5

  def perform(platform_block_id)
    platform_block = PlatformBlock.find_by(id: platform_block_id)
    return if platform_block.nil?

    Radar::ValueListSyncService.new.remove_block(platform_block)
  end
end
