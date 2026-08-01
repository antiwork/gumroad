# frozen_string_literal: true

class Radar::RemoveValueListItemJob
  include Sidekiq::Job

  sidekiq_options queue: "critical", retry: 5

  def perform(platform_block_id)
    platform_block = PlatformBlock.find_by(id: platform_block_id)
    return if platform_block.nil?

    Radar::ValueListSyncService.new.remove_block(platform_block)
  end
end
