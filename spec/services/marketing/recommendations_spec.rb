# frozen_string_literal: true

require "spec_helper"

describe Marketing::Recommendations do
  let(:seller) { create(:user, twitter_handle: "edgar", twitter_oauth_token: "tok", twitter_oauth_secret: "sec") }
  let(:product) do
    create(:product, user: seller, name: "Gumstein Letters",
                     description: "<p>Ten years of letters from the Andes. Second sentence nobody needs. Third.</p>")
  end

  subject(:channels) { described_class.new(product:, seller:).call }

  it "lists every channel with only X live and the rest as coming soon" do
    expect(channels.map { _1.slice(:channel, :live) }).to eq([
                                                               { channel: "x", live: true },
                                                               { channel: "instagram", live: false },
                                                               { channel: "youtube", live: false },
                                                               { channel: "tiktok", live: false },
                                                             ])
    expect(channels.last.keys).to match_array(%i[channel label live])
  end

  it "builds the X action from the product name and first description sentence with a launch UtmLink" do
    x = channels.first
    action = x[:action]
    expect(action.copy).to eq("Gumstein Letters: Ten years of letters from the Andes.")
    expect(action.utm_link).to have_attributes(utm_source: "x", utm_medium: "social", utm_campaign: "launch",
                                               target_resource_id: product.id, seller:)
    expect(action.post_text.length).to be <= Marketing::Action::MAX_POST_LENGTH
    expect(x).to include(connected: true, handle: "edgar")
    expect(x[:intent_url]).to include(CGI.escape(action.utm_link.short_url))
  end

  it "does not invent copy beyond the product's own text" do
    product.update!(description: "")
    action = channels.first[:action]
    expect(action.copy).to eq("Gumstein Letters")
    expect(action.copy).not_to match(/limited|hurry|only|today|love/i)
  end

  it "truncates long names on a word boundary within the copy budget" do
    product.update!(name: "word " * 50, description: "tail " * 60)
    copy = channels.first[:action].copy
    expect(copy.length).to be <= Marketing::Action::MAX_COPY_LENGTH
    expect(copy).to end_with("...")
  end

  it "reuses the open action and its UtmLink on repeat calls" do
    first = channels.first[:action]
    second = described_class.new(product:, seller:).call.first[:action]
    expect(second).to eq(first)
    expect(UtmLink.where(seller:, utm_source: "x", utm_campaign: "launch").count).to eq(1)
  end

  it "reports X as not connected when the seller has no user token" do
    seller.update!(twitter_oauth_token: nil)
    expect(channels.first).to include(connected: false)
  end
end
