# frozen_string_literal: true

class Purchases::RefundRequestsController < ApplicationController
  layout "inertia"

  before_action :set_purchase
  before_action :check_feature_flag
  # The signed token is the URL itself: keep it out of shared caches and Referer headers.
  before_action :set_no_store_and_referrer_policy

  def show
    set_meta_tag(title: "Request a refund")
    set_noindex_header

    render inertia: "Purchases/RefundRequest/Show", props: page_props
  end

  def create
    reason = params[:reason].to_s
    unless PurchaseRefundRequest::REASONS.include?(reason)
      return redirect_to purchase_refund_request_path(params[:purchase_id]), alert: "Please select a reason for your refund request.", status: :see_other
    end

    # Same purchase lock the refund paths take, so a refund committing concurrently
    # either makes this purchase ineligible or sees and closes the new row.
    @purchase.with_lock do
      next if PurchaseRefundRequest.open_for(@purchase).present?
      next unless PurchaseRefundRequest.purchase_eligible?(@purchase)

      PurchaseRefundRequest.create!(
        purchase: @purchase,
        email: @purchase.email,
        reason:,
        message: params[:message].to_s.strip.first(PurchaseRefundRequest::MAX_MESSAGE_LENGTH).presence,
      )
    end

    # The show page renders whatever the purchase now has: the new or existing
    # request, or why it isn't eligible.
    redirect_to purchase_refund_request_path(params[:purchase_id]), status: :see_other
  end

  private
    def set_purchase
      @purchase = Purchase.find_by_secure_external_id(params[:purchase_id], scope: PurchaseRefundRequest::SECURE_ID_SCOPE)
      e404 if @purchase.nil?
    end

    def check_feature_flag
      e404 unless Feature.active?(:buyer_refund_requests, @purchase.seller)
    end

    def set_no_store_and_referrer_policy
      response.headers["Cache-Control"] = "no-store"
      response.headers["Referrer-Policy"] = "no-referrer"
    end

    def page_props
      refund_request = PurchaseRefundRequest.where(purchase_id: @purchase.id).order(:id).last
      ineligibility = PurchaseRefundRequest.ineligibility(@purchase)
      # A request made now would get this deadline; an existing one keeps its own.
      respond_by = refund_request&.escalation_deadline || PurchaseRefundRequest.escalation_deadline_from(Time.current)
      {
        purchase_route_id: params[:purchase_id],
        product_name: @purchase.link.name,
        creator_name: @purchase.seller.name_or_username,
        formatted_price: @purchase.formatted_display_price,
        respond_by: respond_by.strftime(PurchaseRefundRequest::DATE_FORMAT),
        max_message_length: PurchaseRefundRequest::MAX_MESSAGE_LENGTH,
        reasons: PurchaseRefundRequest::REASON_LABELS.map { |value, label| { value:, label: } },
        refund_request: refund_request && {
          state: displayed_state(refund_request),
          email: refund_request.email,
          reason_label: PurchaseRefundRequest::REASON_LABELS[refund_request.reason],
        },
        ineligibility:,
        refund_window_ended_on: (PurchaseRefundRequest.refund_window_end(@purchase)&.strftime(PurchaseRefundRequest::DATE_FORMAT) if ineligibility == "outside_window"),
      }
    end

    # The purchase is the source of truth if the refund/chargeback sync missed this row.
    def displayed_state(refund_request)
      return "refunded" if @purchase.refunded?
      return "expired" if @purchase.chargedback? && refund_request.state != "refunded"
      return "expired" if refund_request.state_refunded?

      refund_request.state
    end
end
