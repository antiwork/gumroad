# frozen_string_literal: true

class Radar::AddValueListItemJob
  include Sidekiq::Job

  # The mirror of RemoveValueListItemJob, and the reason the removal path can get away with an
  # unsynchronised final check: whichever way an add/remove interleaving falls, the add's own job
  # re-asserts the item within seconds rather than leaving it to tomorrow's sync.
  sidekiq_options queue: "default", retry: 5, lock: :until_executed

  def perform(platform_block_id)
    platform_block = PlatformBlock.find_by(id: platform_block_id)
    return if platform_block.nil?

    Radar::ValueListSyncService.new.add_block(platform_block)
  end
end
