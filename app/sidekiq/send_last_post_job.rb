# frozen_string_literal: true

class SendLastPostJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(purchase_id)
    purchase = Purchase.find(purchase_id)
    # Honor the customer's unsubscribe: skip the welcome "last post" email when
    # the purchase has can_contact disabled (e.g. the buyer unchecked email
    # updates at checkout, or unsubscribed before this job ran).
    return unless purchase.can_contact?

    subscription = purchase.subscription

    posts = Installment.emailable_posts_for_purchase(purchase:).order(published_at: :desc)
    post = posts.find { _1.purchase_passes_filters(purchase) }
    return if post.nil?

    SentPostEmail.ensure_uniqueness(post:, email: purchase.email) do
      recipient = { email: purchase.email, purchase:, subscription: }
      recipient[:url_redirect] = post.generate_url_redirect_for_subscription(subscription) if post.has_files?
      PostEmailApi.process(post:, recipients: [recipient])
    end
  end
end
