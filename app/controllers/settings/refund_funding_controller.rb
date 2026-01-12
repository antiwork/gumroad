# frozen_string_literal: true

class Settings::RefundFundingController < Settings::BaseController
  before_action :authorize

  def show
    render json: refund_funding_data
  end

  def create
    card_data_handling_mode = CardParamsHelper.get_card_data_handling_mode(params)
    card_data_handling_error = CardParamsHelper.check_for_errors(params)

    if card_data_handling_error.present?
      return render json: { success: false, error: card_data_handling_error.error_message }, status: :unprocessable_entity
    end

    chargeable = CardParamsHelper.build_chargeable(params)

    if chargeable.blank?
      return render json: { success: false, error: "Invalid card information" }, status: :unprocessable_entity
    end

    credit_card = CreditCard.create(chargeable, card_data_handling_mode, current_seller)

    if credit_card.persisted?
      current_seller.update!(
        refund_funding_credit_card: credit_card,
        refund_funding_card_name: params[:name_on_card]
      )
      render json: { success: true, **refund_funding_data }
    else
      render json: { success: false, error: credit_card.errors.full_messages.first }, status: :unprocessable_entity
    end
  end

  def destroy
    current_seller.update!(
      refund_funding_credit_card: nil,
      refund_funding_card_name: nil
    )
    render json: { success: true, **refund_funding_data }
  end

  def dismiss_banner
    current_seller.update!(dismissed_refund_payment_method_banner: true)
    render json: { success: true }
  end

  private

  def refund_funding_data
    card = current_seller.refund_funding_credit_card
    {
      enabled: card.present?,
      name_on_card: current_seller.refund_funding_card_name,
      credit_card: card.present? ? {
        visual: card.visual,
        card_type: card.card_type,
        expiry_month: card.expiry_month,
        expiry_year: card.expiry_year
      } : nil,
      show_banner: !current_seller.dismissed_refund_payment_method_banner? && card.blank?
    }
  end

  def authorize
    super([:settings, :payments, current_seller])
  end
end
