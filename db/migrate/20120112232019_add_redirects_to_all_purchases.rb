# frozen_string_literal: true

class AddRedirectsToAllPurchases < ActiveRecord::Migration
  def up
    Purchase.find_each do |p|
      p.create_url_redirect!
    end
  end

  def down
  end
end
