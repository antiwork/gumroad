# frozen_string_literal: true

class AddPartnerSourceToLinks < ActiveRecord::Migration
  def change
    add_column :links, :partner_source, :string
  end
end
