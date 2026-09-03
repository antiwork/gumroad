# frozen_string_literal: true

require "spec_helper"

describe YoutubeChannelFetcher do
  let(:token) { "ya29.test-token" }
  let(:channel_body) { File.read("#{Rails.root}/spec/support/fixtures/youtube_channel.json") }
  let(:playlist_body) { File.read("#{Rails.root}/spec/support/fixtures/youtube_playlist_items.json") }

  def stub_channel(body: channel_body, status: 200)
    WebMock.stub_request(:get, %r{googleapis.com/youtube/v3/channels})
           .to_return(status:, body:, headers: { "Content-Type" => "application/json" })
  end

  def stub_playlist(body: playlist_body, status: 200)
    WebMock.stub_request(:get, %r{googleapis.com/youtube/v3/playlistItems})
           .to_return(status:, body:, headers: { "Content-Type" => "application/json" })
  end

  it "returns channel metadata plus the latest upload time" do
    stub_channel
    stub_playlist

    result = described_class.new(token).fetch

    expect(result).to include(
      "id" => "UC_x5XG1OV2P6uZZ5FSM9Ttw",
      "handle" => "googledevelopers",
      "published_at" => "2007-08-23T00:34:43Z",
      "subscriber_count" => "2400000",
      "video_count" => "5800",
    )
    expect(result["last_posted_at"]).to eq(Time.iso8601("2026-08-01T12:00:00Z"))
  end

  it "returns nil when the Google account has no YouTube channel" do
    stub_channel(body: { kind: "youtube#channelListResponse", items: [] }.to_json)

    expect(described_class.new(token).fetch).to be_nil
  end

  it "returns nil when the token is blank" do
    expect(described_class.new(nil).fetch).to be_nil
  end

  it "omits handle when the channel has no custom URL" do
    body = JSON.parse(channel_body)
    body["items"][0]["snippet"].delete("customUrl")
    stub_channel(body: body.to_json)
    stub_playlist

    expect(described_class.new(token).fetch["handle"]).to be_nil
  end

  it "logs the HTTP status and returns nil on non-2xx without the body or token" do
    stub_channel(body: { error: { message: "accessNotConfigured" } }.to_json, status: 403)
    logged = []
    allow(Rails.logger).to receive(:error) { |msg| logged << msg.to_s }

    expect(described_class.new(token).fetch).to be_nil
    expect(logged.join).to include("HTTP 403")
    expect(logged.join).not_to include("accessNotConfigured")
    expect(logged.join).not_to include(token)
  end
end
