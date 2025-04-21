# frozen_string_literal: true

class CreateSocialProofWidgetsLinks < ActiveRecord::Migration[7.1]
  def change
      create_table :social_proof_widgets_links do |t|
        t.integer :social_proof_widget_id, null: false
        t.integer :link_id, null: false

        t.index [:social_proof_widget_id, :link_id], unique: true, name: "index_social_proof_widgets_links_on_widget_and_link"

        t.index :social_proof_widget_id, name: "index_social_proof_widgets_links_on_widget_id"
        t.index :link_id, name: "index_social_proof_widgets_links_on_link_id"
      end
  end
end
