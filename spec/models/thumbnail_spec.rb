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
  end
end
