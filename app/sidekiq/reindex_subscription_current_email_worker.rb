# frozen_string_literal: true

# Refreshes the `subscription_current_email` search field on every membership the user buys, so a
# seller can find the member in Customers by the address the member uses now rather than only the
# one they signed up with.
class ReindexSubscriptionCurrentEmailWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(user_id)
    user = User.find(user_id)

    # Only the original purchase is reachable from Customers search; the recurring charges already
    # carry the new address themselves.
    Purchase.where(subscription_id: user.subscriptions.select(:id))
            .is_original_subscription_purchase
            .select(:id)
            .find_each do |purchase|
      ElasticsearchIndexerWorker.perform_async("update", {
                                                 "record_id" => purchase.id,
                                                 "class_name" => "Purchase",
                                                 "fields" => ["subscription_current_email"],
                                               })
    end
  end
end
