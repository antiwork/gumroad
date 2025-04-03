# frozen_string_literal: true

class AddSuggestedPriceCentsToLinks < ActiveRecord::Migration
  def change
    add_column :links, :suggested_price_cents, :integer
  end
end
