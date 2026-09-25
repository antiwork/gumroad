# frozen_string_literal: true

require "spec_helper"

describe Mp4Id3Tag do
  # A real box: 4-byte length, then the `ftyp` type and its brands.
  def ftyp_box(type = "ftyp")
    [16].pack("N") + "#{type}M4A " + "\x00\x00\x02\x00"
  end

  def syncsafe(size)
    [(size >> 21) & 0x7F, (size >> 14) & 0x7F, (size >> 7) & 0x7F, size & 0x7F].pack("C4")
  end

  # ID3v2 header (10 bytes) + `tag_size` bytes of tag body (+ a 10-byte footer
  # when `footer`) + the boxes an M4A starts with. `declared_size` defaults to the
  # body actually written; passing a different one produces a header that claims
  # more tag than the file holds.
  def tagged_file(boxes: ftyp_box, tag_size: 16, declared_size: nil, footer: false)
    declared_size ||= tag_size
    file = Tempfile.new(["tagged", ".m4a"], encoding: "ascii-8bit")
    file.write("ID3\x04\x00" + [footer ? 0x10 : 0x00].pack("C") + syncsafe(declared_size))
    file.write("\x00" * tag_size)
    file.write("3DI\x04\x00\x10" + syncsafe(declared_size)) if footer
    file.write(boxes)
    file.flush
    file
  end

  def leading_tag_size_for(file)
    described_class.leading_tag_size(file.path)
  ensure
    file.close!
  end

  it "returns the length of a tag that sits in front of the ftyp box" do
    expect(leading_tag_size_for(tagged_file(tag_size: 1126))).to eq(1136)
  end

  it "includes the footer of a tag that declares one" do
    expect(leading_tag_size_for(tagged_file(tag_size: 1126, footer: true))).to eq(1146)
  end

  it "detects the tag in front of an M4A written by ffmpeg" do
    m4a = File.binread(file_fixture("sine.m4a"))

    expect(leading_tag_size_for(tagged_file(tag_size: 64, boxes: m4a))).to eq(74)
  end

  it "returns nil for a file with no leading tag" do
    file = Tempfile.new(["clean", ".m4a"], encoding: "ascii-8bit")
    file.write(ftyp_box + "aaaaaaaaaaaa")
    file.flush

    expect(leading_tag_size_for(file)).to be_nil
  end

  it "returns nil when the box after a plausible tag is not ftyp" do
    expect(leading_tag_size_for(tagged_file(boxes: ftyp_box("free")))).to be_nil
  end

  it "returns nil when the ftyp type sits where the box length belongs" do
    expect(leading_tag_size_for(tagged_file(boxes: "ftypM4A \x00\x00\x02\x00"))).to be_nil
  end

  it "returns nil when the tag is larger than the file" do
    expect(leading_tag_size_for(tagged_file(tag_size: 16, declared_size: 4096))).to be_nil
  end

  it "returns nil when the size bytes are not syncsafe" do
    # These bytes read as 136 if the high bit is ignored, and that offset lands on
    # a real ftyp box — the syncsafe rule is what refuses it.
    file = Tempfile.new(["notsyncsafe", ".m4a"], encoding: "ascii-8bit")
    file.write("ID3\x04\x00\x00")
    file.write([0, 0, 0, 0x88].pack("C4"))
    file.write("\x00" * 136)
    file.write(ftyp_box)
    file.flush

    expect(leading_tag_size_for(file)).to be_nil
  end

  it "returns nil for a file shorter than an ID3 header" do
    file = Tempfile.new(["short", ".m4a"], encoding: "ascii-8bit")
    file.write("ID3\x04")
    file.flush

    expect(leading_tag_size_for(file)).to be_nil
  end

  it "returns nil for an empty file" do
    file = Tempfile.new(["empty", ".m4a"], encoding: "ascii-8bit")
    file.flush

    expect(leading_tag_size_for(file)).to be_nil
  end
end
