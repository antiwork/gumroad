# frozen_string_literal: true

class AddRedirectsToAllPurchases < ActiveRecord::Migration[4.2]
  def up
    Purchase.find_each do |p|
      p.create_url_redirect!
    end
  end

  def down
  end
end
