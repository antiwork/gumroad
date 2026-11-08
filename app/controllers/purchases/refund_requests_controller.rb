# frozen_string_literal: true

# Buyer-facing refund request page, reached from a signed link in the purchase
# receipt email. No login: the signed, scoped token proves the visitor holds
# the receipt, which is the same trust the unsubscribe and dispute-evidence
# links rely on. Nothing on this surface moves money — it records the request
# and notifies the seller and support, who act through the existing refund
# action.
class Purchases::RefundRequestsController < ApplicationController
  SECURE_ID_SCOPE = "refund_request"

  before_action :hide_layouts
  before_action :set_purchase
  before_action :check_feature_flag

  def show
    @refund_request = latest_refund_request
    @eligible = PurchaseRefundRequest.purchase_eligible?(@purchase)
  end

  def create
    # A buyer who posts twice (double submit, returning later) gets the request
    # they already filed, not an error and not a second one.
    @refund_request = PurchaseRefundRequest.open_for(@purchase)

    if @refund_request.nil?
      return render_ineligible unless PurchaseRefundRequest.purchase_eligible?(@purchase)

      begin
        @refund_request = PurchaseRefundRequest.create!(
          purchase: @purchase,
          email: @purchase.email,
          reason: permitted_reason,
          message: params[:message].to_s.strip.first(PurchaseRefundRequest::MAX_MESSAGE_LENGTH).presence,
        )
      rescue ActiveRecord::RecordNotUnique
        # Two concurrent submits raced past the open_for read; the unique index
        # kept one row, so return it.
        @refund_request = PurchaseRefundRequest.open_for(@purchase)
      rescue ActiveRecord::RecordInvalid
        flash[:alert] = "Please select a reason for your refund request."
        return redirect_to purchase_refund_request_path(params[:purchase_id])
      end

      if @refund_request.present?
        ContactingCreatorMailer.refund_requested(@refund_request.id).deliver_later
        notify_support(@refund_request)
      end
    end

    redirect_to purchase_refund_request_path(params[:purchase_id])
  end

  private
    def set_purchase
      @purchase = Purchase.find_by_secure_external_id(params[:purchase_id], scope: SECURE_ID_SCOPE)
      e404 if @purchase.nil?
    end

    # Flag is per-seller so the rollout can start with volunteers. Off means
    # the page does not exist: same 404 as a bad token.
    def check_feature_flag
      e404 unless Feature.active?(:buyer_refund_requests, @purchase.seller)
    end

    def permitted_reason
      reason = params[:reason].to_s
      PurchaseRefundRequest::REASONS.include?(reason) ? reason : nil
    end

    def render_ineligible
      @refund_request = latest_refund_request
      @eligible = false
      render :show
    end

    def latest_refund_request
      PurchaseRefundRequest.where(purchase_id: @purchase.id).order(:id).last
    end

    # Same support pipeline as the Help Center contact form: an email to the
    # support inbox that Helper ingests, reply-to the buyer.
    def notify_support(refund_request)
      SupportContactMailer.contact_form(
        email: refund_request.email,
        category: "purchases & refunds",
        message: support_message(refund_request),
      ).deliver_later
    end

    def support_message(refund_request)
      <<~MESSAGE
        Buyer refund request ##{refund_request.id} (automated copy for visibility; the seller was notified and has 2 business days to respond).

        Purchase: #{@purchase.external_id}
        Product: #{@purchase.link.name}
        Amount: #{@purchase.formatted_display_price}
        Reason: #{PurchaseRefundRequest::REASON_LABELS[refund_request.reason]}
        Message: #{refund_request.message.presence || "(none)"}
      MESSAGE
    end
end
