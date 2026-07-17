# frozen_string_literal: true

require "test_helper"

# Proves the VCR ↔ Minitest wiring (test/support/vcr.rb): an existing cassette
# recorded by the RSpec suite replays under the Minitest harness with no network
# access, and an unrecorded request fails loudly rather than reaching out. If the
# VCR config is removed, the first test can't find/replay the cassette and fails.
class VcrBridgeTest < ActiveSupport::TestCase
  test "replays a cassette recorded by the RSpec suite, with no network access" do
    # Reuses spec/support/fixtures/vcr_cassettes/AssetPreview/Embeddable_link/
    # succeeds_with_a_video_URL.yml verbatim — the same name RSpec metadata derived.
    result = VCR.use_cassette("AssetPreview/Embeddable_link/succeeds_with_a_video_URL", record: :none) do
      OEmbedFinder.embeddable_from_url("https://www.youtube.com/watch?v=huKYieB4evw")
    end

    assert result, "expected the recorded YouTube oembed response to replay"
    assert_includes result[:html], "youtube.com/embed/huKYieB4evw"
    assert_equal "https://i.ytimg.com/vi/huKYieB4evw/hqdefault.jpg", result[:info]["thumbnail_url"]
  end

  test "a request absent from the cassette raises instead of hitting the network" do
    assert_raises(VCR::Errors::UnhandledHTTPRequestError) do
      VCR.use_cassette("vcr_bridge/unrecorded", record: :none) do
        Net::HTTP.get_response(URI("https://example.com/not-recorded"))
      end
    end
  end
end
