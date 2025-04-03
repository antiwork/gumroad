# frozen_string_literal: true

require "spec_helper"

describe Integrations::CircleIntegrationService do
  let(:community_id) { 3512 }
  let(:space_group_id) { 43576 }
  let(:email) { "test_circle_integration@gumroad.com" }

  before do
    @user = create(:user, email:)
    @integration = create(:circle_integration, community_id:, space_group_id:)
  end

  describe "standalone product" do
    before do
      @product = create(:product, active_integrations: [@integration])
      @purchase = create(:purchase, link: @product, email:)
      @purchase_without_integration = create(:purchase, email:)
    end

    describe "#activate" do
      it "adds member to the community specified in the integration" do
        expect_any_instance_of(CircleApi).to receive(:add_member).with(community_id, space_group_id, email)
        Integrations::CircleIntegrationService.new.activate(@purchase)
      end

      it "does nothing if integration does not exist" do
        expect_any_instance_of(CircleApi).to_not receive(:add_member)
        Integrations::CircleIntegrationService.new.activate(@purchase_without_integration)
      end
    end

    describe "#deactivate" do
      it "removes member from the community specified in the integration" do
        expect_any_instance_of(CircleApi).to receive(:remove_member).with(community_id, email)
        Integrations::CircleIntegrationService.new.deactivate(@purchase)
      end

      it "does nothing if integration does not exist" do
        expect_any_instance_of(CircleApi).to_not receive(:remove_member)
        Integrations::CircleIntegrationService.new.deactivate(@purchase_without_integration)
      end

      it "does nothing if deactivation is disabled" do
        @integration.update!(keep_inactive_members: true)
        expect_any_instance_of(CircleApi).to_not receive(:remove_member)
        Integrations::CircleIntegrationService.new.deactivate(@purchase)
      end
    end
  end

  describe "product with variants" do
    before do
      @product_with_digital_versions = create(:product_with_digital_versions, active_integrations: [@integration])
      @version_category = @product_with_digital_versions.variant_categories.first
      @version_category.variants[1].active_integrations << @integration
      @purchase_with_integration = create(:purchase, link: @product_with_digital_versions, email:, variant_attributes: [@version_category.variants[1]])
      @purchase_without_integration = create(:purchase, link: @product_with_digital_versions, email:, variant_attributes: [@version_category.variants[0]])
      @purchase_without_variant = create(:purchase, link: @product_with_digital_versions, email:)
    end

    describe "#activate" do
      it "adds member to the community if variant has integration" do
        expect_any_instance_of(CircleApi).to receive(:add_member).with(community_id, space_group_id, email)
        Integrations::CircleIntegrationService.new.activate(@purchase_with_integration)
      end

      it "adds member to the community if product has integration and purchase does not have a variant specified" do
        expect_any_instance_of(CircleApi).to receive(:add_member).with(community_id, space_group_id, email)
        Integrations::CircleIntegrationService.new.activate(@purchase_without_variant)
      end

      it "does nothing if variant does not have integration" do
        expect_any_instance_of(CircleApi).to_not receive(:add_member)
        Integrations::CircleIntegrationService.new.activate(@purchase_without_integration)
      end
    end

    describe "#deactivate" do
      it "removes member from the community if variant has integration" do
        expect_any_instance_of(CircleApi).to receive(:remove_member).with(community_id, email)
        Integrations::CircleIntegrationService.new.deactivate(@purchase_with_integration)
      end

      it "does nothing if variant does not have integration" do
        expect_any_instance_of(CircleApi).to_not receive(:remove_member)
        Integrations::CircleIntegrationService.new.deactivate(@purchase_without_integration)
      end

      it "does nothing if deactivation is disabled" do
        @integration.update!(keep_inactive_members: true)
        expect_any_instance_of(CircleApi).to_not receive(:remove_member)
        Integrations::CircleIntegrationService.new.deactivate(@purchase_with_integration)
      end

      it "removes member from the community if product has integration and purchase does not have a variant specified" do
        expect_any_instance_of(CircleApi).to receive(:remove_member).with(community_id, email)
        Integrations::CircleIntegrationService.new.deactivate(@purchase_without_variant)
      end
    end
  end

  describe "membership product" do
    before do
      @membership_product = create(:membership_product_with_preset_tiered_pricing, active_integrations: [@integration])
      @membership_product.tiers[1].active_integrations << @integration
      @purchase_with_integration = create(:membership_purchase, link: @membership_product, email:, variant_attributes: [@membership_product.tiers[1]],
                                                                purchase_sales_tax_info: PurchaseSalesTaxInfo.create(business_vat_id: 0))
      @purchase_without_integration = create(:membership_purchase, link: @membership_product, email:, variant_attributes: [@membership_product.tiers[0]],
                                                                   purchase_sales_tax_info: PurchaseSalesTaxInfo.create(business_vat_id: 0))
    end

    describe "#activate" do
      it "adds member to the community if tier has integration" do
        expect_any_instance_of(CircleApi).to receive(:add_member).with(community_id, space_group_id, email)
        Integrations::CircleIntegrationService.new.activate(@purchase_with_integration)
      end

      it "does nothing if tier does not have integration" do
        expect_any_instance_of(CircleApi).to_not receive(:add_member)
        Integrations::CircleIntegrationService.new.activate(@purchase_without_integration)
      end
    end

    describe "#deactivate" do
      it "removes member from the community if tier has integration" do
        expect_any_instance_of(CircleApi).to receive(:remove_member).with(community_id, email)
        Integrations::CircleIntegrationService.new.deactivate(@purchase_with_integration)
      end

      it "does nothing if tier does not have integration" do
        expect_any_instance_of(CircleApi).to_not receive(:remove_member)
        Integrations::CircleIntegrationService.new.deactivate(@purchase_without_integration)
      end

      it "does nothing if deactivation is disabled" do
        @integration.update!(keep_inactive_members: true)
        expect_any_instance_of(CircleApi).to_not receive(:remove_member)
        Integrations::CircleIntegrationService.new.deactivate(@purchase_with_integration)
      end
    end

    describe "#update_on_tier_change" do
      before do
        @subscription_with_integration = @purchase_with_integration.subscription
        @subscription_without_integration = @purchase_without_integration.subscription
      end

      it "activates integration if new tier has integration and old tier did not" do
        @subscription_without_integration.update_current_plan!(
          new_variants: [@membership_product.tiers[1]],
          new_price: create(:price),
          perceived_price_cents: 0,
          is_applying_plan_change: true,
          )
        @subscription_without_integration.reload

        expect_any_instance_of(CircleApi).to receive(:add_member).with(community_id, space_group_id, email)
        expect_any_instance_of(CircleApi).to_not receive(:remove_member)
        Integrations::CircleIntegrationService.new.update_on_tier_change(@subscription_without_integration)
      end

      it "deactivates integration if old tier had integration and new tier does not" do
        @subscription_with_integration.update_current_plan!(
          new_variants: [@membership_product.tiers[0]],
          new_price: create(:price),
          perceived_price_cents: 0,
          is_applying_plan_change: true,
          )
        @subscription_with_integration.reload

        expect_any_instance_of(CircleApi).to receive(:remove_member).with(community_id, email)
        expect_any_instance_of(CircleApi).to_not receive(:add_member)
        Integrations::CircleIntegrationService.new.update_on_tier_change(@subscription_with_integration)
      end

      it "does nothing if old tier had integration and new tier does not but deactivation is disabled" do
        @integration.update!(keep_inactive_members: true)
        @subscription_with_integration.update_current_plan!(
          new_variants: [@membership_product.tiers[0]],
          new_price: create(:price),
          perceived_price_cents: 0,
          is_applying_plan_change: true,
          )
        @subscription_with_integration.reload

        expect_any_instance_of(CircleApi).to_not receive(:remove_member)
        expect_any_instance_of(CircleApi).to_not receive(:add_member)
        Integrations::CircleIntegrationService.new.update_on_tier_change(@subscription_with_integration)
      end

      it "does nothing if new and old tier have integration" do
        tier_3 = create(:variant, variant_category: @membership_product.tier_category, name: "Tier 3", active_integrations: [@integration])
        @subscription_with_integration.update_current_plan!(
          new_variants: [tier_3],
          new_price: create(:price),
          perceived_price_cents: 0,
          is_applying_plan_change: true,
          )
        @subscription_with_integration.reload

        expect_any_instance_of(CircleApi).to_not receive(:add_member)
        expect_any_instance_of(CircleApi).to_not receive(:remove_member)
        Integrations::CircleIntegrationService.new.update_on_tier_change(@subscription_with_integration)
      end

      it "does nothing if new and old tier do not have integration" do
        tier_3 = create(:variant, variant_category: @membership_product.tier_category, name: "Tier 3")
        @subscription_without_integration.update_current_plan!(
          new_variants: [tier_3],
          new_price: create(:price),
          perceived_price_cents: 0,
          is_applying_plan_change: true,
          )
        @subscription_without_integration.reload

        expect_any_instance_of(CircleApi).to_not receive(:add_member)
        expect_any_instance_of(CircleApi).to_not receive(:remove_member)
        Integrations::CircleIntegrationService.new.update_on_tier_change(@subscription_without_integration)
      end
    end
  end
end
