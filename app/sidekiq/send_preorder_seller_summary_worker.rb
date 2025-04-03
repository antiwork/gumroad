# frozen_string_literal: true

class SendPreorderSellerSummaryWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  MAX_ATTEMPTS_TO_WAIT_FOR_ALL_CHARGED = 72 # roughly 24h, but could be longer if the queue is backed up
  WAIT_PERIOD = 20.minutes

  def perform(preorder_link_id, attempts = 0)
    if attempts >= MAX_ATTEMPTS_TO_WAIT_FOR_ALL_CHARGED
      notify_bugsnag_and_raise "Timed out waiting for all preorders to be charged. PreorderLink: #{preorder_link_id}."
    end

    preorder_link = PreorderLink.find(preorder_link_id)
    preorders = preorder_link.preorders.authorization_successful
    are_all_preorders_charged = preorders.joins(:purchases).merge(Purchase.not_in_progress)
                                         .group("preorders.id").having("count(*) = 1").count("preorders.id")
                                         .empty?

    if are_all_preorders_charged
      ContactingCreatorMailer.preorder_summary(preorder_link_id).deliver_later(queue: "critical")
    else
      # We're not done charging the cards. Try again later.
      SendPreorderSellerSummaryWorker.perform_in(WAIT_PERIOD, preorder_link_id, attempts + 1)
    end
  end

  private
    def notify_bugsnag_and_raise(error_message)
      Bugsnag.notify(error_message)
      raise error_message
    end
end
