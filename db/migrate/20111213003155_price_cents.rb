# frozen_string_literal: true

class PriceCents < ActiveRecord::Migration
  def up
    add_column :links, :price_cents, :integer
    add_column :purchases, :price_cents, :integer
    Link.find_each do |link|
      link.price_cents = link.price * 100
      link.save(validate: false)
    end

    Purchase.find_each do |purchase|
      purchase.price_cents = purchase.price * 100
      purchase.save(validate: false)
    end
  end

  def down
    remove_column :links, :price_cents
    remove_column :purchases, :price_cents
  end
end
