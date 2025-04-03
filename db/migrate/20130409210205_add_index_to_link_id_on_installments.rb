# frozen_string_literal: true

class AddIndexToLinkIdOnInstallments < ActiveRecord::Migration
  def change
    add_index :installments, :link_id
  end
end
