# frozen_string_literal: true

class AddJsonDataToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :json_data, :text
  end
end
