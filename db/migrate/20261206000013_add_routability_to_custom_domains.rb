# frozen_string_literal: true

class AddRoutabilityToCustomDomains < ActiveRecord::Migration[7.1]
  def change
    change_table :custom_domains, bulk: true do |t|
      t.boolean :routable
      t.datetime :routability_checked_at
    end
  end
end
