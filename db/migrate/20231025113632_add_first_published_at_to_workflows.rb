# frozen_string_literal: true

class AddFirstPublishedAtToWorkflows < ActiveRecord::Migration[4.2]
  def change
    add_column :workflows, :first_published_at, :datetime, precision: nil
  end
end
