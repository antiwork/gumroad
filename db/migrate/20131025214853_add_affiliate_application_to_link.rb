# frozen_string_literal: true

class AddAffiliateApplicationToLink < ActiveRecord::Migration
  def change
    add_column :links, :affiliate_application_id, :integer
  end
end
