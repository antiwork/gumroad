# frozen_string_literal: true

# Writes a deflated ZIP to an append-only sink (anything with `write`), so an archive never has to
# exist as a file or a String. rubyzip cannot do this: it seeks back to patch each local header.
#
# The CRC and compressed size follow each entry in a data descriptor, which forward-only readers
# accept only for deflated entries. They disagree on how wide it is: Java 17 goes by the actual
# sizes, while libarchive and Java 21+ go by a ZIP64 extra in the local header. Both agree only when
# that extra appears exactly when an actual size passes 4 GiB, so an entry whose compressed size
# might cross 4 GiB when its input does not (see .compressed_size_needed?) needs that size up front.
class StreamingZipWriter
  class SizeMismatchError < StandardError; end
  # Raised once an entry has failed: its bytes are already in the sink, so the archive is unusable.
  class FailedError < StandardError; end
  # A second close would append another central directory.
  class ClosedError < StandardError; end

  FOUR_BYTE_MAX = 0xFFFF_FFFF
  TWO_BYTE_MAX = 0xFFFF
  VERSION_NEEDED = 20
  VERSION_NEEDED_ZIP64 = 45
  # Upper byte 3 = Unix, so external attributes carry a Unix mode that extractors apply.
  VERSION_MADE_BY = (3 << 8) | VERSION_NEEDED_ZIP64
  FLAGS = 0x0008 | 0x0800 # data descriptor follows the data; names are UTF-8
  DEFLATED = 8
  UNIX_FILE_ATTRIBUTES = 0o100644 << 16
  ZIP64_END_OF_CENTRAL_DIRECTORY_SIZE = 56
  # Fixed: #deflated_size predicts #write_entry's output only while deflate ignores how the input is
  # split, and at level 0 it does not.
  DEFLATE_LEVEL = Zlib::DEFAULT_COMPRESSION

  Entry = Struct.new(:name, :size, :compressed_size, :crc32, :offset, :zip64_local, keyword_init: true)

  # zlib's deflateBound for raw deflate at the default window and memLevel: stored blocks add
  # 5 bytes per 16 KiB, so incompressible input grows by about 1.25 MiB near 4 GiB.
  def self.deflate_bound(size)
    size + (size >> 12) + (size >> 14) + (size >> 25) + 7
  end

  def self.compressed_size_needed?(size)
    size <= FOUR_BYTE_MAX && deflate_bound(size) > FOUR_BYTE_MAX
  end

  attr_reader :bytes_written

  def initialize(sink, modified_at: Time.current)
    @sink = sink
    @bytes_written = 0
    @entries = []
    @dos_time, @dos_date = dos_time_and_date(modified_at)
  end

  # Yields a writer for the entry's uncompressed bytes. `size`, and `compressed_size` when
  # .compressed_size_needed?, must match what is written: the local header is sent before any data.
  def write_entry(name, size:, compressed_size: nil)
    raise FailedError, "an earlier entry failed" if @failed
    raise ClosedError, "the archive is closed" if @closed
    # The name length is a 16-bit field; a longer name would silently misplace every later byte.
    raise ArgumentError, "#{name[0, 40]}...: name is over #{TWO_BYTE_MAX} bytes" if name.b.bytesize > TWO_BYTE_MAX
    if compressed_size.nil? && self.class.compressed_size_needed?(size)
      raise ArgumentError, "#{name}: #{size} bytes may deflate past 4 GiB, so its compressed size is needed"
    end

    entry = Entry.new(name: name.b, size:, offset: @bytes_written,
                      zip64_local: size > FOUR_BYTE_MAX || compressed_size.to_i > FOUR_BYTE_MAX)
    begin
      write_local_header(entry)
      data = EntryData.new(self)
      begin
        yield data
        data.finish
      ensure
        data.close
      end
      raise SizeMismatchError, "#{name}: declared #{size} bytes, wrote #{data.size}" if data.size != size
      if compressed_size && data.compressed_size != compressed_size
        raise SizeMismatchError, "#{name}: expected #{compressed_size} compressed bytes, wrote #{data.compressed_size}"
      end
      if !entry.zip64_local && data.compressed_size > FOUR_BYTE_MAX
        raise SizeMismatchError, "#{name}: compressed past 4 GiB without a ZIP64 local header"
      end

      entry.crc32 = data.crc32
      entry.compressed_size = data.compressed_size
      write_data_descriptor(entry)
    rescue Exception
      @failed = true
      raise
    end
    @entries << entry
  end

  # Deflates what the block writes with #write_entry's settings and returns the compressed length,
  # discarding the output.
  def deflated_size
    data = EntryData.new(DISCARD)
    yield data
    data.finish
    data.compressed_size
  ensure
    data&.close
  end

  def close
    raise FailedError, "an earlier entry failed" if @failed
    raise ClosedError, "the archive is already closed" if @closed

    @closed = true
    central_directory_offset = @bytes_written
    @entries.each { write_central_header(_1) }
    central_directory_size = @bytes_written - central_directory_offset

    if @entries.size >= TWO_BYTE_MAX || central_directory_size >= FOUR_BYTE_MAX || central_directory_offset >= FOUR_BYTE_MAX
      zip64_end_offset = @bytes_written
      emit([0x06064b50, ZIP64_END_OF_CENTRAL_DIRECTORY_SIZE - 12, VERSION_MADE_BY, VERSION_NEEDED_ZIP64, 0, 0,
            @entries.size, @entries.size, central_directory_size, central_directory_offset].pack("VQ<vvVVQ<Q<Q<Q<"))
      emit([0x07064b50, 0, zip64_end_offset, 1].pack("VVQ<V"))
    end

    entry_count = [@entries.size, TWO_BYTE_MAX].min
    emit([0x06054b50, 0, 0, entry_count, entry_count,
          [central_directory_size, FOUR_BYTE_MAX].min, [central_directory_offset, FOUR_BYTE_MAX].min, 0].pack("VvvvvVVv"))
  end

  def emit(bytes)
    @sink.write(bytes)
    @bytes_written += bytes.bytesize
  end

  class EntryData
    attr_reader :size, :compressed_size, :crc32

    def initialize(writer)
      @writer = writer
      @deflate = Zlib::Deflate.new(DEFLATE_LEVEL, -Zlib::MAX_WBITS)
      @size = 0
      @compressed_size = 0
      @crc32 = Zlib.crc32
    end

    def write(bytes)
      @crc32 = Zlib.crc32(bytes, @crc32)
      @size += bytes.bytesize
      emit_compressed(deflate(bytes))
    end

    def finish
      emit_compressed(@deflate.finish)
    end

    def close
      @deflate.close unless @deflate.closed?
    end

    private
      # zlib 3.2.1 reruns a deflate call a signal interrupted even when it finished, and the empty
      # rerun raises BufError. The input was consumed and the output stays buffered for the next call.
      def deflate(bytes)
        @deflate.deflate(bytes)
      rescue Zlib::BufError
        "".b
      end

      def emit_compressed(bytes)
        return if bytes.empty?

        @compressed_size += bytes.bytesize
        @writer.emit(bytes)
      end
  end
  private_constant :EntryData

  module DISCARD
    def self.emit(_bytes); end
  end
  private_constant :DISCARD

  private
    def write_local_header(entry)
      zip64 = entry.zip64_local
      extra = zip64 ? [0x0001, 16, 0, 0].pack("vvQ<Q<") : "".b
      size_field = zip64 ? FOUR_BYTE_MAX : 0
      emit([0x04034b50, zip64 ? VERSION_NEEDED_ZIP64 : VERSION_NEEDED, FLAGS, DEFLATED, @dos_time, @dos_date, 0,
            size_field, size_field, entry.name.bytesize, extra.bytesize].pack("VvvvvvVVVvv"))
      emit(entry.name)
      emit(extra)
    end

    def write_data_descriptor(entry)
      if entry.size > FOUR_BYTE_MAX || entry.compressed_size > FOUR_BYTE_MAX
        emit([0x08074b50, entry.crc32, entry.compressed_size, entry.size].pack("VVQ<Q<"))
      else
        emit([0x08074b50, entry.crc32, entry.compressed_size, entry.size].pack("VVVV"))
      end
    end

    def write_central_header(entry)
      zip64_values = []
      zip64_values << entry.size if entry.size >= FOUR_BYTE_MAX
      zip64_values << entry.compressed_size if entry.compressed_size >= FOUR_BYTE_MAX
      zip64_values << entry.offset if entry.offset >= FOUR_BYTE_MAX
      extra = zip64_values.empty? ? "".b : [0x0001, 8 * zip64_values.size, *zip64_values].pack("vvQ<*")
      emit([0x02014b50, VERSION_MADE_BY, zip64_values.empty? ? VERSION_NEEDED : VERSION_NEEDED_ZIP64, FLAGS, DEFLATED,
            @dos_time, @dos_date, entry.crc32, [entry.compressed_size, FOUR_BYTE_MAX].min, [entry.size, FOUR_BYTE_MAX].min,
            entry.name.bytesize, extra.bytesize, 0, 0, 0, UNIX_FILE_ATTRIBUTES, [entry.offset, FOUR_BYTE_MAX].min]
             .pack("VvvvvvvVVVvvvvvVV"))
      emit(entry.name)
      emit(extra)
    end

    def dos_time_and_date(time)
      time = time.getutc
      year = time.year.clamp(1980, 2107)
      [(time.hour << 11) | (time.min << 5) | (time.sec / 2), ((year - 1980) << 9) | (time.month << 5) | time.day]
    end
end
