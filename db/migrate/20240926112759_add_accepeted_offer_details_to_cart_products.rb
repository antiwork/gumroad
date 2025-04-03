# frozen_string_literal: true

class AddAccepetedOfferDetailsToCartProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :cart_products, :accepted_offer_details, :json
  end
end
