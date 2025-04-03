# frozen_string_literal: true

class Api::Internal::Installments::RecipientCountsController < Api::Internal::BaseController
  before_action :authenticate_user!
  after_action :verify_authorized

  def show
    authorize Installment, :updated_recipient_count?

    permitted_params = params.permit(
      :paid_more_than_cents,
      :paid_less_than_cents,
      :bought_from,
      :installment_type,
      :created_after,
      :created_before,
      bought_products: [],
      bought_variants: [],
      not_bought_products: [],
      not_bought_variants: [],
      affiliate_products: []
    )
    installment = Installment.new(permitted_params)
    installment.seller = current_seller

    render json: {
      audience_count: current_seller.audience_members.count,
      recipient_count: installment.audience_members_count
    }
  end
end
