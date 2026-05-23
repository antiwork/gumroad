# frozen_string_literal: true

require "test_helper"

class VideoFileHasThumbnailTest < ActiveSupport::TestCase
  self.described_class = VideoFile::HasThumbnail



  context_ VideoFile::HasThumbnail do
    subject(:video_file) { build(:video_file) }

    let(:jpg_image) { fixture_file_upload("test.jpg") }
    let(:png_image) { fixture_file_upload("test.png") }
    let(:gif_image) { fixture_file_upload("test.gif") }

  context_ "validations" do
  context_ "when no thumbnail is attached" do
  test "is valid" do
          expect(video_file.valid?).to eq(true)
        end
      end

  context_ "when a valid thumbnail is attached" do
  test "is valid with a JPG image" do
          video_file.thumbnail.attach(jpg_image)
          expect(video_file.valid?).to eq(true)
        end

  test "is valid with a PNG image" do
          video_file.thumbnail.attach(png_image)
          expect(video_file.valid?).to eq(true)
        end

  test "is valid with a GIF image" do
          video_file.thumbnail.attach(gif_image)
          expect(video_file.valid?).to eq(true)
        end
      end

  context_ "when the thumbnail has an invalid content type" do
        let(:txt_file) { fixture_file_upload("blah.txt") }
        let(:mp4_file) { fixture_file_upload("test.mp4") }

  test "is invalid with a text file" do
          video_file.thumbnail.attach(txt_file)
          expect(video_file.valid?).to eq(false)
          expect(video_file.errors[:thumbnail]).to include("must be a JPG, PNG, or GIF image.")
        end

  test "is invalid with a video file" do
          video_file.thumbnail.attach(mp4_file)
          expect(video_file.valid?).to eq(false)
          expect(video_file.errors[:thumbnail]).to include("must be a JPG, PNG, or GIF image.")
        end
      end

  context_ "when the thumbnail is too large" do
        let(:large_image_over_5mb) { fixture_file_upload("P1110259.JPG") }

  test "is invalid with a file over 5MB" do
          video_file.thumbnail.attach(large_image_over_5mb)
          expect(video_file.valid?).to eq(false)
          expect(video_file.errors[:thumbnail]).to include("must be smaller than 5 MB.")
        end
      end
    end

  context_ "#preview_thumbnail_url" do
  context_ "when a thumbnail is attached" do
  test "returns a valid representation URL" do
          video_file.thumbnail.attach(jpg_image)
          video_file.save!

          expect(video_file.thumbnail_url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{video_file.thumbnail.key}")

          video_file.thumbnail.variant(:preview).processed
          expect(video_file.thumbnail_url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{video_file.thumbnail.variant(:preview).key}")
        end
      end

  context_ "when no thumbnail is attached" do
  test "returns nil" do
          expect(video_file.thumbnail_url).to be_nil
        end
      end
    end
  end
end
