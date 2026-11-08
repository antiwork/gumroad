# frozen_string_literal: true

class Purchases::RefundRequestsController < ApplicationController
  SECURE_ID_SCOPE = "refund_request"
  # A revisit only re-enqueues notifications for a request at least this old, so
  # the redirect after create — worker still pending, both stamps still nil —
  # can't pile more jobs on top of the one after_create_commit already enqueued.
  NOTIFICATION_RETRY_GRACE = 10.minutes

  before_action :hide_layouts
  before_action :set_purchase
  before_action :check_feature_flag
  # The signed token is the URL itself; keep it out of shared caches and
  # don't leak it to third parties via the Referer header.
  before_action :set_no_store_and_referrer_policy

  def show
    @refund_request = latest_refund_request
    # A crash or Redis outage after create can leave an open row with unsent
    # notifications; a later revisit re-enqueues them. Not a fresh row, though:
    # the redirect from create arrives while the job enqueued by
    # after_create_commit is usually still pending, and re-enqueueing there is
    # what made the happy path race two jobs for the same request.
    if @refund_request&.notifications_pending? && @refund_request.created_at < NOTIFICATION_RETRY_GRACE.ago
      @refund_request.enqueue_notifications
    end
    @eligible = PurchaseRefundRequest.purchase_eligible?(@purchase)
  end

  def create
    # Lock the purchase so a concurrently-committing refund can't slide between
    # the eligibility read and the insert; the refund callback takes the same
    # lock, so after our insert it will see and close the row.
    @purchase.with_lock do
      @refund_request = PurchaseRefundRequest.open_for(@purchase)
      next if @refund_request.present? # double submit → show the existing one

      unless PurchaseRefundRequest.purchase_eligible?(@purchase)
        @ineligible = true
        next
      end

      begin
        @refund_request = PurchaseRefundRequest.create!(
          purchase: @purchase,
          email: @purchase.email,
          reason: permitted_reason,
          message: params[:message].to_s.strip.first(PurchaseRefundRequest::MAX_MESSAGE_LENGTH).presence,
        )
      rescue ActiveRecord::RecordInvalid
        @invalid = true
      end
    end

    return render_ineligible if @ineligible
    if @invalid
      flash[:alert] = "Please select a reason for your refund request."
      return redirect_to purchase_refund_request_path(params[:purchase_id])
    end

    # Notifications are NOT sent here: after_create_commit enqueues an
    # idempotent worker exactly once, on the submission that created the row.
    redirect_to purchase_refund_request_path(params[:purchase_id])
  end

  private
    def set_purchase
      @purchase = Purchase.find_by_secure_external_id(params[:purchase_id], scope: SECURE_ID_SCOPE)
      e404 if @purchase.nil?
    end

    # Off means the page does not exist: same 404 as a bad token.
    def check_feature_flag
      e404 unless Feature.active?(:buyer_refund_requests, @purchase.seller)
    end

    def set_no_store_and_referrer_policy
      response.headers["Cache-Control"] = "no-store"
      response.headers["Referrer-Policy"] = "no-referrer"
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
end
