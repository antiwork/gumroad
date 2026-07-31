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

    # The memo only earns its keep if a warm hit costs nothing: the durable
    # lookup is a query against active_storage_variant_records plus a URL build,
    # and running it before the cache would mean every render pays for it.
    it "skips the durable lookup entirely on a warm cache hit" do
      Rails.cache.write(asset_preview.send(:video_poster_cache_key), "https://files.example.com/cached.jpg")
      expect(asset_preview).not_to receive(:persisted_video_poster_url)

      expect(asset_preview.video_poster_url).to eq("https://files.example.com/cached.jpg")
    end

    # The sentinel is an empty string, so it is not a usable URL — it must fall
    # through to the durable lookup like any other miss. Otherwise an hour of
    # sentinel would hide a poster a concurrent worker had just persisted.
    it "still consults the durable preview when the cache holds the failure sentinel" do
      Rails.cache.write(asset_preview.send(:video_poster_cache_key), described_class::FAILED_POSTER_SENTINEL)
      allow(asset_preview).to receive(:persisted_video_poster_url).and_return("https://files.example.com/persisted.jpg")

      expect(asset_preview.video_poster_url).to eq("https://files.example.com/persisted.jpg")
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

    # The same deploy, with nothing stubbed: a real preview_image attachment and
    # a real resized variant record, so the poster that survives the clear is the
    # one ActiveStorage actually holds rather than one the test asserted into
    # existence. This is the example that would have caught the original bug on
    # its own.
    it "keeps returning the real persisted poster across a cache clear, with no regeneration" do
      attach_poster_image(asset_preview)
      # Stands in for the worker run that made the resized copy of the poster.
      asset_preview.generate_video_poster!
      expect(asset_preview.video_poster_url).to be_present

      Rails.cache.clear
      asset_preview.file.blob.reload
      expect_any_instance_of(ActiveStorage::VariantWithRecord).not_to receive(:process)

      expect do
        expect(asset_preview.video_poster_url).to be_present
      end.not_to change { GenerateVideoPosterWorker.jobs.size }
    end

    it "rewarms the memo from the persisted preview so later renders skip the durable read" do
      allow(asset_preview).to receive(:persisted_video_poster_url).and_return("https://files.example.com/persisted.jpg")

      asset_preview.video_poster_url

      expect(Rails.cache.read(asset_preview.send(:video_poster_cache_key))).to eq("https://files.example.com/persisted.jpg")
    end

    it "falls back to nil rather than raising when the persisted preview cannot be read" do
      # A half-written preview attachment must not 500 a product page: a missing
      # poster only costs the nicety of a preview frame.
      allow(asset_preview.file.blob).to receive(:preview_image).and_raise(StandardError, "storage unavailable")

      expect(asset_preview.video_poster_url).to be_nil
    end

    it "returns nil for image covers, which need no poster" do
      expect(create(:asset_preview_jpg).video_poster_url).to be_nil
    end

    # The poster is stored full size and we serve a resized copy of it. Asking
    # ActiveStorage for the resized copy's URL before it exists makes it on the
    # spot — download, image-process, upload — so on a web request we must report
    # "no poster yet" and let the worker do that work instead. Otherwise a
    # product page with several video covers would run one image job per cover
    # while the buyer waits.
    context "when the poster is persisted but its resized copy has not been made yet" do
      let(:asset_preview) { create(:asset_preview_mov) }

      before { attach_poster_image(asset_preview) }

      it "does not process the resized copy on the request path" do
        expect_any_instance_of(ActiveStorage::VariantWithRecord).not_to receive(:process)

        asset_preview.video_poster_url
      end

      it "reports no poster and enqueues generation so a worker makes the resized copy" do
        expect do
          expect(asset_preview.video_poster_url).to be_nil
        end.to change { GenerateVideoPosterWorker.jobs.size }.by(1)
      end

      it "returns the poster on the request path once the resized copy exists" do
        # This is what the worker does.
        expect(asset_preview.generate_video_poster!).to be_present

        expect do
          expect(asset_preview.video_poster_url).to be_present
        end.not_to change { GenerateVideoPosterWorker.jobs.size }
      end
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

  # Stands in for what ffmpeg would have produced: a poster frame persisted on
  # the blob as its preview_image, without any resized copy of it yet.
  def attach_poster_image(asset_preview)
    asset_preview.file.blob.preview_image.attach(
      io: File.open(Rails.root.join("spec", "support", "fixtures", "test-small.jpg")),
      filename: "poster.jpg",
      content_type: "image/jpeg"
    )
    asset_preview.file.blob.reload
  end
end
