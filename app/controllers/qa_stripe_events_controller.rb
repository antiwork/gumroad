# frozen_string_literal: true

# TEMP: preview-app QA endpoint for driving Stripe refund webhook events through the
# real handler pipeline (revert before merge — same lifecycle as the other QA
# scaffolding commits). Stripe signs production webhooks and we can't mint signed
# events for a preview host, so this endpoint lets QA inject a test-shaped
# refund.updated / refund.failed event that enters the exact same code path as a real
# webhook (StripeEventHandler.handle_stripe_event).
#
# Guarded: only mounts on preview/staging (see routes), requires a logged-in admin.
class QaStripeEventsController < ApplicationController
  before_action :require_admin!

  def create
    raise ActionController::RoutingError, "Not Found" unless Rails.env.staging? || ENV["PREVIEW_APP"].present?

    event_type = params.require(:event_type)
    raise ArgumentError, "only refund.* event types are allowed" unless event_type.start_with?("refund.")

    event_params = {
      "id" => "evt_qa_#{SecureRandom.hex(8)}",
      "type" => event_type,
      "created" => Time.current.to_i,
      "livemode" => false,
      "data" => {
        "object" => {
          "id" => params.require(:refund_id),
          "object" => "refund",
          "charge" => params.require(:charge_id),
          "status" => params.require(:refund_status),
          "amount" => params[:amount].to_i,
          "currency" => params[:currency] || "eur",
          "failure_reason" => params[:failure_reason],
        },
      },
    }

    StripeEventHandler.new(event_params).handle_stripe_event

    render json: { ok: true, event_type:, refund_id: params[:refund_id] }
  end

  private
    def require_admin!
      e404 unless logged_in_user&.is_team_member?
    end
end
