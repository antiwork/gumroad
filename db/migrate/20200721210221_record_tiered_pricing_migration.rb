# frozen_string_literal: true

class RecordTieredPricingMigration < ActiveRecord::Migration[5.1]
  # TODO(helen): remove these columns when confident that tiered pricing data
  # migration was successful (see https://github.com/gumroad/web/pull/13830)
  # Also see note in `Price` model re. `.alive` and `#alive?` methods
  def up
    add_column :links, :migrated_to_tiered_pricing_at, :datetime
    add_column :prices, :archived_at, :datetime
  end

  def down
    remove_column :prices, :archived_at
    remove_column :links, :migrated_to_tiered_pricing_at
  end
end
