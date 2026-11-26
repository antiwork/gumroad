# frozen_string_literal: true

require "spec_helper"

describe Marketing::Channels::Instagram do
  let(:seller) { create(:user) }
  let!(:identity) do
    create(:user_instagram_identity, user: seller, instagram_user_id: "17841400000000000", handle: "edgar",
                                     access_token: "ig-token", access_token_expires_at: 30.days.from_now)
  end
  let(:product) { create(:product, user: seller) }
  let(:utm_link) { create(:utm_link, seller:, target_resource_type: :product_page, target_resource_id: product.id) }
  let(:action) do
    create(:marketing_action, user: seller, link: product, utm_link:, channel: "instagram", copy: "New thing").tap(&:approve!)
  end
  let(:image) { instance_double(Marketing::InstagramImage, available?: true, url: "https://cdn.example.com/cover.jpg") }
  let(:graph) { "#{Marketing::InstagramApi::GRAPH_URL}/#{INSTAGRAM_API_VERSION}" }

  before do
    allow(Marketing::InstagramImage).to receive(:new).and_return(image)
    allow_any_instance_of(described_class).to receive(:sleep)
  end

  def stub_graph(method, path, status: 200, body: {})
    WebMock.stub_request(method, "#{graph}/#{path}")
           .to_return(status:, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def stub_container(**options) = stub_graph(:post, "17841400000000000/media", **options)
  def stub_status(code) = stub_graph(:get, "container-1?fields=status_code", body: { status_code: code })
  def stub_publish(**options) = stub_graph(:post, "17841400000000000/media_publish", **options)
  def stub_permalink = stub_graph(:get, "media-9?fields=permalink", body: { permalink: "https://www.instagram.com/p/abc/" })

  it "publishes the cover with the copy and tagged link as the caption and records the post" do
    stub_container(body: { id: "container-1" })
    stub_status("FINISHED")
    stub_publish(body: { id: "media-9" })
    stub_permalink

    result = described_class.new(action).call

    expect(WebMock).to have_requested(:post, "#{graph}/17841400000000000/media").with { |req|
      req.headers["Authorization"] == "Bearer ig-token" &&
        JSON.parse(req.body) == { "image_url" => "https://cdn.example.com/cover.jpg",
                                  "caption" => "New thing\n\n#{utm_link.short_url}" }
    }
    expect(WebMock).to have_requested(:post, "#{graph}/17841400000000000/media_publish")
      .with(body: { creation_id: "container-1" }.to_json)
    expect(result.action).to be_posted
    expect(result.action).to have_attributes(external_post_id: "media-9", external_url: "https://www.instagram.com/p/abc/")
  end

  it "waits for Instagram to finish downloading the image before publishing" do
    stub_container(body: { id: "container-1" })
    WebMock.stub_request(:get, "#{graph}/container-1?fields=status_code").to_return(
      { status: 200, body: { status_code: "IN_PROGRESS" }.to_json, headers: { "Content-Type" => "application/json" } },
      { status: 200, body: { status_code: "FINISHED" }.to_json, headers: { "Content-Type" => "application/json" } },
    )
    stub_publish(body: { id: "media-9" })
    stub_permalink

    expect(described_class.new(action).call.action).to be_posted
  end

  it "publishes nothing when Instagram cannot process the image" do
    stub_container(body: { id: "container-1" })
    stub_status("ERROR")

    result = described_class.new(action).call

    expect(result.action).to be_failed
    expect(result.action.error_code).to eq("instagram_image_not_ready")
    expect(WebMock).not_to have_requested(:post, "#{graph}/17841400000000000/media_publish")
  end

  it "keeps the action open without calling Instagram when the product has no image" do
    allow(image).to receive(:available?).and_return(false)

    result = described_class.new(action).call

    expect(result.action).to be_approved
    expect(result.action.error_code).to eq("instagram_image_missing")
    expect(WebMock).not_to have_requested(:any, /graph\.instagram\.com/)
  end

  it "keeps the action open for a reconnect when the connection never got the publish permission" do
    identity.update!(access_token: nil, access_token_expires_at: nil)

    result = described_class.new(action).call

    expect(result.action).to be_approved
    expect(result.action.error_code).to eq("instagram_publish_permission_missing")
    expect(result.connect_path).to eq("/settings/social_connections?social_connect_origin=marketing" \
                                      "&social_connect_product=#{product.unique_permalink}")
    expect(WebMock).not_to have_requested(:any, /graph\.instagram\.com/)
  end

  it "asks for a reconnect when the stored token has expired" do
    identity.update!(access_token_expires_at: 1.day.ago)

    expect(described_class.new(action).call.action.error_code).to eq("instagram_publish_permission_missing")
  end

  it "asks for a reconnect when Instagram says the token was revoked" do
    stub_container(status: 400, body: { error: { message: "Invalid OAuth access token", code: 190 } })

    result = described_class.new(action).call

    expect(result.action).to be_approved
    expect(result.action.error_code).to eq("instagram_publish_permission_missing")
  end

  it "fails cleanly when Instagram refuses the image" do
    stub_container(status: 400, body: { error: { message: "The aspect ratio is not supported", code: 36003 } })

    result = described_class.new(action).call

    expect(result.action).to be_failed
    expect(result.action.error_code).to eq("instagram_rejected")
  end

  # Publishing is the only call that makes anything public, so it is the only one whose
  # unanswered request leaves a post that may exist.
  it "never resends when the publish call's result is unknown" do
    stub_container(body: { id: "container-1" })
    stub_status("FINISHED")
    WebMock.stub_request(:post, "#{graph}/17841400000000000/media_publish").to_timeout

    result = described_class.new(action).call

    expect(result.action).to be_failed
    expect(result.action.error_code).to eq("instagram_post_result_unknown")

    described_class.new(action.reload).call
    expect(WebMock).to have_requested(:post, "#{graph}/17841400000000000/media_publish").once
  end

  it "treats a failure before publishing as retryable, since nothing went out" do
    WebMock.stub_request(:post, "#{graph}/17841400000000000/media").to_timeout

    result = described_class.new(action).call

    expect(result.action).to be_failed
    expect(result.action.error_code).to eq("instagram_unavailable")
  end

  it "does not post twice for an action that is already posted" do
    action.queue!
    action.mark_posted!

    described_class.new(action).call

    expect(WebMock).not_to have_requested(:any, /graph\.instagram\.com/)
  end

  it "closes an abandoned attempt as unknown instead of posting again" do
    action.queue!
    action.update_columns(queued_at: 5.minutes.ago)

    result = described_class.new(action).call

    expect(result.action).to be_failed
    expect(result.action.error_code).to eq("instagram_post_result_unknown")
    expect(WebMock).not_to have_requested(:any, /graph\.instagram\.com/)
  end

  it "refuses a confirmation made for different copy" do
    stale = action.confirmation_token
    action.update!(copy: "Edited after review")

    expect { described_class.new(action, confirmation_token: stale).call }.to raise_error(Marketing::Action::ConfirmationChanged)
    expect(action.reload).to be_approved
  end

  it "renews a token that is close to expiring before it posts" do
    identity.update!(access_token_expires_at: 3.days.from_now)
    WebMock.stub_request(:get, "#{Marketing::InstagramApi::GRAPH_URL}/refresh_access_token")
           .with(query: { grant_type: "ig_refresh_token", access_token: "ig-token" })
           .to_return(status: 200, body: { access_token: "fresh-token", expires_in: 60.days.to_i }.to_json,
                      headers: { "Content-Type" => "application/json" })
    stub_container(body: { id: "container-1" })
    stub_status("FINISHED")
    stub_publish(body: { id: "media-9" })
    stub_permalink

    described_class.new(action).call

    expect(identity.reload.access_token).to eq("fresh-token")
    expect(identity.access_token_expires_at).to be > 50.days.from_now
    expect(WebMock).to have_requested(:post, "#{graph}/17841400000000000/media")
      .with(headers: { "Authorization" => "Bearer fresh-token" })
  end
end
