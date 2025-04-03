# frozen_string_literal: true

class CancelPreorderWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(preorder_id)
    preorder = Preorder.find_by(id: preorder_id)
    return unless preorder.is_authorization_successful?

    preorder.mark_cancelled!(auto_cancelled: true)
  end
end
