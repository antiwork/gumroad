# frozen_string_literal: true

class AddSuggestedPriceCentsToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :suggested_price_cents, :integer
  end
end
