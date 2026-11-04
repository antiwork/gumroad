# frozen_string_literal: true

require "spec_helper"

describe AssetPreview do
  describe "#url=" do
    it "stores a playable cover from a video host outside the builtin oEmbed list" do
      vcr_turned_on do
        VCR.use_cassette("AssetPreview/framerate_cover_url") do
          preview = build(:asset_preview, link: create(:product), attach: false)

          preview.url = "https://framerate.tv/watch/AB3peBMp"

          expect(preview.oembed).to be_present
          expect(preview.oembed_url).to include("framerate.tv/embed/")
          expect(preview.oembed_width).to be_positive
          expect(preview.oembed_height).to be_positive
          expect(preview.oembed_thumbnail_url).to be_present
        end
      end
    end

    it "raises on a failed response instead of storing the error page as the cover" do
      response = Net::HTTPNotFound.new("1.1", "404", "Not Found")
      allow(response).to receive(:body).and_return("<html>Not found</html>")
      allow(SsrfFilter).to receive(:get).and_return(response)
      preview = build(:asset_preview, link: create(:product), attach: false)

      expect { preview.url = "https://example.com/missing.png" }.to raise_error(OpenURI::HTTPError, "404 Not Found")
        .and not_change { ActiveStorage::Blob.count }
      expect(preview.file).not_to be_attached
    end

    it "names the stored file from the URL path, dropping the query string" do
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response["content-type"] = "image/svg+xml"
      allow(response).to receive(:body).and_return("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")
      allow(SsrfFilter).to receive(:get).and_return(response)
      preview = build(:asset_preview, link: create(:product), attach: false)

      preview.url = "https://example.com/cover.svg?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Signature=abc123"

      expect(preview.file).to be_attached
      expect(preview.file.filename.to_s).to eq("cover.svg")
    end

    it "falls back to a default name for a root URL" do
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response["content-type"] = "image/svg+xml"
      allow(response).to receive(:body).and_return("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")
      allow(SsrfFilter).to receive(:get).and_return(response)
      preview = build(:asset_preview, link: create(:product), attach: false)

      preview.url = "https://example.com/"

      expect(preview.file.filename.to_s).to eq("cover")
    end
  end
end
