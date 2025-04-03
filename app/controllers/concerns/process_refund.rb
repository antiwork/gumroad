# frozen_string_literal: true

module ProcessRefund
  private
    def process_refund(seller:, user:, purchase_external_id:, amount:, impersonating: false)
      # We don't support commas in refund amount
      # Reference: https://github.com/gumroad/web/pull/17747
      return render json: { success: false, message: "Commas not supported in refund amount." } if amount&.include?(",")

      purchase = seller.sales.paid.find_by_external_id(purchase_external_id)
      return e404_json if purchase.nil? || purchase.stripe_refunded? || purchase.paypal_refund_expired?

      begin
        if purchase.refund!(refunding_user_id: user.id, amount:)
          purchase.seller.update!(refund_fee_notice_shown: true) unless impersonating
          render json: { success: true, id: purchase.external_id, message: "Purchase successfully refunded.", partially_refunded: purchase.stripe_partially_refunded? }
        else
          render json: { success: false, message: purchase.errors.full_messages.to_sentence }
        end
      rescue ActiveRecord::RecordInvalid => e
        Bugsnag.notify(e)
        render json: { success: false, message: "Sorry, something went wrong." }, status: :unprocessable_entity
      end
    end
end
