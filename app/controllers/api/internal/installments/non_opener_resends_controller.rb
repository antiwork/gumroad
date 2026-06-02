# frozen_string_literal: true

class Api::Internal::Installments::NonOpenerResendsController < Api::Internal::BaseController
  # A seller may resend a published post to its non-openers at most once per this window,
  # to avoid accidentally re-blasting the same people repeatedly.
  RESEND_THROTTLE = 24.hours

  # Hard lifetime cap on non-opener resends per post. Combined with the 24h throttle
  # this means at most one resend per day, up to three total — after that the same
  # unopened recipients are left alone for good.
  MAX_RESENDS = 3

  before_action :authenticate_user!
  before_action :set_installment
  after_action :verify_authorized

  def show
    authorize @installment, :resend_to_non_openers?

    render json: { count: @installment.unopened_recipients_count }
  end

  def create
    authorize @installment, :resend_to_non_openers?

    if resend_limit_reached?
      return render json: { success: false, error: "You can resend to non-openers up to #{MAX_RESENDS} times per email." },
                    status: :too_many_requests
    end

    if recently_resent?
      return render json: { success: false, error: "You can only resend to non-openers once every 24 hours." },
                    status: :too_many_requests
    end

    count = @installment.unopened_recipients_count
    if count.zero?
      return render json: { success: false, error: "Everyone who was emailed has already opened this." },
                    status: :unprocessable_entity
    end

    blast = PostEmailBlast.create!(
      post: @installment,
      requested_at: Time.current,
      recipient_filter: PostEmailBlast::RECIPIENT_FILTER_UNOPENED
    )
    SendPostBlastEmailsJob.perform_async(blast.id)

    render json: { success: true, count: }
  end

  private
    def set_installment
      @installment = current_seller.installments.alive.find_by_external_id(params[:id])
      (skip_authorization and e404_json) unless @installment&.resendable_to_non_openers?
    end

    def recently_resent?
      @installment.blasts.to_non_openers.where(requested_at: RESEND_THROTTLE.ago..).exists?
    end

    def resend_limit_reached?
      @installment.blasts.to_non_openers.count >= MAX_RESENDS
    end
end
