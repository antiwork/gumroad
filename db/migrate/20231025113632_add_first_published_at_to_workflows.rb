# frozen_string_literal: true

class AddFirstPublishedAtToWorkflows < ActiveRecord::Migration[7.0]
  def change
    add_column :workflows, :first_published_at, :datetime, precision: nil
  end
end
