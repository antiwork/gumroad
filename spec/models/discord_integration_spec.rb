# frozen_string_literal: true

require "spec_helper"

describe DiscordIntegration do
  it "creates the correct json details" do
    integration = create(:discord_integration)
    DiscordIntegration::INTEGRATION_DETAILS.each do |detail|
      expect(integration.respond_to?(detail)).to eq true
    end
  end

  it "saves details correctly" do
    integration = create(:discord_integration)
    expect(integration.type).to eq(Integration.type_for(Integration::DISCORD))
    expect(integration.server_id).to eq("0")
    expect(integration.server_name).to eq("Gaming")
    expect(integration.username).to eq("gumbot")
    expect(integration.keep_inactive_members).to eq(false)
  end

  describe "#as_json" do
    it "returns the correct json object" do
      integration = create(:discord_integration)
      expect(integration.as_json).to eq({ keep_inactive_members: false,
                                          name: "discord", integration_details: {
                                            "server_id" => "0",
                                            "server_name" => "Gaming",
                                            "username" => "gumbot",
                                          } })
    end
  end

  describe ".is_enabled_for" do
    it "returns true if a discord integration is enabled on the product" do
      product = create(:product, active_integrations: [create(:discord_integration)])
      purchase = create(:purchase, link: product)
      expect(DiscordIntegration.is_enabled_for(purchase)).to eq(true)
    end

    it "returns false if a discord integration is not enabled on the product" do
      product = create(:product, active_integrations: [create(:circle_integration)])
      purchase = create(:purchase, link: product)
      expect(DiscordIntegration.is_enabled_for(purchase)).to eq(false)
    end

    it "returns false if a deleted discord integration exists on the product" do
      product = create(:product, active_integrations: [create(:discord_integration)])
      purchase = create(:purchase, link: product)
      product.product_integrations.first.mark_deleted!
      expect(DiscordIntegration.is_enabled_for(purchase)).to eq(false)
    end
  end

  describe ".discord_user_id_for" do
    it "returns discord_user_id for a purchase with an enabled discord integration" do
      purchase_integration = create(:discord_purchase_integration)
      expect(DiscordIntegration.discord_user_id_for(purchase_integration.purchase)).to eq("user-0")
    end

    it "returns nil for a purchase without an enabled discord integration" do
      purchase = create(:purchase, link: create(:product, active_integrations: [create(:circle_integration)]))
      expect(DiscordIntegration.discord_user_id_for(purchase)).to be_nil
    end

    it "returns nil for a purchase without an active discord integration" do
      purchase_integration = create(:discord_purchase_integration, deleted_at: 1.day.ago)
      expect(DiscordIntegration.discord_user_id_for(purchase_integration.purchase)).to be_nil
    end

    it "returns nil for a purchase with a deleted discord integration" do
      purchase_integration = create(:discord_purchase_integration)
      purchase_integration.purchase.link.product_integrations.first.mark_deleted!
      expect(DiscordIntegration.discord_user_id_for(purchase_integration.purchase)).to be_nil
    end
  end

  describe "#disconnect!" do
    let(:server_id) { "0" }
    let(:request_header) { { "Authorization" => "Bot #{DISCORD_BOT_TOKEN}" } }
    let(:discord_integration) { create(:discord_integration, server_id:) }

    it "disconnects bot from server if server id is valid" do
      WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/#{server_id}").
        with(headers: request_header).
        to_return(status: 204)

      expect(discord_integration.disconnect!).to eq(true)
    end

    it "fails if bot is not added to server" do
      WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/#{server_id}").
        with(headers: request_header).
        to_return(status: 404, body: { code: Discordrb::Errors::UnknownMember.code }.to_json)

      expect(discord_integration.disconnect!).to eq(false)
    end

    it "returns true if the server has been deleted" do
      WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/users/@me/guilds/#{server_id}").
        with(headers: request_header).
        to_return(status: 404, body: { code: Discordrb::Errors::UnknownServer.code }.to_json)

      expect(discord_integration.disconnect!).to eq(true)
    end
  end

  describe "#same_connection?" do
    let(:discord_integration) { create(:discord_integration) }
    let(:same_connection_discord_integration) { create(:discord_integration) }
    let(:other_discord_integration) { create(:discord_integration, server_id: "1") }

    it "returns true if both integrations have the same server id" do
      expect(discord_integration.same_connection?(same_connection_discord_integration)).to eq(true)
    end

    it "returns false if both integrations have different server ids" do
      expect(discord_integration.same_connection?(other_discord_integration)).to eq(false)
    end

    it "returns false if both integrations have different types" do
      same_connection_discord_integration.update(type: "NotDiscordIntegration")
      expect(discord_integration.same_connection?(same_connection_discord_integration)).to eq(false)
    end
  end
end
