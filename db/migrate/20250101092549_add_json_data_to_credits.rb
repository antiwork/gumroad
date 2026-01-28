# frozen_string_literal: true

class AddJsonDataToCredits < ActiveRecord::Migration[4.2]
  def change
    add_column :credits, :json_data, :text
  end
end
