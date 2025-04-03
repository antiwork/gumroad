# frozen_string_literal: true

class AddArchivedAtToAffiliates < ActiveRecord::Migration[7.0]
  def change
    add_column :affiliates, :archived_at, :datetime
  end
end
