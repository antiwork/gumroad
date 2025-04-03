# frozen_string_literal: true

class DeleteUnusedPublicFilesJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  def perform
    PublicFile
      .alive
      .with_attached_file
      .where("scheduled_for_deletion_at < ?", Time.current)
      .find_in_batches do |batch|
        ReplicaLagWatcher.watch

        batch.each do |public_file|
          ActiveRecord::Base.transaction do
            public_file.mark_deleted!

            blob = public_file.blob
            next unless blob
            next if ActiveStorage::Attachment.where(blob_id: blob.id).where.not(record: public_file).exists?

            public_file.file.purge_later
          end
        end
      end
  end
end
