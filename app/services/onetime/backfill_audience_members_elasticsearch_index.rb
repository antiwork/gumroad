# frozen_string_literal: true

class Onetime::BackfillAudienceMembersElasticsearchIndex < Onetime::Base
  BATCH_SIZE = 5_000

  def initialize(start_id: nil, end_id: nil)
    @start_id = start_id
    @end_id = end_id
  end

  def process
    scope = AudienceMember.all
    scope = scope.where("id >= ?", @start_id) if @start_id.present?
    scope = scope.where("id <= ?", @end_id) if @end_id.present?

    enqueued_count = 0
    scope.find_in_batches(batch_size: BATCH_SIZE) do |batch|
      ReplicaLagWatcher.watch
      batch.each do |audience_member|
        ElasticsearchIndexerWorker.set(queue: "low").perform_async(
          "index",
          "record_id" => audience_member.id,
          "class_name" => "AudienceMember"
        )
        enqueued_count += 1
      end
      Rails.logger.info "Enqueued audience members #{batch.first.id} to #{batch.last.id} (#{enqueued_count} total)"
    end

    Rails.logger.info "Backfill complete. Enqueued #{enqueued_count} index jobs."
  end
end
