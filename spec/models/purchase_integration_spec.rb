# frozen_string_literal: true

require "spec_helper"

describe PurchaseIntegration do
  describe "validations" do
    it "raises error if purchase_id is not present" do
      purchase_integration = build(:purchase_integration, purchase_id: nil, integration_id: create(:discord_integration).id)
      expect(purchase_integration.valid?).to eq(false)
      expect(purchase_integration.errors.full_messages).to include("Purchase can't be blank")
    end

    it "raises error if integration_id is not present" do
      purchase_integration = build(:purchase_integration, purchase_id: create(:purchase).id, integration_id: nil)
      expect(purchase_integration.valid?).to eq(false)
      expect(purchase_integration.errors.full_messages).to include("Integration can't be blank")
    end

    it "raises error if (purchase_id, integration_id) is not unique" do
      purchase_integration_1 = create(:discord_purchase_integration)
      purchase_integration_2 = build(:purchase_integration, purchase: purchase_integration_1.purchase, integration: purchase_integration_1.integration)
      expect(purchase_integration_2.valid?).to eq(false)
      expect(purchase_integration_2.errors.full_messages).to include("Integration has already been taken")
    end

    it "is successful if (purchase_id, integration_id) is not unique but all clashing entries have been deleted" do
      purchase_integration_1 = create(:discord_purchase_integration, deleted_at: 1.day.ago)
      purchase_integration_2 = create(:purchase_integration, purchase: purchase_integration_1.purchase, integration: purchase_integration_1.integration, discord_user_id: "user-1")
      expect(purchase_integration_2).to be_valid
      expect(purchase_integration_2).to be_persisted
    end

    it "raises error if same purchase has different integrations of same type" do
      purchase_integration_1 = create(:discord_purchase_integration)
      purchase_integration_2 = build(:purchase_integration, purchase: purchase_integration_1.purchase, integration: create(:discord_integration), discord_user_id: "user-1")
      expect(purchase_integration_2.valid?).to eq(false)
      expect(purchase_integration_2.errors.full_messages).to include("Purchase cannot have multiple integrations of the same type.")
    end

    it "is successful if same purchase has integrations of different type" do
      purchase_integration = create(:discord_purchase_integration)
      integration = create(:circle_integration)
      purchase_integration.purchase.link.active_integrations << integration
      purchase_integration_2 = create(:purchase_integration, purchase: purchase_integration.purchase, integration:)
      expect(purchase_integration_2).to be_valid
      expect(purchase_integration_2).to be_persisted
    end

    it "raises error if discord_user_id is not present for a discord integration" do
      purchase_integration = build(:purchase_integration, integration: create(:discord_integration))
      expect(purchase_integration.valid?).to eq(false)
      expect(purchase_integration.errors.full_messages).to include("Discord user can't be blank")
    end

    it "raises error if purchase and the associated standalone product have different integrations" do
      product = create(:product, active_integrations: [create(:discord_integration)])
      purchase_integration = build(:purchase_integration, integration: create(:discord_integration), purchase: create(:purchase, link: product))
      expect(purchase_integration.valid?).to eq(false)
      expect(purchase_integration.errors.full_messages).to include("Integration does not match the one available for the associated product.")
    end

    it "raises error if purchase and the associated variant have different integrations" do
      product = create(:product_with_digital_versions, active_integrations: [create(:discord_integration)])
      purchase_integration = build(:purchase_integration, integration: create(:discord_integration), purchase: create(:purchase, link: product, variant_attributes: [product.alive_variants.first]))
      expect(purchase_integration.valid?).to eq(false)
      expect(purchase_integration.errors.full_messages).to include("Integration does not match the one available for the associated product.")
    end
  end
end
