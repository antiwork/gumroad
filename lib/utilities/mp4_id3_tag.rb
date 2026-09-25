# frozen_string_literal: true

# Some M4A/MP4 exporters write the ID3v2 tag that belongs in an MP3 in front of a
# file's ISO-BMFF boxes. The bytes after the tag are the valid AAC-in-MP4 the
# exporter meant to write, but every decoder reads the leading `ID3` as a corrupt
# box and refuses the file, which reaches buyers as a player that never loads.
class Mp4Id3Tag
  HEADER_SIZE = 10

  def self.leading_tag_size(path)
    new(path).leading_tag_size
  end

  def initialize(path)
    @path = path
  end

  # Byte length of the leading ID3v2 tag, or nil when there is nothing to strip.
  # The `ftyp` box immediately after the tag is what makes the strip a repair
  # rather than a guess: the bytes left behind have to be a playable MP4.
  def leading_tag_size
    header = File.binread(@path, HEADER_SIZE)
    return nil unless header&.start_with?("ID3")

    size = syncsafe_size(header)
    return nil if size.nil?
    return nil unless File.binread(@path, 4, HEADER_SIZE + size) == "ftyp"

    HEADER_SIZE + size
  end

  private
    # ID3v2 sizes are "syncsafe": seven bits per byte, so a byte with its high bit
    # set means these were never tag-size bytes.
    def syncsafe_size(header)
      bytes = header.byteslice(6, 4)&.bytes
      return nil if bytes.nil? || bytes.any? { _1 >= 0x80 }

      bytes.reduce(0) { |size, byte| (size << 7) | byte }
    end
end
