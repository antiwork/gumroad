# frozen_string_literal: true

# No backfill is possible: nothing recorded the publish event, so rows published before this
# migration stay NULL. A NULL here means "not recorded", never "never published".
class AddFirstPublishedAtToLinks < ActiveRecord::Migration[7.1]
  def change
    add_column :links, :first_published_at, :datetime
  end
end
