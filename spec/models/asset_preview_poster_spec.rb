# frozen_string_literal: true

require "spec_helper"

describe AssetPreview do
  describe "#video_poster_url" do
    let(:asset_preview) { create(:asset_preview_mov) }

    before { Rails.cache.clear }

    it "returns nil and enqueues generation when no poster exists yet" do
      # Touch the cover first so its own after_create_commit enqueue lands
      # outside the block — otherwise we'd be counting creation's job too.
      asset_preview

      expect do
        expect(asset_preview.video_poster_url).to be_nil
      end.to change { GenerateVideoPosterWorker.jobs.size }.by(1)
    end

    it "returns nil without enqueuing again once generation has failed" do
      Rails.cache.write(asset_preview.send(:video_poster_cache_key), described_class::FAILED_POSTER_SENTINEL)

      expect do
        expect(asset_preview.video_poster_url).to be_nil
      end.not_to change { GenerateVideoPosterWorker.jobs.size }
    end

    it "returns the memoized URL when the cache still holds one" do
      Rails.cache.write(asset_preview.send(:video_poster_cache_key), "https://files.example.com/cached.jpg")

      expect(asset_preview.video_poster_url).to eq("https://files.example.com/cached.jpg")
    end

    # The bug this file exists for: in production the cache store is namespaced by
    # the deploy revision, so every deploy is equivalent to a full cache clear.
    # When the poster URL lived only in the cache, that made every video cover go
    # back to rendering as a black rectangle after each deploy. Clearing the cache
    # here is that deploy in miniature — the poster must still be there afterwards.
    it "keeps returning the poster after the cache is cleared, as happens on every deploy" do
      allow(asset_preview).to receive(:persisted_video_poster_url).and_return("https://files.example.com/persisted.jpg")

      expect(asset_preview.video_poster_url).to eq("https://files.example.com/persisted.jpg")

      Rails.cache.clear

      expect do
        expect(asset_preview.video_poster_url).to eq("https://files.example.com/persisted.jpg")
      end.not_to change { GenerateVideoPosterWorker.jobs.size }
    end

    it "prefers the persisted preview over a stale cached URL" do
      Rails.cache.write(asset_preview.send(:video_poster_cache_key), "https://files.example.com/stale.jpg")
      allow(asset_preview).to receive(:persisted_video_poster_url).and_return("https://files.example.com/persisted.jpg")

      expect(asset_preview.video_poster_url).to eq("https://files.example.com/persisted.jpg")
    end

    it "rewarms the cache from the persisted preview so later renders skip the URL build" do
      allow(asset_preview).to receive(:persisted_video_poster_url).and_return("https://files.example.com/persisted.jpg")

      asset_preview.video_poster_url

      expect(Rails.cache.read(asset_preview.send(:video_poster_cache_key))).to eq("https://files.example.com/persisted.jpg")
    end

    it "falls back to nil rather than raising when the persisted preview cannot be read" do
      # A half-written preview attachment must not 500 a product page: a missing
      # poster only costs the nicety of a preview frame.
      allow(asset_preview.file.blob).to receive(:preview_image).and_raise(StandardError, "storage unavailable")

      expect { asset_preview.video_poster_url }.not_to raise_error
    end

    it "returns nil for image covers, which need no poster" do
      expect(create(:asset_preview_jpg).video_poster_url).to be_nil
    end
  end

  describe "#generate_video_poster!" do
    let(:asset_preview) { create(:asset_preview_mov) }

    before { Rails.cache.clear }

    it "reuses an already-persisted poster instead of re-running ffmpeg" do
      allow(asset_preview).to receive(:persisted_video_poster_url).and_return("https://files.example.com/persisted.jpg")
      expect(asset_preview.file).not_to receive(:preview)

      expect(asset_preview.generate_video_poster!).to eq("https://files.example.com/persisted.jpg")
    end

    it "records a sentinel and returns nil when generation raises" do
      allow(asset_preview).to receive(:persisted_video_poster_url).and_return(nil)
      allow(asset_preview.file).to receive(:preview).and_raise(StandardError, "ffmpeg missing")

      expect(asset_preview.generate_video_poster!).to be_nil
      expect(Rails.cache.read(asset_preview.send(:video_poster_cache_key))).to eq(described_class::FAILED_POSTER_SENTINEL)
    end
  end
end
