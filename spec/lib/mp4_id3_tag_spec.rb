# frozen_string_literal: true

require "spec_helper"

describe Mp4Id3Tag do
  # ID3v2 header (10 bytes) + `tag_size` bytes of tag body + the boxes a real M4A
  # starts with. `declared_size` defaults to the body actually written; passing a
  # different one produces a header that claims more tag than the file holds.
  def tagged_file(boxes: "ftypM4A ", tag_size: 16, declared_size: nil)
    declared_size ||= tag_size
    file = Tempfile.new(["tagged", ".m4a"], encoding: "ascii-8bit")
    file.write("ID3\x04\x00\x00")
    file.write([(declared_size >> 21) & 0x7F, (declared_size >> 14) & 0x7F,
                (declared_size >> 7) & 0x7F, declared_size & 0x7F].pack("C4"))
    file.write("\x00" * tag_size)
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

  it "returns nil for a file with no leading tag" do
    file = Tempfile.new(["clean", ".m4a"], encoding: "ascii-8bit")
    file.write("ftypM4A aaaaaaaaaaaa")
    file.flush

    expect(leading_tag_size_for(file)).to be_nil
  end

  it "returns nil when the bytes after a plausible tag are not an ftyp box" do
    expect(leading_tag_size_for(tagged_file(boxes: "freeM4A "))).to be_nil
  end

  it "returns nil when the tag is larger than the file" do
    expect(leading_tag_size_for(tagged_file(tag_size: 16, declared_size: 4096))).to be_nil
  end

  it "returns nil when the size bytes are not syncsafe" do
    file = Tempfile.new(["notsyncsafe", ".m4a"], encoding: "ascii-8bit")
    file.write("ID3\x04\x00\x00\xFF\xFF\xFF\xFF")
    file.write("\x00" * 64)
    file.write("ftypM4A ")
    file.flush

    expect(leading_tag_size_for(file)).to be_nil
  end

  it "returns nil for an empty file" do
    file = Tempfile.new(["empty", ".m4a"], encoding: "ascii-8bit")
    file.flush

    expect(leading_tag_size_for(file)).to be_nil
  end
end
