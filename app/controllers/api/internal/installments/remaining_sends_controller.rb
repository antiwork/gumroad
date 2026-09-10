# frozen_string_literal: true

class Api::Internal::Installments::RemainingSendsController < Api::Internal::BaseController
  before_action :authenticate_user!
  before_action :set_installment
  after_action :verify_authorized

  # Resumes an incomplete send at the seller's request. The job skips everyone who already
  # received the email, so this cannot double-send; the guards below only keep two senders
  # from running at once.
  def create
    authorize @installment, :send_to_remaining?

    blast = @installment.latest_regular_blast
    unless blast&.delivery_status == "incomplete"
      return render json: { success: false, error: "This email is not waiting on any recipients." }, status: :unprocessable_entity
    end
    if AlertOnStalledPostEmailBlastsJob.sender_visible?(blast.id)
      return render json: { success: false, error: "This email is already sending. Check back in a few hours." }, status: :unprocessable_entity
    end
    # The monitor's own once-per-window marker, so the seller and the monitor cannot both enqueue.
    marker = RedisKey.stalled_blast_auto_resumed(blast.id)
    unless $redis.set(marker, "seller:#{current_seller.id}", nx: true, ex: AlertOnStalledPostEmailBlastsJob::STALL_THRESHOLD.to_i)
      return render json: { success: false, error: "A send was started recently. Check back in a few hours." }, status: :unprocessable_entity
    end

    SendPostBlastEmailsJob.perform_async(blast.id)
    render json: { success: true }
  end

  private
    def set_installment
      @installment = current_seller.installments.alive.published.not_workflow_installment.find_by_external_id(params[:id])
      (skip_authorization and e404_json) if @installment.nil?
    end
end
