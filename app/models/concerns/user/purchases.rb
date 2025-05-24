# frozen_string_literal: true

module User::Purchases
  extend ActiveSupport::Concern

  def transfer_purchases!(new_email:)
    new_user = User.find_by!(email: new_email)
    purchases = Purchase.where(email:)

    transaction do
      purchases.find_each do |purchase|
        purchase.email = new_email
        purchase.purchaser_id = new_user.id
        purchase.save!
      end
    end
  end
end
