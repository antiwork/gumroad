# frozen_string_literal: true

module MassTransferPurchases
  extend ActiveSupport::Concern

  private
    def transfer_purchases(user:, new_email:)
      purchases = Purchase.where(email: user.email)
      error_message = if user.suspended?
        "Mass-transferring purchases for a suspended user is not allowed."
      elsif purchases.none?
        "User has no purchases."
      elsif new_email.blank?
        "Email can't be blank."
      elsif !EmailFormatValidator.valid?(new_email)
        "Invalid email format."
      end
      return { success: false, message: error_message, status: :unprocessable_entity } if error_message.present?

      user.transfer_purchases!(new_email:)
      { success: true, message: "Mass purchase transfer successful to email #{new_email}", status: :ok }
    rescue ActiveRecord::RecordNotFound
      error_message = "User with email #{new_email} does not exist."
      { success: false, message: error_message, status: :not_found }
    end
end
