# frozen_string_literal: true

class BackfillAudienceMembersIndexJob
  include Sidekiq::Job
  sidekiq_options queue: :mongo, retry: 5, lock: :until_executed

  def perform(start_id, end_id, seller_id = nil, batch_size = Onetime::BackfillAudienceMembersIndex::BATCH_SIZE)
    Onetime::BackfillAudienceMembersIndex.new(batch_size:, seller_id:).index_range(start_id, end_id)
  end
end
