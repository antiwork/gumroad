# frozen_string_literal: true

class AddArchivedAtToAffiliates < ActiveRecord::Migration[4.2]
  def change
    add_column :affiliates, :archived_at, :datetime
  end
end
