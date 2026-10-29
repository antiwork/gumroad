# frozen_string_literal: true

class Products::WaitlistEmailsController < Sellers::BaseController
  def create
    authorize Installment, :create?
    product = current_seller.products.visible.find_by(unique_permalink: params[:product_id]) || e404
    return render json: { success: false }, status: :unprocessable_entity unless current_seller.eligible_to_send_emails?

    installment = WaitlistLaunchEmail.new(product:).find_or_create_email!
    render json: { success: true, edit_url: edit_email_path(installment.external_id) }
  rescue ActiveRecord::RecordInvalid => e
    # The sending limit still applies to accounts the eligibility check lets through, such as team accounts.
    render json: { success: false, error: helpers.strip_tags(e.record.errors.full_messages.to_sentence) }, status: :unprocessable_entity
  end
end
