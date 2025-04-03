# frozen_string_literal: true

class AddCleanedReferrerToEvents < ActiveRecord::Migration
  def change
    add_column :events, :referrer_domain, :string
  end
end
