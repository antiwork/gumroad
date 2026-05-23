# frozen_string_literal: true

require "test_helper"

class ThumbnailTest < ActiveSupport::TestCase
  self.described_class = Thumbnail



  context_ Thumbnail do
    before do
      @product = create(:product)
    end

  context_ "#validate_file" do
  test "does not save if no file attached" do
        thumbnail = Thumbnail.new(product: @product)
        expect(thumbnail.save).to eq(false)
        expect(thumbnail.errors.full_messages).to eq(["Could not process your thumbnail, please try again."])
      end

  test "saves with a valid file attached" do
        thumbnail = Thumbnail.new(product: @product)
        blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
        blob.analyze
        thumbnail.file.attach(blob)
        expect(thumbnail.save).to eq(true)
        expect(thumbnail.errors.full_messages).to be_empty
      end

  test "errors with invalid file attached" do
        thumbnail = Thumbnail.new(product: @product)
        thumbnail.file.attach(fixture_file_upload("blah.txt"))
        expect(thumbnail.save).to eq(false)
        expect(thumbnail.errors.full_messages).to eq(["Could not process your thumbnail, please try again."])
      end

  test "errors with svg file attached" do
        thumbnail = Thumbnail.new(product: @product)
        thumbnail.file.attach(fixture_file_upload("test-svg.svg"))
        expect(thumbnail.save).to eq(false)
        expect(thumbnail.errors.full_messages).to eq(["Could not process your thumbnail, please try again."])
      end

  test "errors with a large file attached" do
        thumbnail = Thumbnail.new(product: @product)
        blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("error_file.jpeg"), filename: "error_file.jpeg")
        blob.analyze
        thumbnail.file.attach(blob)
        expect(thumbnail.save).to eq(false)
        expect(thumbnail.errors.full_messages).to eq(["Could not process your thumbnail, please upload an image with size smaller than 5 MB."])
      end

  test "errors with wrong dimensions" do
        thumbnail = Thumbnail.new(product: @product)
        blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("kFDzu.png"), filename: "kFDzu.png")
        blob.analyze
        thumbnail.file.attach(blob)
        expect(thumbnail.save).to eq(false)
        expect(thumbnail.errors.full_messages).to eq(["Please upload a square thumbnail."])
      end

  context_ "marked deleted" do
  test "does not validate file" do
          thumbnail = Thumbnail.new(product: @product)
          thumbnail.deleted_at = Time.current
          expect(thumbnail.save).to eq(true)
          expect(thumbnail.errors.full_messages).to be_empty
        end
      end
    end

  context_ "#alive" do
  test "returns nil if deleted" do
        thumbnail = Thumbnail.new(product: @product)
        thumbnail.deleted_at = Time.current
        expect(thumbnail.alive).to eq(nil)
      end

  test "returns self if alive?" do
        thumbnail = Thumbnail.new(product: @product)
        expect(thumbnail.alive).to eq(thumbnail)
      end
    end

  context_ "#url" do
  test "returns url if file is attached" do
        thumbnail = Thumbnail.new(product: @product)
        blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
        blob.analyze
        thumbnail.file.attach(blob)
        thumbnail.save!
        expect(thumbnail.url).to match(PUBLIC_STORAGE_S3_BUCKET)
      end

  test "returns original file instead of variant for gifs" do
        thumbnail = Thumbnail.new(product: @product)
        blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("test.gif"), filename: "test.gif")
        blob.analyze
        thumbnail.file.attach(blob)
        thumbnail.save!
        expect(thumbnail.url).to eq(thumbnail.file.url)
      end

  test "returns empty if no file attached" do
        thumbnail = Thumbnail.new(product: @product)
        expect(thumbnail.url).to eq(nil)
      end

  test "falls back to original file URL when MiniMagick::Error is raised" do
        thumbnail = Thumbnail.new(product: @product)
        blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
        blob.analyze
        thumbnail.file.attach(blob)
        thumbnail.save!

        allow(thumbnail).to receive(:thumbnail_variant).and_raise(MiniMagick::Error, "corrupt image")
        expect(thumbnail.url).to match(PUBLIC_STORAGE_S3_BUCKET)
      end

  test "falls back to original file URL when ActiveStorage::Error is raised" do
        thumbnail = Thumbnail.new(product: @product)
        blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
        blob.analyze
        thumbnail.file.attach(blob)
        thumbnail.save!

        allow(thumbnail).to receive(:thumbnail_variant).and_raise(ActiveStorage::Error, "processing failed")
        expect(thumbnail.url).to match(PUBLIC_STORAGE_S3_BUCKET)
      end

  test "falls back to original file URL when Errno::ENOENT is raised" do
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
end
