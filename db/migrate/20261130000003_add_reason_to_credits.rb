# frozen_string_literal: true

class AddReasonToCredits < ActiveRecord::Migration[7.1]
  def change
    add_column :credits, :reason, :text
  end
end
