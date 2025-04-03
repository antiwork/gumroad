# frozen_string_literal: true

class RenameProductFileWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(product_file_id)
    file = ProductFile.find_by(id: product_file_id)
    return if file.nil? || file.deleted_from_cdn?

    file.rename_in_storage
  end
end
