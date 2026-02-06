# frozen_string_literal: true

class Settings::RefundFundingController < Settings::BaseController
  before_action :authorize

  def show
    funding_card = current_seller.refund_funding_credit_card

    render json: {
      enabled: funding_card.present?,
      credit_card: funding_card.present? ? {
        id: funding_card.id,
        visual: funding_card.visual,
        card_type: funding_card.card_type,
        expiry_month: funding_card.expiry_month,
        expiry_year: funding_card.expiry_year
      } : nil,
      show_banner: !current_seller.dismissed_refund_payment_method_banner? && current_seller.refund_funding_credit_card.blank?
    }
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

    if !credit_card.persisted?
      return render json: { success: false, error: credit_card.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end

    current_seller.update!(refund_funding_credit_card: credit_card)

    render json: {
      success: true,
      credit_card: {
        id: credit_card.id,
        visual: credit_card.visual,
        card_type: credit_card.card_type,
        expiry_month: credit_card.expiry_month,
        expiry_year: credit_card.expiry_year
      }
    }
  end

  def destroy
    current_seller.update!(refund_funding_credit_card: nil)

    render json: { success: true }
  end

  def dismiss_banner
    current_seller.update!(dismissed_refund_payment_method_banner: true)

    render json: { success: true }
  end

  private

  def authorize
    super([:settings, :refund_funding, current_seller])
  end
end
