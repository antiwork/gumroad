class AddStatusToSocialProofWidgets < ActiveRecord::Migration[7.1]
  def change
    add_column :social_proof_widgets, :status, :string, default: 'unpublished', null: false
    add_index :social_proof_widgets, :status
  end
end
