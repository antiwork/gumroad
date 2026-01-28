# frozen_string_literal: true

class RemoveCurrency < ActiveRecord::Migration[4.2]
  def up
    drop_table :currencies
  end

  def down
    create_table :currencies do |t|
      t.float  :currency_rate
      t.string :currency_type
    end
  end
end
