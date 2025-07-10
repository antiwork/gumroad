class ChangeStatusTypeToIntegerInSocialProofWidgets < ActiveRecord::Migration[7.1]
  def change
    change_column :social_proof_widgets, :status, :integer, default: 1, null: false
  end
end
