# frozen_string_literal: true

class AddJsonDataToCredits < ActiveRecord::Migration[7.1]
  def change
    add_column :credits, :json_data, :text
  end
end
