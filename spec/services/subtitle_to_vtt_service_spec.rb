# frozen_string_literal: true

require "spec_helper"

describe SubtitleToVttService do
  def convert(content)
    described_class.new(content).perform
  end

  describe "SRT input" do
    it "converts a simple SRT file to WebVTT with centered cue settings" do
      srt = <<~SRT
        1
        00:00:01,000 --> 00:00:04,000
        Hello there!

        2
        00:00:05,500 --> 00:00:07,250
        Second cue line one
        Second cue line two
      SRT

      expect(convert(srt)).to eq(<<~VTT)
        WEBVTT

        00:00:01.000 --> 00:00:04.000 align:center position:50%
        Hello there!

        00:00:05.500 --> 00:00:07.250 align:center position:50%
        Second cue line one
        Second cue line two
      VTT
    end

    it "converts the repo's sample SRT fixture" do
      srt = File.read(Rails.root.join("spec", "support", "fixtures", "sample.srt"))

      expect(convert(srt)).to eq(<<~VTT)
        WEBVTT

        01:20:45.138 --> 01:20:48.164 align:center position:50%
        You'd say anything now
        to get what you want.
      VTT
    end

    it "handles CRLF line endings" do
      srt = File.read(Rails.root.join("spec", "support", "fixtures", "subtitles", "crlf.srt"))

      result = convert(srt)
      expect(result).to include("00:00:01.000 --> 00:00:04.000 align:center position:50%\nHello there!")
      expect(result).to include("00:00:05.500 --> 00:00:07.250 align:center position:50%\nSecond cue line one\nSecond cue line two")
      expect(result).not_to include("\r")
    end

    it "strips a UTF-8 BOM" do
      srt = File.read(Rails.root.join("spec", "support", "fixtures", "subtitles", "bom.srt"))

      expect(convert(srt)).to eq(<<~VTT)
        WEBVTT

        00:00:01.000 --> 00:00:02.000 align:center position:50%
        BOM cue
      VTT
    end

    it "pads sloppy timestamps into the canonical VTT shape" do
      srt = <<~SRT
        1
        0:00:01,5 --> 0:00:02,75
        Short components
      SRT

      expect(convert(srt)).to include("00:00:01.500 --> 00:00:02.750 align:center position:50%")
    end

    it "keeps HTML entities and formatting tags untouched" do
      srt = <<~SRT
        1
        00:00:01,000 --> 00:00:02,000
        <i>Ol&aacute; &amp; welcome</i>
      SRT

      expect(convert(srt)).to include("<i>Ol&aacute; &amp; welcome</i>")
    end

    it "keeps overlapping cues in file order" do
      srt = <<~SRT
        1
        00:00:01,000 --> 00:00:05,000
        First (overlaps second)

        2
        00:00:03,000 --> 00:00:06,000
        Second
      SRT

      result = convert(srt)
      expect(result.index("First (overlaps second)")).to be < result.index("Second")
      expect(result.scan("align:center position:50%").size).to eq(2)
    end

    it "skips malformed cues without failing the rest of the file" do
      srt = <<~SRT
        1
        this is not a timing line
        Broken cue

        2
        00:00:05,000 --> 00:00:06,000
        Good cue

        3
        00:00:07,000 --> 00:00:08,000
      SRT

      expect(convert(srt)).to eq(<<~VTT)
        WEBVTT

        00:00:05.000 --> 00:00:06.000 align:center position:50%
        Good cue
      VTT
    end

    it "returns a bare WebVTT header for an empty file" do
      expect(convert("")).to eq("WEBVTT\n")
      expect(convert(nil)).to eq("WEBVTT\n")
      expect(convert("   \n\n  ")).to eq("WEBVTT\n")
    end

    it "does not raise on invalid byte sequences" do
      expect { convert("1\n00:00:01,000 --> 00:00:02,000\nBad \xC3 byte".b) }.not_to raise_error
    end
  end

  describe "VTT input" do
    it "injects centered cue settings into VTT cues that have none" do
      vtt = <<~VTT
        WEBVTT

        00:00:01.000 --> 00:00:04.000
        Bare cue
      VTT

      expect(convert(vtt)).to eq(<<~EXPECTED)
        WEBVTT

        00:00:01.000 --> 00:00:04.000 align:center position:50%
        Bare cue
      EXPECTED
    end

    it "leaves cues that already carry settings untouched" do
      vtt = <<~VTT
        WEBVTT

        00:00:01.000 --> 00:00:04.000 line:0 align:start
        Already positioned
      VTT

      result = convert(vtt)
      expect(result).to include("00:00:01.000 --> 00:00:04.000 line:0 align:start")
      expect(result).not_to include("position:50%")
    end

    it "preserves the header line, NOTE blocks, and cue identifiers" do
      vtt = <<~VTT
        WEBVTT - with a description

        NOTE
        This is a comment

        intro
        00:00:01.000 --> 00:00:04.000
        Identified cue
      VTT

      expect(convert(vtt)).to eq(<<~EXPECTED)
        WEBVTT - with a description

        NOTE
        This is a comment

        intro
        00:00:01.000 --> 00:00:04.000 align:center position:50%
        Identified cue
      EXPECTED
    end
  end
end
