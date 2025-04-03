# frozen_string_literal: true

require "spec_helper"

describe ProductIntegration do
  describe "validations" do
    before do
      @integration = create(:circle_integration)
      @product = create(:product)
    end

    it "raises error if product_id is not present" do
      product_integration = ProductIntegration.new(integration_id: @integration.id)
      expect(product_integration.valid?).to eq(false)
      expect(product_integration.errors.full_messages).to include("Product can't be blank")
    end

    it "raises error if integration_id is not present" do
      product_integration = ProductIntegration.new(product_id: @product.id)
      expect(product_integration.valid?).to eq(false)
      expect(product_integration.errors.full_messages).to include("Integration can't be blank")
    end

    it "raises error if (product_id, integration_id) is not unique" do
      ProductIntegration.create!(integration_id: @integration.id, product_id: @product.id)
      product_integration_2 = ProductIntegration.new(integration_id: @integration.id, product_id: @product.id)
      expect(product_integration_2.valid?).to eq(false)
      expect(product_integration_2.errors.full_messages).to include("Integration has already been taken")
    end

    it "is successful if (product_id, integration_id) is not unique but all clashing entries have been deleted" do
      product_integration_1 = ProductIntegration.create!(integration_id: @integration.id, product_id: @product.id)
      product_integration_1.mark_deleted!
      ProductIntegration.create!(integration_id: @integration.id, product_id: @product.id)
      expect(ProductIntegration.count).to eq(2)
      expect(@product.active_integrations.count).to eq(1)
    end

    it "is successful if same product has different integrations" do
      ProductIntegration.create!(integration_id: @integration.id, product_id: @product.id)
      ProductIntegration.create!(integration_id: create(:circle_integration).id, product_id: @product.id)
      expect(ProductIntegration.count).to eq(2)
    end
  end
end
