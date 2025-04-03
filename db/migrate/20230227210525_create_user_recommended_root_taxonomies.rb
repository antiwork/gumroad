# frozen_string_literal: true

class CreateUserRecommendedRootTaxonomies < ActiveRecord::Migration[7.0]
  def change
    create_table :user_recommended_root_taxonomies do |t|
      t.references :user, null: false, index: false
      t.references :taxonomy, null: false, index: false
      t.integer :position, null: false
      t.timestamps
      t.index [:user_id, :position]
    end
  end
end
