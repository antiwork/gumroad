class RemoveExternalIdFromSocialProofWidgets < ActiveRecord::Migration[7.1]
  def change
    remove_column :social_proof_widgets, :external_id, :string
  end
end
