# frozen_string_literal: true

require "spec_helper"

describe Ffprobe do
  describe "#parse" do
    context "when a valid movie file is supplied" do
      let(:ffprobe_parsed) do
        Ffprobe.new(fixture_file_upload("sample.mov")).parse
      end

      expected_ffprobe_data = {
        bit_rate: "27506",
        duration: "4.483333",
        height: 132,
        r_frame_rate: "60/1",
        width: 176
      }

      expected_ffprobe_data.each do |property, value|
        it "has the correct value for #{property}" do
          expect(ffprobe_parsed.public_send(property)).to eq value
        end
      end
    end

    context "when a video file with multiple audio streams encoded before the video stream is supplied" do
      #
      # The file has three streams:
      # streams[0] is an audio track
      # streams[1] is another audio track
      # streams[2] is the video track
      # These specs ensure that the order of streams does not matter and we select the video track correctly
      #

      let(:ffprobe_parsed) do
        Ffprobe.new(file_fixture("video_with_multiple_audio_tracks.mov")).parse
      end

      expected_ffprobe_data = {
        bit_rate: "34638",
        duration: "1.016667",
        height: 24,
        r_frame_rate: "60/1",
        width: 28
      }

      expected_ffprobe_data.each do |property, value|
        it "has the correct value for #{property}" do
          expect(ffprobe_parsed.public_send(property)).to eq value
        end
      end
    end

    context "when an invalid movie file is supplied" do
      it "raises a NoMethodError" do
        expect { Ffprobe.new(fixture_file("sample.epub")).parse }.to raise_error(NoMethodError)
      end
    end

    context "when a non-existent file is supplied" do
      it "raises an ArgumentError" do
        file_path = File.join(Rails.root, "spec", "sample_data", "non-existent.mov")
        expect { Ffprobe.new(file_path).parse }.to raise_error(ArgumentError, "File not found #{file_path}")
      end
    end
  end
end
