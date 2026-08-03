# frozen_string_literal: true

class CreateTaxonomyAttributes < ActiveRecord::Migration[7.1]
  FONT_ATTRIBUTES = [
    { name: "format", label: "Format", value_type: "enum", values: ["OTF", "TTF", "WOFF2"], position: 0 },
    { name: "license", label: "License", value_type: "enum", values: ["Personal", "Commercial", "App embedding"], position: 1 },
    { name: "variable_font", label: "Variable font", value_type: "boolean", values: [], position: 2 },
    { name: "styles", label: "Styles", value_type: "number", values: [], position: 3 },
  ].freeze

  def up
    create_table :taxonomy_attributes do |t|
      t.references :taxonomy, null: false
      t.string :name, null: false
      t.string :label, null: false
      t.string :value_type, null: false
      t.json :values
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps

      t.index [:taxonomy_id, :name], unique: true
    end

    fonts_id = select_value(<<~SQL.squish)
      SELECT child.id
      FROM taxonomies child
      INNER JOIN taxonomies parent ON parent.id = child.parent_id
      WHERE child.slug = 'fonts' AND parent.slug = 'design'
      LIMIT 1
    SQL
    return if fonts_id.blank?

    now = quote(Time.current)
    FONT_ATTRIBUTES.each do |attribute|
      execute <<~SQL.squish
        INSERT INTO taxonomy_attributes
          (taxonomy_id, name, label, value_type, `values`, position, active, created_at, updated_at)
        VALUES
          (#{fonts_id}, #{quote(attribute[:name])}, #{quote(attribute[:label])}, #{quote(attribute[:value_type])}, #{quote(attribute[:values].to_json)}, #{attribute[:position]}, TRUE, #{now}, #{now})
      SQL
    end
  end

  def down
    drop_table :taxonomy_attributes
  end
end
