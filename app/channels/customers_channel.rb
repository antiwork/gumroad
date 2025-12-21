# frozen_string_literal: true

class CustomersChannel < ApplicationCable::Channel
  MISSED_POSTS_JOB_COMPLETE_TYPE = "missed_posts_job_complete"
  MISSED_POSTS_JOB_FAILED_TYPE = "missed_posts_job_failed"

  MESSAGE_TEMPLATES = {
    MISSED_POSTS_JOB_COMPLETE_TYPE => "Missed emails for workflow \"%{workflow_name}\" were sent to %{email}",
    MISSED_POSTS_JOB_FAILED_TYPE => "Failed to send missed emails for workflow \"%{workflow_name}\" to %{email}. Please try again in some time."
  }.freeze

  def subscribed
    return reject unless params[:purchase_id].present?
    return reject unless current_user.present?

    purchase = Purchase.find_by_external_id(params[:purchase_id])
    return reject unless purchase.present?

    return reject unless Audience::PurchasePolicy.new(
      SellerContext.new(user: current_user, seller: purchase.seller),
      purchase
    ).send_missed_posts?

    stream_for "user_#{current_user.external_id}"
  end

  def self.broadcast_missed_posts_message!(purchase_id, workflow_id, type)
    purchase = Purchase.find_by_external_id!(purchase_id)

    message = MESSAGE_TEMPLATES[type] % {
      workflow_name: workflow_id.present? ? purchase.seller.workflows.alive.published.find_by_external_id!(workflow_id).name : "All missed emails",
      email: purchase.email
    }

    begin
      broadcast_to(
        "user_#{purchase.seller.external_id}",
        {
          type:,
          purchase_id: purchase.external_id,
          workflow_id: workflow_id,
          message:,
        }.compact,
      )
    rescue => e
      Rails.logger.error("Failed to broadcast message to customers channel: #{e.message}")
      Bugsnag.notify(e)
      raise e
    end
  end
end
