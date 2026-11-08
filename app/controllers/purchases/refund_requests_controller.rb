# frozen_string_literal: true

class Purchases::RefundRequestsController < ApplicationController
  layout "inertia"

  SECURE_ID_SCOPE = "refund_request"
  LINK_EXPIRY = 6.months

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
      @purchase = Purchase.find_by_secure_external_id(params[:purchase_id], scope: SECURE_ID_SCOPE)
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
      {
        purchase_route_id: params[:purchase_id],
        product_name: @purchase.link.name,
        formatted_price: @purchase.formatted_display_price,
        escalation_business_days: PurchaseRefundRequest::ESCALATION_BUSINESS_DAYS,
        max_message_length: PurchaseRefundRequest::MAX_MESSAGE_LENGTH,
        reasons: PurchaseRefundRequest::REASON_LABELS.map { |value, label| { value:, label: } },
        refund_request: refund_request && {
          state: displayed_state(refund_request),
          email: refund_request.email,
          reason_label: PurchaseRefundRequest::REASON_LABELS[refund_request.reason],
        },
        ineligibility: ineligibility,
      }
    end

    # The purchase is the source of truth if the refund/chargeback sync missed this row.
    def displayed_state(refund_request)
      return "refunded" if @purchase.refunded?
      return "expired" if @purchase.chargedback? && refund_request.state != "refunded"
      return "expired" if refund_request.state_refunded?

      refund_request.state
    end

    def ineligibility
      return if PurchaseRefundRequest.purchase_eligible?(@purchase)
      return "refunded" if @purchase.refunded?
      return "partially_refunded" if @purchase.stripe_partially_refunded?
      return "chargedback" if @purchase.chargedback?

      "other"
    end
end
