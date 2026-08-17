# frozen_string_literal: true

require "spec_helper"

describe Ffprobe do
  describe "#parse" do
    context "when a valid movie file is supplied" do
      let(:ffprobe_parsed) do
        Ffprobe.new(file_fixture("sample.mov")).parse
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

    # A phone films in one fixed sensor orientation and records a rotation rather
    # than rewriting the pixels, so a clip that looks portrait is often stored
    # landscape with a quarter-turn attached. Callers want the dimensions the
    # viewer sees, which is what streamio-ffmpeg already reports for every other
    # format we accept. See https://github.com/antiwork/gumroad-private/issues/1392
    context "when the video carries rotation metadata" do
      # file_fixture, not fixture_file_upload: the latter hands back a Tempfile
      # that nothing references once Ffprobe has copied the path out, and a GC
      # during the stubbing below unlinks it before parse reads it.
      def parsed_with(stream_attributes)
        probe = Ffprobe.new(file_fixture("sample.mov"))
        allow(probe).to receive(:`).and_return({ streams: [{ width: 1920, height: 1080, r_frame_rate: "30/1" }.merge(stream_attributes)] }.to_json)
        probe.parse
      end

      it "reports the displayed dimensions for a quarter turn recorded as a rotate tag" do
        parsed = parsed_with(tags: { rotate: "90" })

        expect(parsed.width).to eq(1080)
        expect(parsed.height).to eq(1920)
      end

      it "reports the displayed dimensions for a quarter turn recorded as display-matrix side data" do
        parsed = parsed_with(side_data_list: [{ side_data_type: "Display Matrix", rotation: -90 }])

        expect(parsed.width).to eq(1080)
        expect(parsed.height).to eq(1920)
      end

      it "reports the displayed dimensions for a three-quarter turn" do
        parsed = parsed_with(tags: { rotate: "270" })

        expect(parsed.width).to eq(1080)
        expect(parsed.height).to eq(1920)
      end

      # Some phones and editors leave a "rotate: 0" tag behind next to a real
      # quarter turn in the display matrix. The turn still happens on playback,
      # so the leftover tag must not win just because it is present.
      it "reports the displayed dimensions when a leftover zero rotate tag sits next to a quarter turn in the display matrix" do
        parsed = parsed_with(tags: { rotate: "0" }, side_data_list: [{ side_data_type: "Display Matrix", rotation: -90 }])

        expect(parsed.width).to eq(1080)
        expect(parsed.height).to eq(1920)
      end

      it "reports the displayed dimensions when a leftover zero rotate tag sits next to a three-quarter turn in the display matrix" do
        parsed = parsed_with(tags: { rotate: "0" }, side_data_list: [{ side_data_type: "Display Matrix", rotation: -270 }])

        expect(parsed.width).to eq(1080)
        expect(parsed.height).to eq(1920)
      end

      it "prefers the rotate tag when it describes a turn and the display matrix does not" do
        parsed = parsed_with(tags: { rotate: "90" }, side_data_list: [{ side_data_type: "Display Matrix", rotation: 0 }])

        expect(parsed.width).to eq(1080)
        expect(parsed.height).to eq(1920)
      end

      it "leaves the dimensions alone for a half turn, which does not change the shape" do
        parsed = parsed_with(tags: { rotate: "180" })

        expect(parsed.width).to eq(1920)
        expect(parsed.height).to eq(1080)
      end

      it "leaves the dimensions alone when there is no rotation" do
        parsed = parsed_with({})

        expect(parsed.width).to eq(1920)
        expect(parsed.height).to eq(1080)
      end
    end
  end
end
