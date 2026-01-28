# frozen_string_literal: true

class AddAffiliateApplicationToLink < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :affiliate_application_id, :integer
  end
end
