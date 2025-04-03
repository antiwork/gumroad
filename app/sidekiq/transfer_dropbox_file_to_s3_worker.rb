# frozen_string_literal: true

class TransferDropboxFileToS3Worker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(dropbox_file_id)
    dropbox_file = DropboxFile.find(dropbox_file_id)
    dropbox_file.transfer_to_s3
  end
end
