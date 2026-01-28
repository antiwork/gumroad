# frozen_string_literal: true

class AddVariantRefToInstallments < ActiveRecord::Migration[4.2]
  def change
    add_reference :installments, :base_variant, index: true
  end
end
