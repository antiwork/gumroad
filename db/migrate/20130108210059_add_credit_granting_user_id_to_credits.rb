# frozen_string_literal: true

class AddCreditGrantingUserIdToCredits < ActiveRecord::Migration[4.2]
  def change
    add_column :credits, :crediting_user_id, :integer
  end
end
