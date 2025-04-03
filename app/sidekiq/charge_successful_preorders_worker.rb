# frozen_string_literal: true

class ChargeSuccessfulPreordersWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(preorder_link_id)
    preorder_link = PreorderLink.find_by(id: preorder_link_id)
    preorder_link.preorders.authorization_successful.each do |preorder|
      ChargePreorderWorker.perform_async(preorder.id)
    end

    if preorder_link.preorders.authorization_successful.present?
      SendPreorderSellerSummaryWorker.perform_in(20.minutes, preorder_link_id)
    end
  end
end
