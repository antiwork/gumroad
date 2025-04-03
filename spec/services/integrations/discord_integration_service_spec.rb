# frozen_string_literal: true

require "spec_helper"

describe Integrations::DiscordIntegrationService do
  let(:integration) { create(:discord_integration) }
  let(:server_id) { integration.server_id }
  let(:user_id) { "694641779777077339" }
  let(:regular_user_role_id) { "111111111111111111" }
  let(:gumroad_bot_role_id) { "222222222222222222" }
  let(:power_user_role_id) { "333333333333333333" }
  let(:new_role_id) { "999999999999999999" }
  let(:admin_user_role_id) { "444444444444444444" }
  let(:resolve_member_response) do
    OpenStruct.new(
      body: {
        "avatar" => nil,
        "communication_disabled_until" => nil,
        "flags" => 0,
        "joined_at" => "2024-03-01T04:38:49.939000+00:00",
        "nick" => nil,
        "pending" => false,
        "premium_since" => nil,
        "roles" => [], # This will be empty for members with the default @everyone role
        "unusual_dm_activity_until" => nil,
        "user" => {
          "id" => user_id,
          "username" => "tkidd0",
          "avatar" => "4a2e3c2f51d11aad2d4c6e586bce9a7d",
          "discriminator" => "0",
          "public_flags" => 0,
          "premium_type" => 0,
          "flags" => 0,
          "banner" => nil,
          "accent_color" => nil,
          "global_name" => "tkidd9",
          "avatar_decoration_data" => nil,
          "banner_color" => nil
        },
        "mute" => false,
        "deaf" => false
      }.to_json
    )
  end
  let(:gumroad_resolve_member_response) do
    OpenStruct.new(
      body: {
        "avatar" => nil,
        "communication_disabled_until" => nil,
        "flags" => 0,
        "joined_at" => "2024-03-09T00:23:46.555000+00:00",
        "nick" => nil,
        "pending" => false,
        "premium_since" => nil,
        "roles" => [gumroad_bot_role_id],
        "unusual_dm_activity_until" => nil,
        "user" => {
          "id" => DISCORD_GUMROAD_BOT_ID,
          "username" => "Gumroad",
          "avatar" => nil,
          "discriminator" => "1956",
          "public_flags" => 65536,
          "premium_type" => 0,
          "flags" => 65536,
          "bot" => true,
          "banner" => nil,
          "accent_color" => nil,
          "global_name" => nil,
          "avatar_decoration_data" => nil,
          "banner_color" => nil
        },
        "mute" => false,
        "deaf" => false
      }.to_json
    )
  end
  let(:roles_response) do
    OpenStruct.new(
      body: [
        {
          "id" => "000000000000000000",
          "name" => "@everyone",
          "description" => nil,
          "permissions" => "533235326373441",
          "position" => 0,
          "color" => 0,
          "hoist" => false,
          "managed" => false,
          "mentionable" => false,
          "icon" => nil,
          "unicode_emoji" => nil,
          "flags" => 0
        },
        {
          "id" => power_user_role_id,
          "name" => "Power User Role",
          "description" => nil,
          "permissions" => "1071698660928",
          "position" => 3,
          "color" => 3447003,
          "hoist" => true,
          "managed" => false,
          "mentionable" => false,
          "icon" => nil,
          "unicode_emoji" => nil,
          "flags" => 0
        },
        {
          "id" => new_role_id,
          "name" => "New Role at same position as Power User Role",
          "description" => nil,
          "permissions" => "1071698660928",
          # When a Discord Role is created, it could receive the same position as another role.
          # Positions become unique again if an Admin reorders the Roles in the Discord interface.
          # Weird. https://github.com/discord/discord-api-docs/issues/1778
          "position" => 3,
          "color" => 3447003,
          "hoist" => true,
          "managed" => false,
          "mentionable" => false,
          "icon" => nil,
          "unicode_emoji" => nil,
          "flags" => 0
        },
        {
          "id" => admin_user_role_id,
          "name" => "Admin User Role",
          "description" => nil,
          "permissions" => "1071698660928",
          "position" => 4,
          "color" => 3447003,
          "hoist" => true,
          "managed" => false,
          "mentionable" => false,
          "icon" => nil,
          "unicode_emoji" => nil,
          "flags" => 0
        },
        {
          "id" => regular_user_role_id,
          "name" => "Regular User Role",
          "description" => nil,
          "permissions" => "1071698660928",
          "position" => 1,
          "color" => 3447003,
          "hoist" => true,
          "managed" => false,
          "mentionable" => false,
          "icon" => nil,
          "unicode_emoji" => nil,
          "flags" => 0
        },
        {
          "id" => gumroad_bot_role_id,
          "name" => "Gumroad",
          "description" => nil,
          "permissions" => "268435459",
          "position" => 2,
          "color" => 0,
          "hoist" => false,
          "managed" => true,
          "mentionable" => false,
          "icon" => nil,
          "unicode_emoji" => nil,
          "tags" => { "bot_id" => DISCORD_GUMROAD_BOT_ID }, # This tag will appear for the Role managed by the Gumroad bot.
          "flags" => 0
        }
      ].to_json
    )
  end

  describe "standalone product" do
    describe "#deactivate" do
      it "removes member from the server specified in the integration" do
        discord_purchase_integration = create(:discord_purchase_integration, integration:, discord_user_id: user_id)

        expect_any_instance_of(DiscordApi).to receive(:remove_member).with(server_id, user_id)

        Integrations::DiscordIntegrationService.new.deactivate(discord_purchase_integration.purchase)

        expect(discord_purchase_integration.reload.deleted?).to eq(true)
      end

      it "does nothing if integration is not enabled" do
        purchase_without_integration = create(:purchase)

        expect_any_instance_of(DiscordApi).to_not receive(:remove_member)
        Integrations::DiscordIntegrationService.new.deactivate(purchase_without_integration)
      end

      it "does nothing if purchase does not have an activated integration" do
        purchase_with_integration = create(:purchase, link: create(:product, active_integrations: [integration]))

        expect_any_instance_of(DiscordApi).to_not receive(:remove_member)
        Integrations::DiscordIntegrationService.new.deactivate(purchase_with_integration)
      end

      it "does nothing if deactivation is disabled" do
        discord_purchase_integration = create(:discord_purchase_integration, integration:, discord_user_id: user_id)
        integration.update!(keep_inactive_members: true)

        expect_any_instance_of(DiscordApi).to_not receive(:remove_member)
        Integrations::DiscordIntegrationService.new.deactivate(discord_purchase_integration.purchase)
        expect(discord_purchase_integration.reload.deleted?).to eq(false)
      end

      it "sends an email to the creator when the Gumroad bot role is lower than the member's highest role" do
        discord_purchase_integration = create(:discord_purchase_integration, integration:, discord_user_id: user_id)
        resolve_member_response.body = JSON.parse(resolve_member_response.body).merge("roles" => [admin_user_role_id]).to_json

        expect_any_instance_of(DiscordApi).to receive(:remove_member).with(server_id, user_id).and_raise(Discordrb::Errors::NoPermission)
        allow_any_instance_of(DiscordApi).to receive(:resolve_member).with(server_id, user_id).and_return(resolve_member_response)
        allow_any_instance_of(DiscordApi).to receive(:resolve_member).with(server_id, DISCORD_GUMROAD_BOT_ID).and_return(gumroad_resolve_member_response)
        expect_any_instance_of(DiscordApi).to receive(:roles).with(server_id).and_return(roles_response)
        expect(ContactingCreatorMailer).to receive(:unremovable_discord_member).and_call_original

        Integrations::DiscordIntegrationService.new.deactivate(discord_purchase_integration.purchase)
      end

      it "sends an email to the creator when the Gumroad bot role is lower than the member's highest of multiple roles" do
        discord_purchase_integration = create(:discord_purchase_integration, integration:, discord_user_id: user_id)
        resolve_member_response.body = JSON.parse(resolve_member_response.body).merge("roles" => [regular_user_role_id, admin_user_role_id]).to_json

        expect_any_instance_of(DiscordApi).to receive(:remove_member).with(server_id, user_id).and_raise(Discordrb::Errors::NoPermission)
        allow_any_instance_of(DiscordApi).to receive(:resolve_member).with(server_id, user_id).and_return(resolve_member_response)
        allow_any_instance_of(DiscordApi).to receive(:resolve_member).with(server_id, DISCORD_GUMROAD_BOT_ID).and_return(gumroad_resolve_member_response)
        expect_any_instance_of(DiscordApi).to receive(:roles).with(server_id).and_return(roles_response)
        expect(ContactingCreatorMailer).to receive(:unremovable_discord_member).and_call_original

        Integrations::DiscordIntegrationService.new.deactivate(discord_purchase_integration.purchase)
      end

      it "sends an email to the creator when the Gumoroad bot role is equal to the member's highest role" do
        discord_purchase_integration = create(:discord_purchase_integration, integration:, discord_user_id: user_id)
        resolve_member_response.body = JSON.parse(resolve_member_response.body).merge("roles" => [new_role_id]).to_json
        gumroad_resolve_member_response.body = JSON.parse(resolve_member_response.body).merge("roles" => [gumroad_bot_role_id, power_user_role_id]).to_json

        expect_any_instance_of(DiscordApi).to receive(:remove_member).with(server_id, user_id).and_raise(Discordrb::Errors::NoPermission)
        allow_any_instance_of(DiscordApi).to receive(:resolve_member).with(server_id, user_id).and_return(resolve_member_response)
        allow_any_instance_of(DiscordApi).to receive(:resolve_member).with(server_id, DISCORD_GUMROAD_BOT_ID).and_return(gumroad_resolve_member_response)
        expect_any_instance_of(DiscordApi).to receive(:roles).with(server_id).and_return(roles_response)
        expect(ContactingCreatorMailer).to receive(:unremovable_discord_member).and_call_original

        Integrations::DiscordIntegrationService.new.deactivate(discord_purchase_integration.purchase)
      end

      it "propagates the NoPermission error if it is raised when the Gumroad bot role removes a member with the default @everyone role" do
        discord_purchase_integration = create(:discord_purchase_integration, integration:, discord_user_id: user_id)

        expect_any_instance_of(DiscordApi).to receive(:remove_member).with(server_id, user_id).and_raise(Discordrb::Errors::NoPermission)
        allow_any_instance_of(DiscordApi).to receive(:resolve_member).with(server_id, user_id).and_return(resolve_member_response)

        expect do
          Integrations::DiscordIntegrationService.new.deactivate(discord_purchase_integration.purchase)
        end.to raise_error(Discordrb::Errors::NoPermission)
      end

      it "propagates the NoPermission error if it is raised when the Gumroad bot role is higher than the member's highest role" do
        discord_purchase_integration = create(:discord_purchase_integration, integration:, discord_user_id: user_id)
        resolve_member_response.body = JSON.parse(resolve_member_response.body).merge("roles" => [regular_user_role_id]).to_json

        expect_any_instance_of(DiscordApi).to receive(:remove_member).with(server_id, user_id).and_raise(Discordrb::Errors::NoPermission)
        allow_any_instance_of(DiscordApi).to receive(:resolve_member).with(server_id, user_id).and_return(resolve_member_response)
        allow_any_instance_of(DiscordApi).to receive(:resolve_member).with(server_id, DISCORD_GUMROAD_BOT_ID).and_return(gumroad_resolve_member_response)
        expect_any_instance_of(DiscordApi).to receive(:roles).with(server_id).and_return(roles_response)

        expect do
          Integrations::DiscordIntegrationService.new.deactivate(discord_purchase_integration.purchase)
        end.to raise_error(Discordrb::Errors::NoPermission)
      end

      it "propagates the NoPermission error if it is raised when the Gumroad bot is assigned a role higher than the member's highest role" do
        discord_purchase_integration = create(:discord_purchase_integration, integration:, discord_user_id: user_id)
        resolve_member_response.body = JSON.parse(resolve_member_response.body).merge("roles" => [power_user_role_id]).to_json
        gumroad_resolve_member_response.body = JSON.parse(resolve_member_response.body).merge("roles" => [gumroad_bot_role_id, admin_user_role_id]).to_json

        expect_any_instance_of(DiscordApi).to receive(:remove_member).with(server_id, user_id).and_raise(Discordrb::Errors::NoPermission)
        allow_any_instance_of(DiscordApi).to receive(:resolve_member).with(server_id, user_id).and_return(resolve_member_response)
        allow_any_instance_of(DiscordApi).to receive(:resolve_member).with(server_id, DISCORD_GUMROAD_BOT_ID).and_return(gumroad_resolve_member_response)
        expect_any_instance_of(DiscordApi).to receive(:roles).with(server_id).and_return(roles_response)

        expect do
          Integrations::DiscordIntegrationService.new.deactivate(discord_purchase_integration.purchase)
        end.to raise_error(Discordrb::Errors::NoPermission)
      end

      it "marks the purchase integration as deleted when the Discord server is deleted" do
        discord_purchase_integration = create(:discord_purchase_integration, integration:, discord_user_id: user_id)

        expect_any_instance_of(DiscordApi).to receive(:remove_member).with(server_id, user_id).and_raise(Discordrb::Errors::UnknownServer, "unknown server")

        Integrations::DiscordIntegrationService.new.deactivate(discord_purchase_integration.purchase)

        expect(discord_purchase_integration.reload.deleted?).to eq(true)
      end
    end
  end

  describe "product with variants" do
    let(:product_with_digital_versions) { create(:product_with_digital_versions, active_integrations: [integration]) }
    let(:variant_with_integration) do
      version_category = product_with_digital_versions.variant_categories.first
      variant = version_category.variants[1]
      variant.active_integrations << integration
      variant
    end
    let(:variant_without_integration) { product_with_digital_versions.variant_categories.first.variants[0] }

    describe "#deactivate" do
      it "removes member from the server if variant has integration" do
        purchase_with_integration = create(:purchase, link: product_with_digital_versions, variant_attributes: [variant_with_integration])
        purchase_integration = create(:purchase_integration, integration:, purchase: purchase_with_integration, discord_user_id: user_id)

        expect_any_instance_of(DiscordApi).to receive(:remove_member).with(server_id, user_id)

        Integrations::DiscordIntegrationService.new.deactivate(purchase_with_integration)

        expect(purchase_integration.reload.deleted?).to eq(true)
      end

      it "does nothing if variant does not have integration enabled" do
        purchase_without_integration = create(:purchase, link: product_with_digital_versions, variant_attributes: [variant_without_integration])

        expect_any_instance_of(DiscordApi).to_not receive(:remove_member)
        Integrations::DiscordIntegrationService.new.deactivate(purchase_without_integration)
      end

      it "does nothing if purchase does not have an activated integration" do
        purchase_with_integration = create(:purchase, link: product_with_digital_versions, variant_attributes: [variant_with_integration])

        expect_any_instance_of(DiscordApi).to_not receive(:remove_member)
        Integrations::DiscordIntegrationService.new.deactivate(purchase_with_integration)
      end

      it "does nothing if deactivation is disabled" do
        integration.update!(keep_inactive_members: true)
        purchase_with_integration = create(:purchase, link: product_with_digital_versions, variant_attributes: [variant_with_integration])
        purchase_integration = create(:purchase_integration, integration:, purchase: purchase_with_integration, discord_user_id: user_id)

        expect_any_instance_of(DiscordApi).to_not receive(:remove_member)
        Integrations::DiscordIntegrationService.new.deactivate(purchase_with_integration)
        expect(purchase_integration.reload.deleted?).to eq(false)
      end

      it "removes member from the server if product has integration and purchase does not have a variant specified" do
        purchase_without_variant = create(:purchase, link: product_with_digital_versions)
        purchase_integration = create(:purchase_integration, integration:, purchase: purchase_without_variant, discord_user_id: user_id)

        expect_any_instance_of(DiscordApi).to receive(:remove_member).with(server_id, user_id)

        Integrations::DiscordIntegrationService.new.deactivate(purchase_without_variant)

        expect(purchase_integration.reload.deleted?).to eq(true)
      end
    end
  end

  describe "membership product" do
    let(:membership_product) { create(:membership_product_with_preset_tiered_pricing, active_integrations: [integration]) }
    let(:tier_with_integration) do
      tier = membership_product.tiers[1]
      tier.active_integrations << integration
      tier
    end
    let(:tier_without_integration) { membership_product.tiers[0] }

    describe "#deactivate" do
      it "removes member from the server if tier has integration" do
        purchase_with_integration = create(:membership_purchase, link: membership_product, variant_attributes: [tier_with_integration])
        purchase_integration = create(:purchase_integration, integration:, purchase: purchase_with_integration, discord_user_id: user_id)

        expect_any_instance_of(DiscordApi).to receive(:remove_member).with(server_id, user_id)

        Integrations::DiscordIntegrationService.new.deactivate(purchase_with_integration)

        expect(purchase_integration.reload.deleted?).to eq(true)
      end

      it "does nothing if tier does not have integration enabled" do
        purchase_without_integration = create(:membership_purchase, link: membership_product, variant_attributes: [tier_without_integration])

        expect_any_instance_of(DiscordApi).to_not receive(:remove_member)
        Integrations::DiscordIntegrationService.new.deactivate(purchase_without_integration)
      end

      it "does nothing if purchase does not have an activated integration" do
        purchase_with_integration = create(:membership_purchase, link: membership_product, variant_attributes: [tier_with_integration])

        expect_any_instance_of(DiscordApi).to_not receive(:remove_member)
        Integrations::DiscordIntegrationService.new.deactivate(purchase_with_integration)
      end

      it "does nothing if deactivation is disabled" do
        integration.update!(keep_inactive_members: true)
        purchase_with_integration = create(:membership_purchase, link: membership_product, variant_attributes: [tier_with_integration])
        purchase_integration = create(:purchase_integration, integration:, purchase: purchase_with_integration, discord_user_id: user_id)

        expect_any_instance_of(DiscordApi).to_not receive(:remove_member)
        Integrations::DiscordIntegrationService.new.deactivate(purchase_with_integration)
        expect(purchase_integration.reload.deleted?).to eq(false)
      end
    end

    describe "#update_on_tier_change" do
      it "does nothing if new tier has integration and old tier did not" do
        purchase_without_integration = create(:membership_purchase, link: membership_product, variant_attributes: [tier_without_integration])
        subscription_without_integration = purchase_without_integration.subscription
        subscription_without_integration.update_current_plan!(
          new_variants: [tier_with_integration],
          new_price: create(:price),
          perceived_price_cents: 0,
          is_applying_plan_change: true,
        )
        subscription_without_integration.reload

        expect_any_instance_of(DiscordApi).to_not receive(:remove_member)
        Integrations::DiscordIntegrationService.new.update_on_tier_change(subscription_without_integration)
      end

      it "deactivates integration if old tier had integration and new tier does not" do
        purchase_with_integration = create(:membership_purchase, link: membership_product, variant_attributes: [tier_with_integration])
        purchase_integration = create(:purchase_integration, integration:, purchase: purchase_with_integration, discord_user_id: user_id)

        subscription_with_integration = purchase_with_integration.subscription
        subscription_with_integration.update_current_plan!(
          new_variants: [tier_without_integration],
          new_price: create(:price),
          perceived_price_cents: 0,
          is_applying_plan_change: true,
        )
        subscription_with_integration.reload

        expect_any_instance_of(DiscordApi).to receive(:remove_member).with(server_id, user_id)

        Integrations::DiscordIntegrationService.new.update_on_tier_change(subscription_with_integration)

        expect(purchase_integration.reload.deleted?).to eq(true)
      end

      it "does nothing if old tier had integration and new tier does not but the integration was not activated" do
        purchase_with_integration = create(:membership_purchase, link: membership_product, variant_attributes: [tier_with_integration])
        subscription_with_integration = purchase_with_integration.subscription
        subscription_with_integration.update_current_plan!(
          new_variants: [tier_without_integration],
          new_price: create(:price),
          perceived_price_cents: 0,
          is_applying_plan_change: true,
        )
        subscription_with_integration.reload

        expect_any_instance_of(DiscordApi).to_not receive(:remove_member)
        Integrations::DiscordIntegrationService.new.update_on_tier_change(subscription_with_integration)
      end

      it "does nothing if old tier had integration and new tier does not but deactivation is disabled" do
        purchase_with_integration = create(:membership_purchase, link: membership_product, variant_attributes: [tier_with_integration])
        purchase_integration = create(:purchase_integration, integration:, purchase: purchase_with_integration, discord_user_id: user_id)

        subscription_with_integration = purchase_with_integration.subscription
        integration.update!(keep_inactive_members: true)
        subscription_with_integration.update_current_plan!(
          new_variants: [tier_without_integration],
          new_price: create(:price),
          perceived_price_cents: 0,
          is_applying_plan_change: true,
        )
        subscription_with_integration.reload

        expect_any_instance_of(DiscordApi).to_not receive(:remove_member)
        Integrations::DiscordIntegrationService.new.update_on_tier_change(subscription_with_integration)
        expect(purchase_integration.reload.deleted?).to eq(false)
      end

      it "does nothing if new and old tier have integration" do
        purchase_with_integration = create(:membership_purchase, link: membership_product, variant_attributes: [tier_with_integration])
        purchase_integration = create(:purchase_integration, integration:, purchase: purchase_with_integration, discord_user_id: user_id)

        tier_3 = create(:variant, variant_category: membership_product.tier_category, name: "Tier 3", active_integrations: [integration])
        subscription_with_integration = purchase_with_integration.subscription
        subscription_with_integration.update_current_plan!(
          new_variants: [tier_3],
          new_price: create(:price),
          perceived_price_cents: 0,
          is_applying_plan_change: true,
        )
        subscription_with_integration.reload

        expect_any_instance_of(DiscordApi).to_not receive(:remove_member)
        Integrations::DiscordIntegrationService.new.update_on_tier_change(subscription_with_integration)
        expect(purchase_integration.reload.deleted?).to eq(false)
      end

      it "does nothing if new and old tier do not have integration" do
        purchase_without_integration = create(:membership_purchase, link: membership_product, variant_attributes: [tier_without_integration])
        tier_3 = create(:variant, variant_category: membership_product.tier_category, name: "Tier 3")
        subscription_without_integration = purchase_without_integration.subscription
        subscription_without_integration.update_current_plan!(
          new_variants: [tier_3],
          new_price: create(:price),
          perceived_price_cents: 0,
          is_applying_plan_change: true,
        )
        subscription_without_integration.reload

        expect_any_instance_of(DiscordApi).to_not receive(:remove_member)
        Integrations::DiscordIntegrationService.new.update_on_tier_change(subscription_without_integration)
      end
    end
  end
end
