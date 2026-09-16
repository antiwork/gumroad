# frozen_string_literal: true

require "spec_helper"

describe Marketing::Channels::X do
  let(:seller) { create(:user, twitter_handle: "edgar", twitter_oauth_token: "tok", twitter_oauth_secret: "sec") }
  let(:product) { create(:product, user: seller) }
  let(:utm_link) { create(:utm_link, seller:, target_resource_type: :product_page, target_resource_id: product.id) }
  let(:action) { create(:marketing_action, user: seller, link: product, utm_link:, copy: "New thing").tap(&:approve!) }

  def stub_tweets(status:, body:)
    WebMock.stub_request(:post, Marketing::XApi::TWEETS_URL)
           .to_return(status:, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  it "posts the copy plus tagged link signed as the seller and records the post" do
    stub_tweets(status: 201, body: { data: { id: "1790", text: "New thing" } })

    result = described_class.new(action).call

    expect(WebMock).to have_requested(:post, Marketing::XApi::TWEETS_URL).with { |req|
      req.headers["Authorization"].include?('oauth_token="tok"') &&
        JSON.parse(req.body) == { "text" => "New thing\n\n#{utm_link.short_url}" }
    }
    expect(result.action).to be_posted
    expect(result.action).to have_attributes(external_post_id: "1790", external_url: "https://x.com/edgar/status/1790")
  end

  it "keeps the action open with the reason and returns the intent fallback when the token cannot write" do
    stub_tweets(status: 403, body: { title: "Forbidden", detail: "oauth1-permissions" })

    result = described_class.new(action).call

    expect(result.action).to be_approved
    expect(result.action).not_to be_terminal
    expect(result.action.error_code).to eq("x_write_permission_missing")
    expect(result.intent_url).to include("twitter.com/intent/tweet").and include(CGI.escape(utm_link.short_url))
    expect(result.connect_path).to eq("/settings/social_connections")
  end

  it "fails without calling X when the seller has no user token" do
    seller.update!(twitter_oauth_token: nil)
    result = described_class.new(action).call
    expect(result.action.error_code).to eq("x_write_permission_missing")
    expect(result.action).to be_approved
    expect(WebMock).not_to have_requested(:post, Marketing::XApi::TWEETS_URL)
  end

  it "re-checks ownership and publish state at execution" do
    product.update!(draft: true)
    expect(described_class.new(action).call.action.error_code).to eq("product_not_published")

    other = create(:marketing_action, user: seller, link: create(:product), copy: "x").tap(&:approve!)
    expect(described_class.new(other).call.action.error_code).to eq("product_ownership_changed")
  end

  it "refuses to post an action the seller has not approved" do
    unapproved = create(:marketing_action, user: seller, link: product, copy: "x")
    result = described_class.new(unapproved).call
    expect(result.action).to be_recommended
    expect(result.action.error_code).to eq("not_approved")
    expect(WebMock).not_to have_requested(:post, Marketing::XApi::TWEETS_URL)
  end

  it "is idempotent once posted" do
    stub_tweets(status: 201, body: { data: { id: "1" } })
    described_class.new(action).call
    described_class.new(action.reload).call
    expect(WebMock).to have_requested(:post, Marketing::XApi::TWEETS_URL).once
  end

  it "lets only one of two racing requests call X" do
    stub_tweets(status: 201, body: { data: { id: "1" } })
    other_request = Marketing::Action.find(action.id)

    described_class.new(action).call
    described_class.new(other_request).call

    expect(WebMock).to have_requested(:post, Marketing::XApi::TWEETS_URL).once
    expect(action.reload).to be_posted
  end

  it "closes an attempt that died mid-flight as an unknown result instead of resending it" do
    action.update!(status: "queued", queued_at: 10.minutes.ago)

    result = described_class.new(action).call

    expect(WebMock).not_to have_requested(:post, Marketing::XApi::TWEETS_URL)
    expect(result.action).to be_failed
    expect(result.action.error_code).to eq("x_post_result_unknown")
  end

  it "leaves an attempt that is still in flight alone" do
    action.update!(status: "queued", queued_at: 5.seconds.ago)

    result = described_class.new(action).call

    expect(WebMock).not_to have_requested(:post, Marketing::XApi::TWEETS_URL)
    expect(result.action).to be_queued
  end

  it "records an ambiguous X response as unknown so the seller checks X before retrying" do
    stub_tweets(status: 500, body: { title: "Internal Server Error" })

    result = described_class.new(action).call

    expect(result.action).to be_failed
    expect(result.action.error_code).to eq("x_post_result_unknown")
  end

  it "records a dropped or timed-out connection as unknown instead of raising" do
    WebMock.stub_request(:post, Marketing::XApi::TWEETS_URL).to_timeout

    result = described_class.new(action).call

    expect(result.action).to be_failed
    expect(result.action.error_code).to eq("x_post_result_unknown")
    expect(WebMock).to have_requested(:post, Marketing::XApi::TWEETS_URL).once
  end

  it "clears an earlier write-permission failure once the post lands" do
    stub_tweets(status: 403, body: {})
    described_class.new(action).call
    expect(action.reload.error_code).to eq("x_write_permission_missing")

    stub_tweets(status: 201, body: { data: { id: "9" } })
    result = described_class.new(action.reload).call

    expect(result.action).to be_posted
    expect(result.action.error_code).to be_nil
  end
end
