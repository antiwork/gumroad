# frozen_string_literal: true

class CancelSubscriptionsForProductWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(product_id)
    product = Link.find(product_id)
    return unless product.deleted? # user undid product deletion

    product.subscriptions.active.each(&:cancel_effective_immediately!)
    ContactingCreatorMailer.subscription_product_deleted(product_id).deliver_later(queue: "critical")
  end
end
