# frozen_string_literal: true

require "spec_helper"

RSpec.describe VideoFile::HasThumbnail do
  subject(:video_file) { build(:video_file) }

  let(:jpg_image) { fixture_file_upload("test.jpg") }
  let(:png_image) { fixture_file_upload("test.png") }
  let(:gif_image) { fixture_file_upload("test.gif") }

  describe "validations" do
    context "when no thumbnail is attached" do
      it "is valid" do
        expect(video_file.valid?).to eq(true)
      end
    end

    context "when a valid thumbnail is attached" do
      it "is valid with a JPG image" do
        video_file.thumbnail.attach(jpg_image)
        expect(video_file.valid?).to eq(true)
      end

      it "is valid with a PNG image" do
        video_file.thumbnail.attach(png_image)
        expect(video_file.valid?).to eq(true)
      end

      it "is valid with a GIF image" do
        video_file.thumbnail.attach(gif_image)
        expect(video_file.valid?).to eq(true)
      end
    end

    context "when the thumbnail has an invalid content type" do
      let(:txt_file) { fixture_file_upload("blah.txt") }
      let(:mp4_file) { fixture_file_upload("test.mp4") }

      it "is invalid with a text file" do
        video_file.thumbnail.attach(txt_file)
        expect(video_file.valid?).to eq(false)
        expect(video_file.errors[:thumbnail]).to include("must be a JPG, PNG, or GIF image.")
      end

      it "is invalid with a video file" do
        video_file.thumbnail.attach(mp4_file)
        expect(video_file.valid?).to eq(false)
        expect(video_file.errors[:thumbnail]).to include("must be a JPG, PNG, or GIF image.")
      end
    end

    context "when the thumbnail is too large" do
      let(:large_image_over_5mb) { fixture_file_upload("P1110259.JPG") }

      it "is invalid with a file over 5MB" do
        video_file.thumbnail.attach(large_image_over_5mb)
        expect(video_file.valid?).to eq(false)
        expect(video_file.errors[:thumbnail]).to include("must be smaller than 5 MB.")
      end
    end
  end

  describe "#preview_thumbnail_url" do
    context "when a thumbnail is attached" do
      it "returns a valid representation URL" do
        video_file.thumbnail.attach(jpg_image)
        video_file.save!

        expect(video_file.thumbnail_url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{video_file.thumbnail.key}")

        video_file.thumbnail.variant(:preview).processed
        expect(video_file.thumbnail_url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{video_file.thumbnail.variant(:preview).key}")
      end
    end

    context "when no thumbnail is attached" do
      it "returns nil" do
        expect(video_file.thumbnail_url).to be_nil
      end
    end
  end
end
