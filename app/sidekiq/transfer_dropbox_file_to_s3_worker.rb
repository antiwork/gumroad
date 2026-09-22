# frozen_string_literal: true

class TransferDropboxFileToS3Worker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :long

  def perform(dropbox_file_id)
    # The newly created row and its cancellation state may not have replicated yet.
    ApplicationRecord.connected_to(role: :writing) do
      dropbox_file = DropboxFile.find(dropbox_file_id)
      dropbox_file.transfer_to_s3
    end
  end
end
