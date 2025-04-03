# frozen_string_literal: true

class RemoveNameFromTaxonomies < ActiveRecord::Migration[6.1]
  def up
    change_table(:taxonomies, bulk: true) do |t|
      t.remove :name
      t.index "(IFNULL(`parent_id`,0)), `slug`", name: :index_taxonomies_on_parent_id_and_slug, unique: true
    end
  end

  def down
    change_table(:taxonomies, bulk: true) do |t|
      t.string :name
      t.remove_index name: :index_taxonomies_on_parent_id_and_slug
    end
  end
end
