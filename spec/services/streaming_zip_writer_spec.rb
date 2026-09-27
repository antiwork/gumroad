# frozen_string_literal: true

require "spec_helper"

describe StreamingZipWriter do
  def write_archive(files)
    archive = Tempfile.new(["streaming", ".zip"], binmode: true)
    writer = described_class.new(archive)
    files.each do |name, bytes|
      writer.write_entry(name, size: bytes.bytesize) do |entry_data|
        (0...bytes.bytesize).step(4096) { entry_data.write(bytes.b.byteslice(_1, 4096)) }
      end
    end
    writer.close
    archive.flush
    [archive, writer]
  end

  # Reads the way java.util.zip.ZipInputStream does: local header, inflate to the end of the deflate
  # stream, then a data descriptor whose field width follows the actual sizes. rubyzip's own
  # Zip::InputStream refuses data descriptors, so it cannot stand in for one.
  # Returns { name => [size, crc32] } computed from the inflated bytes.
  def read_forward_only(path)
    io = File.open(path, "rb")
    entries = {}
    while io.read(4) == [0x04034b50].pack("V")
      _, flags, method, _, _, _, _, _, name_length, extra_length = io.read(26).unpack("vvvvvVVVvv")
      raise "expected deflate with a data descriptor" unless method == 8 && flags & 0x0008 != 0

      name = io.read(name_length).force_encoding("UTF-8")
      io.read(extra_length)
      data_start = io.pos
      inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
      data_crc = Zlib.crc32
      until inflater.finished?
        data_crc = Zlib.crc32(inflater.inflate(io.read(16_384) || raise("truncated entry #{name}")), data_crc)
      end
      io.seek(data_start + inflater.total_in)
      zip64 = inflater.total_in > 0xFFFF_FFFF || inflater.total_out > 0xFFFF_FFFF
      signature, crc, compressed_size, size = io.read(zip64 ? 24 : 16).unpack(zip64 ? "VVQ<Q<" : "VVVV")
      raise "bad data descriptor for #{name}" unless signature == 0x08074b50 && crc == data_crc &&
                                                     compressed_size == inflater.total_in && size == inflater.total_out
      entries[name] = [size, crc]
      inflater.close
    end
    entries
  ensure
    io&.close
  end

  it "writes deflated entries that central-directory and forward-only readers both verify" do
    compressible = "hello " * 10_000
    incompressible = Random.new(1).bytes(70_000)
    files = { "Bundle/Ünïcode 文件.txt" => compressible, "Bundle/empty.bin" => "", "Other/data.bin" => incompressible }
    archive, writer = write_archive(files)

    expect(writer.bytes_written).to eq(File.size(archive.path))
    Zip::File.open(archive.path) do |zip|
      expect(zip.entries.map { _1.name.force_encoding("UTF-8") }).to eq(files.keys)
      zip.entries.each do |entry|
        bytes = files.fetch(entry.name.force_encoding("UTF-8")).b
        expect(entry.compression_method).to eq(Zip::Entry::DEFLATED)
        expect(entry.crc).to eq(Zlib.crc32(bytes))
        expect(entry.size).to eq(bytes.bytesize)
        expect(entry.get_input_stream.read).to eq(bytes)
      end
      text_entry = zip.entries.find { _1.name.force_encoding("UTF-8") == "Bundle/Ünïcode 文件.txt" }
      expect(text_entry.compressed_size).to be < compressible.bytesize / 50
    end

    expect(read_forward_only(archive.path)).to eq(files.transform_values { [_1.bytesize, Zlib.crc32(_1)] })
  ensure
    archive&.close!
  end

  it "keeps every byte when signals interrupt deflate" do
    input = Random.new(3).bytes(16.megabytes)
    stop = false
    spawner = Thread.new { system("true") until stop }
    archive, = write_archive("signals.bin" => input)
    stop = true
    spawner.join

    expect(read_forward_only(archive.path)).to eq("signals.bin" => [input.bytesize, Zlib.crc32(input)])
  ensure
    stop = true
    spawner&.join
    archive&.close!
  end

  it "rejects an entry whose bytes do not match its declared size" do
    writer = described_class.new(StringIO.new)

    expect do
      writer.write_entry("short.bin", size: 10) { _1.write("123") }
    end.to raise_error(described_class::SizeMismatchError, /declared 10 bytes, wrote 3/)
  end

  it "refuses further entries and the central directory once an entry has failed" do
    writer = described_class.new(StringIO.new)

    expect { writer.write_entry("short.bin", size: 10) { _1.write("123") } }.to raise_error(described_class::SizeMismatchError)
    expect { writer.write_entry("next.bin", size: 1) { _1.write("x") } }.to raise_error(described_class::FailedError)
    expect { writer.close }.to raise_error(described_class::FailedError)
  end

  it "leaves the modification time it is given unchanged" do
    modified_at = Time.new(2026, 9, 27, 10, 0, 0, "-05:00")

    described_class.new(StringIO.new, modified_at:)

    expect(modified_at.utc_offset).to eq(-5.hours)
  end

  it "writes the ZIP64 end records once the entry count outgrows its 16-bit field" do
    archive = Tempfile.new(["many", ".zip"], binmode: true)
    writer = described_class.new(archive)
    described_class::TWO_BYTE_MAX.times { |index| writer.write_entry("entry-#{index}", size: 0) { } }
    writer.close
    archive.flush

    bytes = File.binread(archive.path)
    expect(bytes).to include([0x06064b50].pack("V"), [0x07064b50].pack("V"))
    Zip::File.open(archive.path) { |zip| expect(zip.size).to eq(described_class::TWO_BYTE_MAX) }
  ensure
    archive&.close!
  end

  it "asks for the compressed size only where deflate can cross 4 GiB while the input does not" do
    expect(described_class.compressed_size_needed?(0)).to be(false)
    expect(described_class.compressed_size_needed?(0xFFFF_FFFF - 2.megabytes)).to be(false)
    expect(described_class.compressed_size_needed?(0xFFFF_FFFF - 64.kilobytes)).to be(true)
    expect(described_class.compressed_size_needed?(0xFFFF_FFFF)).to be(true)
    expect(described_class.compressed_size_needed?(0xFFFF_FFFF + 1)).to be(false)
  end

  it "refuses an entry that may deflate past 4 GiB unless its compressed size is given" do
    sink = StringIO.new

    expect do
      described_class.new(sink).write_entry("video.mp4", size: 0xFFFF_FFFF - 64.kilobytes) { raise "no data expected" }
    end.to raise_error(ArgumentError, /compressed size is needed/)
    expect(sink.string).to be_empty
  end

  it "rejects a compressed size the deflate output does not match" do
    writer = described_class.new(StringIO.new)

    expect do
      writer.write_entry("a.txt", size: 3, compressed_size: 999) { _1.write("abc") }
    end.to raise_error(described_class::SizeMismatchError, /expected 999 compressed bytes/)
  end

  it "marks the local header ZIP64 when the given compressed size passes 4 GiB" do
    sink = StringIO.new

    expect do
      described_class.new(sink).write_entry("a.bin", size: 3, compressed_size: 0xFFFF_FFFF + 1) { _1.write("abc") }
    end.to raise_error(described_class::SizeMismatchError)
    _, version, _, _, _, _, _, compressed_field, size_field, _, extra_length = sink.string.byteslice(0, 30).unpack("VvvvvvVVVvv")
    expect([version, compressed_field, size_field, extra_length]).to eq([45, 0xFFFF_FFFF, 0xFFFF_FFFF, 20])
  end

  it "predicts the compressed size of an entry however its input is split" do
    input = ("text " * 50_000) + Random.new(4).bytes(200_000)
    writer = described_class.new(StringIO.new)
    predicted = writer.deflated_size { |counter| (0...input.bytesize).step(1_000) { counter.write(input.b.byteslice(_1, 1_000)) } }

    writer.write_entry("mixed.bin", size: input.bytesize, compressed_size: predicted) do |entry_data|
      (0...input.bytesize).step(16_384) { entry_data.write(input.b.byteslice(_1, 16_384)) }
    end
  end

  it "keeps a compressible entry just under 4 GiB out of ZIP64 so every forward-only reader sizes it alike" do
    size = 0xFFFF_FFFF - 64.kilobytes
    zeros = "\0".b * 16.megabytes
    feed = lambda do |target|
      remaining = size
      while remaining.positive?
        chunk = remaining >= zeros.bytesize ? zeros : zeros.byteslice(0, remaining)
        target.write(chunk)
        remaining -= chunk.bytesize
      end
    end
    archive = Tempfile.new(["near-boundary", ".zip"], binmode: true)
    writer = described_class.new(archive)
    compressed_size = writer.deflated_size { feed.call(_1) }
    writer.write_entry("zeros.bin", size:, compressed_size:) { feed.call(_1) }
    writer.close
    archive.flush

    _, version, _, _, _, _, _, compressed_field, size_field, _, extra_length = File.binread(archive.path, 30).unpack("VvvvvvVVVvv")
    expect([version, compressed_field, size_field, extra_length]).to eq([20, 0, 0, 0])
    crc = Object.new.tap { |o| o.instance_variable_set(:@crc, Zlib.crc32) }
    def crc.write(bytes) = @crc = Zlib.crc32(bytes, @crc)
    feed.call(crc)
    expect(read_forward_only(archive.path)).to eq("zeros.bin" => [size, crc.instance_variable_get(:@crc)])
  ensure
    archive&.close!
  end

  it "marks an entry over 4 GiB as ZIP64 in its local header, data descriptor and central directory" do
    large_size = 4.gigabytes + 1.megabyte
    tail = "after the large entry"
    archive = Tempfile.new(["zip64", ".zip"], binmode: true)
    writer = described_class.new(archive)
    zeros = "\0".b * 16.megabytes
    expected_crc = Zlib.crc32

    writer.write_entry("large.bin", size: large_size) do |entry_data|
      remaining = large_size
      while remaining.positive?
        chunk = remaining >= zeros.bytesize ? zeros : zeros.byteslice(0, remaining)
        expected_crc = Zlib.crc32(chunk, expected_crc)
        entry_data.write(chunk)
        remaining -= chunk.bytesize
      end
    end
    writer.write_entry("tail.txt", size: tail.bytesize) { _1.write(tail) }
    writer.close
    archive.flush

    expect(File.size(archive.path)).to eq(writer.bytes_written)
    local_header = File.binread(archive.path, 30 + "large.bin".bytesize + 20)
    _, version, _, method, _, _, _, compressed_field, size_field, _, extra_length = local_header.unpack("VvvvvvVVVvv")
    expect([version, method, compressed_field, size_field, extra_length]).to eq([45, 8, 0xFFFF_FFFF, 0xFFFF_FFFF, 20])
    Zip::File.open(archive.path) do |zip|
      large = zip.find_entry("large.bin")
      expect(large.size).to eq(large_size)
      expect(large.crc).to eq(expected_crc)
      expect(zip.read("tail.txt")).to eq(tail)
    end
    expect(read_forward_only(archive.path)).to eq("large.bin" => [large_size, expected_crc], "tail.txt" => [tail.bytesize, Zlib.crc32(tail)])
  ensure
    archive&.close!
  end
end
