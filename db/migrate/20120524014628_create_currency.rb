# frozen_string_literal: true

class CreateCurrency < ActiveRecord::Migration
  def up
    create_table :currencies do |t|
      t.float  :currency_rate
      t.string :currency_type
    end
  end

  def down
    drop_table :currencies
  end
end
