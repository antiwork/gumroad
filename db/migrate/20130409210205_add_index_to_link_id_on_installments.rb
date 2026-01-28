# frozen_string_literal: true

class AddIndexToLinkIdOnInstallments < ActiveRecord::Migration[4.2]
  def change
    add_index :installments, :link_id
  end
end
