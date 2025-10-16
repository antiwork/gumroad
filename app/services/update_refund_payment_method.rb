# frozen_string_literal: true

class UpdateRefundPaymentMethod
  attr_reader :user, :params

  def initialize(user:, params:)
    @user = user
    @params = params || {}
  end

  def process
    return success_response unless params.present?

    if remove_requested?
      user.refund_payment_method&.destroy!
      return success_response
    end

    refund_payment_method = user.refund_payment_method || user.build_refund_payment_method
    name = params[:name_on_card]&.to_s&.strip
    refund_payment_method.cardholder_name = name if params.key?(:name_on_card)

    card_params = params[:card]

    if card_params.present? && card_params[:type] != "saved"
      chargeable = ChargeProcessor.get_chargeable_for_params(card_params, nil)
      return failure_response("Please check your card information, we couldn't verify it.") if chargeable.nil?

      card_data_handling_mode = CardDataHandlingMode.get_card_data_handling_mode(user)
      credit_card = CreditCard.create(chargeable, card_data_handling_mode, user)
      if credit_card.errors.present?
        return failure_response(credit_card.errors.full_messages.to_sentence)
      end

      previous_credit_card = refund_payment_method.credit_card if refund_payment_method.persisted?
      refund_payment_method.credit_card = credit_card
      previous_credit_card&.destroy!
    elsif refund_payment_method.credit_card.blank?
      return failure_response("Please add a card to use as your backup refund method.") if refund_payment_method.new_record?
    end

    refund_payment_method.save!
    success_response
  rescue ChargeProcessorInvalidRequestError, ChargeProcessorUnavailableError => e
    Bugsnag.notify(e)
    failure_response("Sorry, something went wrong while saving your card. Please try again.")
  end

  private
    def remove_requested?
      ActiveModel::Type::Boolean.new.cast(params[:remove])
    end

    def success_response
      { success: true }
    end

    def failure_response(message)
      { success: false, error_message: message }
    end
end
