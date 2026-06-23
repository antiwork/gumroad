# frozen_string_literal: true

require "digest"

class Api::Internal::Customers::SingleCustomerEmailsController < Api::Internal::BaseController
  before_action :authenticate_user!
  after_action :verify_authorized

  def create
    permitted_params = single_customer_email_params
    purchase = current_seller.sales.find_by_external_id!(permitted_params[:purchase_id])

    authorize Installment, :create?

    return render_error("Customer not found.", :not_found) unless seller_can_email_customers?
    return render_error("Customer cannot be emailed.", :unprocessable_entity) unless purchase.can_contact? && EmailFormatValidator.valid?(purchase.email) && purchase.giftee_email.blank?
    return render_error("You are not eligible to send emails.", :unauthorized) unless current_seller.eligible_to_send_emails?
    return render_error("Please set a title.", :unprocessable_entity) if permitted_params[:name].blank?

    installment = find_or_create_installment(purchase, permitted_params)
    deliver_to_purchase(installment, purchase)

    render json: { success: true }
  rescue ActiveRecord::RecordNotFound
    authorize Installment, :create?
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

    # Build the email exactly once per identical request. The key is the request's
    # content digest, not the new installment's id, so a retry reuses the existing
    # installment instead of creating a second one. Creation is deliberately kept
    # separate from delivery: keying them together would let a failed send re-run
    # creation and leave duplicate published installments behind.
    def find_or_create_installment(purchase, permitted_params)
      installment_id = Rails.cache.fetch(single_customer_email_idempotency_key(purchase, permitted_params), expires_in: 8.hours) do
        ActiveRecord::Base.transaction do
          message = SaveContentUpsellsService.new(seller: current_seller, content: permitted_params[:message], old_content: nil).from_html
          installment = current_seller.installments.build(
            name: permitted_params[:name],
            message:,
            installment_type: Installment::SELLER_TYPE,
            send_emails: true,
            shown_on_profile: false,
            allow_comments: false,
            single_recipient_email: true,
            single_recipient_purchase_id: purchase.id
          )
          installment.save!
          SaveFilesService.perform(installment, files_params(permitted_params))
          installment.publish!
          blast_timestamp = Time.current
          PostEmailBlast.create!(
            post: installment,
            requested_at: blast_timestamp,
            started_at: blast_timestamp,
            completed_at: blast_timestamp
          )
          installment.id
        end
      end

      current_seller.installments.find(installment_id)
    end

    # Deliver after the installment is committed and behind its own per-(installment,
    # purchase) idempotency key, mirroring PostsController#send_for_purchase.
    # PostEmailApi.process hits an external provider (Resend/SendGrid), so it must
    # not run inside the creation transaction: a post-send rollback would orphan an
    # already-delivered email. Keying delivery on the installment means a send
    # failure retries only the send, never a second installment, while a delivery
    # that already succeeded is never repeated.
    def deliver_to_purchase(installment, purchase)
      Rails.cache.fetch("post_email:#{installment.id}:#{purchase.id}", expires_in: 8.hours) do
        CreatorContactingCustomersEmailInfo.where(purchase:, installment:).destroy_all
        PostEmailApi.process(
          post: installment,
          recipients: [
            {
              email: purchase.email,
              purchase:,
              url_redirect: installment.delivery_url_redirect_for(purchase),
              subscription: purchase.subscription,
            }.compact_blank
          ]
        )
        true
      end
    end

    def files_params(permitted_params)
      { files: permitted_params[:files] || [] }.with_indifferent_access
    end

    def single_customer_email_idempotency_key(purchase, permitted_params)
      content_digest = Digest::SHA256.hexdigest(
        [
          permitted_params[:name].to_s,
          permitted_params[:message].to_s,
          canonical_idempotency_value(files_params(permitted_params)[:files]).to_json,
        ].join("\x00")
      )

      "single_customer_email:#{current_seller.id}:#{purchase.id}:#{content_digest}"
    end

    def canonical_idempotency_value(value)
      case value
      when ActionController::Parameters
        canonical_idempotency_value(value.to_h)
      when Hash
        value.to_h.transform_keys(&:to_s).sort.to_h.transform_values { |inner_value| canonical_idempotency_value(inner_value) }
      when Array
        value.map { |inner_value| canonical_idempotency_value(inner_value) }
      else
        value
      end
    end

    def seller_can_email_customers?
      UserPresenter.new(user: current_seller).audience_types.include?(:customers)
    end

    def render_error(message, status)
      render json: { success: false, message: }, status:
    end
end
