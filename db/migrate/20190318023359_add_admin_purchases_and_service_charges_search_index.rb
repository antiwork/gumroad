# frozen_string_literal: true

class AddAdminPurchasesAndServiceChargesSearchIndex < ActiveRecord::Migration
  def change
    add_index :purchases, [:card_type, :card_visual, :stripe_fingerprint], name: "index_purchases_on_card_type_visual_fingerprint"
    add_index :purchases, [:card_type, :card_visual, :created_at, :stripe_fingerprint], name: "index_purchases_on_card_type_visual_date_fingerprint"

    add_index :service_charges, [:card_type, :card_visual, :charge_processor_fingerprint], name: "index_service_charges_on_card_type_visual_fingerprint"
    add_index :service_charges, [:card_type, :card_visual, :created_at, :charge_processor_fingerprint], name: "index_service_charges_on_card_type_visual_date_fingerprint"
  end
end
