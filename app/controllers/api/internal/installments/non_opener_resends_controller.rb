# frozen_string_literal: true

class Api::Internal::Installments::NonOpenerResendsController < Api::Internal::BaseController
  RESEND_THROTTLE = 24.hours
  MAX_RESENDS = 3
  IN_FLIGHT_GRACE = 1.hour

  before_action :authenticate_user!
  before_action :set_installment
  after_action :verify_authorized

  def show
    authorize @installment, :resend_to_non_openers?

    count = @installment.unopened_recipients_count
    audience_filtered_out = count.zero? && @installment.unopened_recipient_emails.any?
    render json: { count:, recently_resent: recently_resent?, audience_filtered_out: }
  end

  def create
    authorize @installment, :resend_to_non_openers?

    blast = nil
    error_response = nil
    @installment.with_lock do
      if resend_limit_reached?
        error_response = [{ success: false, error: "You can resend to non-openers up to #{MAX_RESENDS} times per email." }, :unprocessable_entity]
        next
      end

      if recently_resent?
        error_response = [{ success: false, error: "You can only resend to non-openers once every 24 hours." }, :unprocessable_entity]
        next
      end

      @count = @installment.unopened_recipients_count
      if @count.zero?
        message = if @installment.unopened_recipient_emails.any?
          "There are no non-openers left to email — the remaining unopened recipients are no longer eligible for this email's audience."
        else
          "Everyone who was emailed has already opened this."
        end
        error_response = [{ success: false, error: message }, :unprocessable_entity]
        next
      end

      blast = PostEmailBlast.create!(
        post: @installment,
        requested_at: Time.current,
        recipient_filter: PostEmailBlast::RECIPIENT_FILTER_UNOPENED
      )
    end

    if error_response
      json, status = error_response
      return render json:, status:
    end

    SendPostBlastEmailsJob.perform_async(blast.id)
    render json: { success: true, count: @count }
  end

  private
    def set_installment
      @installment = current_seller.installments.alive.find_by_external_id(params[:id])
      (skip_authorization and e404_json) unless @installment&.resendable_to_non_openers?
    end

    def recently_resent?
      scope = @installment.blasts.to_non_openers
      return true if scope.where(completed_at: nil).where(requested_at: IN_FLIGHT_GRACE.ago..).exists?

      scope.where(completed_at: RESEND_THROTTLE.ago..).where(delivery_count: 1..).exists?
    end

    def resend_limit_reached?
      @installment.blasts.to_non_openers.where.not(completed_at: nil).where(delivery_count: 1..).count >= MAX_RESENDS
    end
end
