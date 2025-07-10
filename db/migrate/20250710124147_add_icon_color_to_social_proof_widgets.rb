class AddIconColorToSocialProofWidgets < ActiveRecord::Migration[7.1]
  def change
    add_column :social_proof_widgets, :icon_color, :string
  end
end
