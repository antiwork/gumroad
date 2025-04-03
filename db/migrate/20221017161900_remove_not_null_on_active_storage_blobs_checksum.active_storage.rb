# frozen_string_literal: true

# This migration comes from active_storage (originally 20211119233751)
class RemoveNotNullOnActiveStorageBlobsChecksum < ActiveRecord::Migration[6.0]
  def change
    Alterity.disable do
      change_column_null(:active_storage_blobs, :checksum, true)
    end
  end
end
