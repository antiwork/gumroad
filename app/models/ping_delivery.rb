# frozen_string_literal: true

# One row per POST attempt to a seller's ping endpoint, written by
# PostToIndividualPingEndpointWorker. Append-only: the ping is fire-and-retry and the worker
# discards the endpoint's answer, so these rows are the only record of what a seller's endpoint
# answered to a given POST.
class PingDelivery < ApplicationRecord
  # How many rows the seller settings list and the admin lookup show.
  MAX_RECENT = 10

  belongs_to :user
  belongs_to :purchase, optional: true
  belongs_to :subscription, optional: true

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  # One shape for both readers (the seller settings list and the admin lookup), so the two cannot
  # drift on what a given attempt's result was.
  def as_props
    {
      id:,
      resource_name:,
      sale_id: purchase&.external_id_numeric&.to_s,
      subscription_id:,
      post_url:,
      attempt:,
      outcome:,
      succeeded:,
      created_at: created_at.as_json,
    }
  end

  private
    def outcome
      return "HTTP #{response_code}" if response_code.present?

      error_class.presence || "No response"
    end
end
