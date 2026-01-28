# frozen_string_literal: true

class AddCleanedReferrerToEvents < ActiveRecord::Migration[4.2]
  def change
    add_column :events, :referrer_domain, :string
  end
end
