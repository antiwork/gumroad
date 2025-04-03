# frozen_string_literal: true

class RemoveUniqueIndexConstraintFromRichContents < ActiveRecord::Migration[7.0]
  def up
    remove_index :rich_contents, name: "index_rich_contents_on_entity_id_and_entity_type"
    add_index :rich_contents, [:entity_id, :entity_type], name: "index_rich_contents_on_entity_id_and_entity_type"
  end

  def down
    remove_index :rich_contents, name: "index_rich_contents_on_entity_id_and_entity_type"
    add_index :rich_contents, [:entity_id, :entity_type], name: "index_rich_contents_on_entity_id_and_entity_type", unique: true
  end
end
