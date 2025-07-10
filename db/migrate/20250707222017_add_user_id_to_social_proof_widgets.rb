# frozen_string_literal: true

class AddUserIdToSocialProofWidgets < ActiveRecord::Migration[7.1]
  def change
    add_reference :social_proof_widgets, :user, null: false, foreign_key: true
    add_column :social_proof_widgets, :deleted_at, :datetime
    add_index :social_proof_widgets, :deleted_at
  end
end