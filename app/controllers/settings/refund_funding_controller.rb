# frozen_string_literal: true

class Settings::RefundFundingController < Sellers::BaseController
  before_action :authorize

  def show
    funding_card = current_seller.refund_funding_credit_card

    render json: {
      enabled: funding_card.present?,
      name_on_card: current_seller.refund_funding_card_name,
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

    if credit_card.errors.any?
      return render json: { success: false, error: credit_card.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end

    current_seller.update!(
      refund_funding_credit_card: credit_card,
      refund_funding_card_name: params[:name_on_card]
    )

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

  def update
    if params[:name_on_card].present?
      current_seller.update!(refund_funding_card_name: params[:name_on_card])
    end

    render json: { success: true }
  end

  def destroy
    current_seller.update!(
      refund_funding_credit_card: nil,
      refund_funding_card_name: nil
    )

    render json: { success: true }
  end

  def dismiss_banner
    current_seller.update!(dismissed_refund_payment_method_banner: true)

    render json: { success: true }
  end

  def test_charge
    amount_cents = params[:amount_cents].to_i

    if amount_cents < BalanceTopUp::ChargeService::MINIMUM_TOP_UP_AMOUNT_CENTS
      return render json: { success: false, error: "Minimum test charge is $1.00" }, status: :unprocessable_entity
    end

    if current_seller.refund_funding_credit_card.blank?
      return render json: { success: false, error: "No funding credit card configured" }, status: :unprocessable_entity
    end

    result = BalanceTopUp::ChargeService.new(
      user: current_seller,
      amount_cents:
    ).perform

    if result.success?
      render json: {
        success: true,
        balance_top_up: {
          id: result.balance_top_up.external_id,
          amount_cents: result.balance_top_up.amount_cents,
          formatted_amount: result.balance_top_up.formatted_amount
        }
      }
    else
      render json: { success: false, error: result.error_message }, status: :unprocessable_entity
    end
  end

  private

  def authorize
    super([:settings, :refund_funding, current_seller])
  end
end
