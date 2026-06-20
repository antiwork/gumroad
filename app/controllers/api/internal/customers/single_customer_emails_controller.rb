# frozen_string_literal: true

class Api::Internal::Customers::SingleCustomerEmailsController < Api::Internal::BaseController
  before_action :authenticate_user!
  after_action :verify_authorized

  def create
    permitted_params = single_customer_email_params
    purchase = current_seller.sales.find_by_external_id!(permitted_params[:purchase_id])

    authorize Installment, :send_for_purchase?

    return render_error("Customer not found.", :not_found) unless seller_can_email_customers?
    return render_error("Customer cannot be emailed.", :unprocessable_entity) unless purchase.can_contact? && EmailFormatValidator.valid?(purchase.email) && purchase.giftee_email.blank?
    return render_error("You are not eligible to send emails.", :unauthorized) unless current_seller.eligible_to_send_emails?
    return render_error("Please set a title.", :unprocessable_entity) if permitted_params[:name].blank?
    return render_error("Please include a message as part of the update.", :unprocessable_entity) if permitted_params[:message].blank?

    installment = ActiveRecord::Base.transaction do
      record = current_seller.installments.build(
        name: permitted_params[:name],
        message: permitted_params[:message],
        installment_type: Installment::SELLER_TYPE,
        send_emails: true,
        shown_on_profile: false,
        allow_comments: false
      )
      record.save!
      SaveFilesService.perform(record, files_params(permitted_params))
      record.publish!
      blast_timestamp = Time.current
      PostEmailBlast.create!(
        post: record,
        requested_at: blast_timestamp,
        started_at: blast_timestamp,
        completed_at: blast_timestamp
      )
      record
    end

    # Deliver AFTER the transaction commits. PostEmailApi.process hits an
    # external provider (Resend/SendGrid), so it must not run inside the DB
    # transaction: a post-send rollback would orphan an already-delivered
    # email, and a retry could double-send. The Rails.cache guard provides
    # idempotency, mirroring PostsController#send_for_purchase.
    Rails.cache.fetch("single_customer_email:#{installment.id}:#{purchase.id}", expires_in: 8.hours) do
      CreatorContactingCustomersEmailInfo.where(purchase:, installment:).destroy_all
      PostEmailApi.process(
        post: installment,
        recipients: [
          {
            email: purchase.email,
            purchase:,
            url_redirect: purchase.url_redirect,
            subscription: purchase.subscription,
          }.compact_blank
        ]
      )
      true
    end

    render json: { success: true }
  rescue ActiveRecord::RecordNotFound
    authorize Installment, :send_for_purchase?
    render_error("Customer not found.", :not_found)
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.first || e.message, :unprocessable_entity)
  rescue Installment::InstallmentInvalid => e
    render_error(e.message, :unprocessable_entity)
  end

  private
    def single_customer_email_params
      params.permit(:purchase_id, :name, :message, files: [:external_id, :position, :url, :stream_only, subtitle_files: [:url, :language]])
    end

    def files_params(permitted_params)
      { files: permitted_params[:files] || [] }.with_indifferent_access
    end

    def seller_can_email_customers?
      UserPresenter.new(user: current_seller).audience_types.include?(:customers)
    end

    def render_error(message, status)
      render json: { success: false, message: }, status:
    end
end
