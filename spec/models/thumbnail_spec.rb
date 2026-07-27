# frozen_string_literal: true

require "spec_helper"

describe Thumbnail do
  before do
    @product = create(:product)
  end

  describe "#validate_file" do
    it "does not save if no file attached" do
      thumbnail = Thumbnail.new(product: @product)
      expect(thumbnail.save).to eq(false)
      expect(thumbnail.errors.full_messages).to eq(["Could not process your thumbnail, please try again."])
    end

    it "saves with a valid file attached" do
      thumbnail = Thumbnail.new(product: @product)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
      blob.analyze
      thumbnail.file.attach(blob)
      expect(thumbnail.save).to eq(true)
      expect(thumbnail.errors.full_messages).to be_empty
    end

    it "errors with invalid file attached" do
      thumbnail = Thumbnail.new(product: @product)
      thumbnail.file.attach(fixture_file_upload("blah.txt"))
      expect(thumbnail.save).to eq(false)
      expect(thumbnail.errors.full_messages).to eq(["Could not process your thumbnail, please try again."])
    end

    it "errors with svg file attached" do
      thumbnail = Thumbnail.new(product: @product)
      thumbnail.file.attach(fixture_file_upload("test-svg.svg"))
      expect(thumbnail.save).to eq(false)
      expect(thumbnail.errors.full_messages).to eq(["Could not process your thumbnail, please try again."])
    end

    it "errors with a large file attached" do
      thumbnail = Thumbnail.new(product: @product)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("error_file.jpeg"), filename: "error_file.jpeg")
      blob.analyze
      thumbnail.file.attach(blob)
      expect(thumbnail.save).to eq(false)
      expect(thumbnail.errors.full_messages).to eq(["Could not process your thumbnail, please upload an image with size smaller than 5 MB."])
    end

    it "errors with wrong dimensions" do
      thumbnail = Thumbnail.new(product: @product)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("kFDzu.png"), filename: "kFDzu.png")
      blob.analyze
      thumbnail.file.attach(blob)
      expect(thumbnail.save).to eq(false)
      expect(thumbnail.errors.full_messages).to eq(["Please upload a square thumbnail."])
    end

    context "marked deleted" do
      it "does not validate file" do
        thumbnail = Thumbnail.new(product: @product)
        thumbnail.deleted_at = Time.current
        expect(thumbnail.save).to eq(true)
        expect(thumbnail.errors.full_messages).to be_empty
      end
    end
  end

  describe "touching the product" do
    # Caches such as the seller's profile payload key on the product's updated_at, so every
    # thumbnail write has to move it. See the comment on Thumbnail#product.
    def attached_thumbnail
      thumbnail = Thumbnail.new(product: @product)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
      blob.analyze
      thumbnail.file.attach(blob)
      thumbnail
    end

    it "bumps the product's updated_at when a thumbnail is created" do
      @product.update_columns(updated_at: 1.week.ago)
      original_updated_at = @product.reload.updated_at

      attached_thumbnail.save!

      expect(@product.reload.updated_at).to be > original_updated_at
    end

    it "bumps the product's updated_at when a thumbnail is soft-deleted" do
      thumbnail = attached_thumbnail
      thumbnail.save!
      @product.update_columns(updated_at: 1.week.ago)
      original_updated_at = @product.reload.updated_at

      thumbnail.mark_deleted!

      expect(@product.reload.updated_at).to be > original_updated_at
    end
  end

  describe "#alive" do
    it "returns nil if deleted" do
      thumbnail = Thumbnail.new(product: @product)
      thumbnail.deleted_at = Time.current
      expect(thumbnail.alive).to eq(nil)
    end

    it "returns self if alive?" do
      thumbnail = Thumbnail.new(product: @product)
      expect(thumbnail.alive).to eq(thumbnail)
    end
  end

  describe "#url" do
    it "returns url if file is attached" do
      thumbnail = Thumbnail.new(product: @product)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
      blob.analyze
      thumbnail.file.attach(blob)
      thumbnail.save!
      expect(thumbnail.url).to match(PUBLIC_STORAGE_S3_BUCKET)
    end

    it "returns original file instead of variant for gifs" do
      thumbnail = Thumbnail.new(product: @product)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("test.gif"), filename: "test.gif")
      blob.analyze
      thumbnail.file.attach(blob)
      thumbnail.save!
      expect(thumbnail.url).to eq(thumbnail.file.url)
    end

    it "returns empty if no file attached" do
      thumbnail = Thumbnail.new(product: @product)
      expect(thumbnail.url).to eq(nil)
    end

    it "falls back to original file URL when MiniMagick::Error is raised" do
      thumbnail = Thumbnail.new(product: @product)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
      blob.analyze
      thumbnail.file.attach(blob)
      thumbnail.save!

      allow(thumbnail).to receive(:thumbnail_variant).and_raise(MiniMagick::Error, "corrupt image")
      expect(thumbnail.url).to match(PUBLIC_STORAGE_S3_BUCKET)
    end

    it "falls back to original file URL when ActiveStorage::Error is raised" do
      thumbnail = Thumbnail.new(product: @product)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
      blob.analyze
      thumbnail.file.attach(blob)
      thumbnail.save!

      allow(thumbnail).to receive(:thumbnail_variant).and_raise(ActiveStorage::Error, "processing failed")
      expect(thumbnail.url).to match(PUBLIC_STORAGE_S3_BUCKET)
    end

    it "falls back to original file URL when Errno::ENOENT is raised" do
      thumbnail = Thumbnail.new(product: @product)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
      blob.analyze
      thumbnail.file.attach(blob)
      thumbnail.save!

      allow(thumbnail).to receive(:thumbnail_variant).and_raise(Errno::ENOENT, "/tmp/image_processing.png")
      expect(thumbnail.url).to match(PUBLIC_STORAGE_S3_BUCKET)
    end
  end
end
