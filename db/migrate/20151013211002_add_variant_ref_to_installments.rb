# frozen_string_literal: true

class AddVariantRefToInstallments < ActiveRecord::Migration
  def change
    add_reference :installments, :base_variant, index: true
  end
end
