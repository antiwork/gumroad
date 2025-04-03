# frozen_string_literal: true

class AddJsonDataToWorkflow < ActiveRecord::Migration
  def change
    add_column :workflows, :json_data, :text
  end
end
