# frozen_string_literal: true

require "spec_helper"

describe SubtitleFile do
  describe "validations" do
    describe "file types" do
      shared_examples "common invalid type behavior" do |file_type:|
        before do
          @subtitle = build(:subtitle_file, url: "subtitle.#{file_type}")
        end

        it "is invalid" do
          expect(@subtitle).not_to be_valid
        end

        it "does not save the record" do
          expect do
            @subtitle.save
          end.not_to change { SubtitleFile.count }
        end

        it "displays an unsupported file type error message" do
          @subtitle.save
          expect(@subtitle.errors.full_messages[0]).to include("Subtitle type not supported.")
        end
      end

      shared_examples "common valid type behavior" do |file_type:|
        before do
          @subtitle = build(:subtitle_file, url: "subtitle.#{file_type}")
        end

        it "is valid" do
          expect(@subtitle).to be_valid
        end

        it "saves the record" do
          expect do
            @subtitle.save
          end.to change { SubtitleFile.count }.by(1)
        end
      end

      context "when uploading an invalid type" do
        include_examples "common invalid type behavior", file_type: "txt"
        include_examples "common invalid type behavior", file_type: "mov"
        include_examples "common invalid type behavior", file_type: "mp4"
        include_examples "common invalid type behavior", file_type: "mp3"

        context "and subtitle is an S3 URL" do
          before do
            @subtitle = build(:subtitle_file, url: "#{AWS_S3_ENDPOINT}/gumroad/attachments/1234/abcdef/original/My Awesome Youtube video.mov")
          end

          it "is invalid" do
            expect(@subtitle).not_to be_valid
          end
        end
      end

      context "when uploading a valid type" do
        include_examples "common valid type behavior", file_type: "srt"
        include_examples "common valid type behavior", file_type: "sub"
        include_examples "common valid type behavior", file_type: "sbv"
        include_examples "common valid type behavior", file_type: "vtt"

        context "and subtitle is an S3 URL" do
          before do
            @subtitle = build(:subtitle_file, url: "#{AWS_S3_ENDPOINT}/gumroad/attachments/1234/abcdef/original/My Subtitle.sub")
          end

          it "is valid" do
            expect(@subtitle).to be_valid
          end
        end
      end

      context "when updating an invalid type" do
        before do
          @subtitle = build(:subtitle_file, url: "subtitle.pdf")
          @subtitle.save!(validate: false)
        end

        it "is invalid" do
          @subtitle.url = "subtitle.txt"
          expect(@subtitle.save).to eq(false)
          expect(@subtitle.errors.full_messages[0]).to include("Subtitle type not supported.")
        end
      end
    end
  end

  describe "#has_alive_duplicate_files?" do
    let!(:file_1) { create(:subtitle_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/some-file.srt") }
    let!(:file_2) { create(:subtitle_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/some-file.srt") }

    it "returns true if there's an alive record with the same url" do
      file_1.mark_deleted
      file_1.save!
      expect(file_1.has_alive_duplicate_files?).to eq(true)
      expect(file_2.has_alive_duplicate_files?).to eq(true)
    end

    it "returns false if there's no other alive record with the same url" do
      file_1.mark_deleted
      file_1.save!
      file_2.mark_deleted
      file_2.save!
      expect(file_1.has_alive_duplicate_files?).to eq(false)
      expect(file_2.has_alive_duplicate_files?).to eq(false)
    end
  end
end
