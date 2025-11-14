# frozen_string_literal: true

class Settings::BalanceLoadCardsController < Sellers::BaseController
  before_action :authorize
  before_action :set_card, only: [:update, :destroy]

  def index
    @cards = current_seller.balance_load_credit_cards.active.order(is_default: :desc, created_at: :desc)
    render json: { success: true, cards: @cards.map(&:as_json) }
  end

  def create
    service = BalanceLoading::PaymentMethodService.new(user: current_seller)
    card = service.add_card(
      payment_method_id: params[:payment_method_id],
      set_as_default: params[:set_as_default] != false
    )

    render json: { success: true, card: card.as_json }
  rescue => e
    Rails.logger.error("Failed to add balance load card for user #{current_seller.id}: #{e.message}")
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def update
    service = BalanceLoading::PaymentMethodService.new(user: current_seller)
    card = service.update_card(
      card_id: @card.id,
      payment_method_id: params[:payment_method_id],
      set_as_default: params[:set_as_default]
    )

    render json: { success: true, card: card.as_json }
  rescue => e
    Rails.logger.error("Failed to update balance load card #{@card.id} for user #{current_seller.id}: #{e.message}")
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def destroy
    service = BalanceLoading::PaymentMethodService.new(user: current_seller)
    service.remove_card(card_id: @card.id)

    render json: { success: true }
  rescue => e
    Rails.logger.error("Failed to remove balance load card #{@card.id} for user #{current_seller.id}: #{e.message}")
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  private

  def set_card
    @card = current_seller.balance_load_credit_cards.active.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { success: false, error: "Card not found" }, status: :not_found
  end

  def authorize
    return if current_seller

    render json: { success: false, error: "Unauthorized" }, status: :unauthorized
  end
end
