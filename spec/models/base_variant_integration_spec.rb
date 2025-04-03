# frozen_string_literal: true

require "spec_helper"

describe BaseVariantIntegration do
  describe "validations" do
    before do
      @integration = create(:circle_integration)
      @variant = create(:variant)
    end

    it "raises error if base_variant_id is not present" do
      base_variant_integration = BaseVariantIntegration.new(integration_id: @integration.id)
      expect(base_variant_integration.valid?).to eq(false)
      expect(base_variant_integration.errors.full_messages).to include("Base variant can't be blank")
    end

    it "raises error if integration_id is not present" do
      base_variant_integration = BaseVariantIntegration.new(base_variant_id: @variant.id)
      expect(base_variant_integration.valid?).to eq(false)
      expect(base_variant_integration.errors.full_messages).to include("Integration can't be blank")
    end

    it "raises error if (base_variant_id, integration_id) is not unique" do
      BaseVariantIntegration.create!(integration_id: @integration.id, base_variant_id: @variant.id)
      base_variant_integration_2 = BaseVariantIntegration.new(integration_id: @integration.id, base_variant_id: @variant.id)
      expect(base_variant_integration_2.valid?).to eq(false)
      expect(base_variant_integration_2.errors.full_messages).to include("Integration has already been taken")
    end

    it "raises error if different variants linked to the same integration are not from the same product" do
      BaseVariantIntegration.create!(integration_id: @integration.id, base_variant_id: @variant.id)
      base_variant_integration_2 = BaseVariantIntegration.new(integration_id: @integration.id, base_variant_id: create(:variant).id)
      expect(base_variant_integration_2.valid?).to eq(false)
      expect(base_variant_integration_2.errors.full_messages).to include("Integration has already been taken by a variant from a different product.")
    end

    it "is successful if different variants of the same product have the same integration" do
      category = create(:variant_category, link: create(:product))
      variant_1 = create(:variant, variant_category: category)
      variant_2 = create(:variant, variant_category: category)
      BaseVariantIntegration.create!(integration_id: @integration.id, base_variant_id: variant_1.id)
      BaseVariantIntegration.create!(integration_id: @integration.id, base_variant_id: variant_2.id)
      expect(BaseVariantIntegration.count).to eq(2)
    end

    it "is successful if (product_id, integration_id) is not unique but all clashing entries have been deleted" do
      base_variant_integration_1 = BaseVariantIntegration.create!(integration_id: @integration.id, base_variant_id: @variant.id)
      base_variant_integration_1.mark_deleted!
      BaseVariantIntegration.create!(integration_id: @integration.id, base_variant_id: @variant.id)
      expect(BaseVariantIntegration.count).to eq(2)
      expect(@variant.active_integrations.count).to eq(1)
    end

    it "is successful if same variant has different integrations" do
      BaseVariantIntegration.create!(integration_id: @integration.id, base_variant_id: @variant.id)
      BaseVariantIntegration.create!(integration_id: create(:circle_integration).id, base_variant_id: @variant.id)
      expect(BaseVariantIntegration.count).to eq(2)
    end
  end
end
