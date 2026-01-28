# frozen_string_literal: true

class AddJsonDataToRefunds < ActiveRecord::Migration[4.2]
  def change
    add_column :refunds, :json_data, :text
  end
end
