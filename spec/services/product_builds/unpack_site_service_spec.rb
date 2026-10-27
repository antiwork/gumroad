# frozen_string_literal: true

require "spec_helper"

describe ProductBuilds::UnpackSiteService do
  let(:product) { create(:product) }
  let(:build) { create(:product_build, product:, number: 1) }
  let(:s3) { Aws::S3::Client.new }
  let(:site_prefix) { "builds/#{product.id}/1/site" }

  before do
    # Product ids are reused after a rollback, so a previous run's objects may still be here.
    s3.list_objects_v2(bucket: S3_BUCKET, prefix: "builds/#{product.id}/1/").contents.each do |object|
      s3.delete_object(bucket: S3_BUCKET, key: object.key)
    end
  end

  def upload_zip(entries, symlink: nil, raw_name: nil, corrupt_entry: nil)
    buffer = Zip::OutputStream.write_buffer do |zip|
      entries.each do |path, content|
        zip.put_next_entry(path)
        zip.write(content)
      end
      if symlink
        entry = Zip::Entry.new("game.zip", symlink)
        entry.fstype = Zip::FSTYPE_UNIX
        entry.instance_variable_set(:@ftype, :symlink)
        zip.put_next_entry(entry)
        zip.write("/etc/passwd")
      end
      if raw_name
        # rubyzip refuses to write a name it would reject on the way in, so the entry's name is set
        # directly: a hand-built zip can carry it, and that is what the service has to defend against.
        entry = Zip::Entry.new("game.zip", "placeholder.html")
        entry.instance_variable_set(:@name, raw_name)
        zip.put_next_entry(entry)
        zip.write("x")
      end
    end
    bytes = corrupt_entry ? corrupt_zip_entry(buffer.string, corrupt_entry) : buffer.string
    s3.put_object(bucket: S3_BUCKET, key: build.storage_key, body: bytes)
  end

  # rubyzip only writes archives it can read back, so the compressed bytes of one entry are
  # overwritten in a zip it just wrote: the central directory still looks valid, which is what a
  # zip that is damaged in transit looks like.
  def corrupt_zip_entry(zip_bytes, entry_index)
    bytes = zip_bytes.b
    offset = -1
    (entry_index + 1).times { offset = bytes.index("PK\x03\x04".b, offset + 1) }
    name_length, extra_length = bytes[offset + 26, 4].unpack("vv")
    bytes[offset + 30 + name_length + extra_length, 12] = "\x00\xff\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa".b
    bytes
  end

  def zip_bytes(entries)
    Zip::OutputStream.write_buffer do |zip|
      entries.each do |path, content|
        zip.put_next_entry(path)
        zip.write(content)
      end
    end.string
  end

  # Points the last `count` entries of an archive's central directory at the first local header, which
  # is how a zip makes several of its entries read the same bytes without carrying them twice.
  def point_entries_at_first_local_header(zip_bytes, count)
    bytes = zip_bytes.b
    eocd_at = bytes.rindex(ProductBuilds::UnpackSiteService::EOCD_SIGNATURE)
    offset = bytes[eocd_at + 16, 4].unpack1("V")
    records = []

    loop do
      header = bytes[offset, ProductBuilds::UnpackSiteService::CENTRAL_DIRECTORY_ENTRY_FIXED_SIZE]
      break if header.nil? || !header.start_with?(ProductBuilds::UnpackSiteService::CENTRAL_DIRECTORY_ENTRY_SIGNATURE)

      name_length, extra_length, comment_length = header[28, 6].unpack("vvv")
      records << offset
      offset += ProductBuilds::UnpackSiteService::CENTRAL_DIRECTORY_ENTRY_FIXED_SIZE + name_length + extra_length + comment_length
    end

    records.last(count).each { |record| bytes[record + 42, 4] = [0].pack("V") }
    bytes
  end

  def site_keys
    s3.list_objects_v2(bucket: S3_BUCKET, prefix: "#{site_prefix}/").contents.map(&:key).sort
  end

  def content_type_of(key) = s3.head_object(bucket: S3_BUCKET, key:).content_type

  def body_of(key) = s3.get_object(bucket: S3_BUCKET, key:).body.read

  describe "#perform" do
    it "copies every file to the build's site prefix with a content type the browser can run" do
      upload_zip({
                   "index.html" => "<html>game</html>",
                   "assets/game.js" => "console.log(1)",
                   "assets/game.wasm" => "\x00asm",
                   "assets/level.json" => "{}",
                   "assets/model.glb" => "binary",
                 })

      described_class.perform(build)

      expect(site_keys).to eq([
                                "#{site_prefix}/assets/game.js",
                                "#{site_prefix}/assets/game.wasm",
                                "#{site_prefix}/assets/level.json",
                                "#{site_prefix}/assets/model.glb",
                                "#{site_prefix}/index.html",
                              ])
      expect(content_type_of("#{site_prefix}/index.html")).to eq("text/html")
      expect(content_type_of("#{site_prefix}/assets/game.js")).to eq("text/javascript")
      expect(content_type_of("#{site_prefix}/assets/game.wasm")).to eq("application/wasm")
      expect(content_type_of("#{site_prefix}/assets/level.json")).to eq("application/json")
      expect(content_type_of("#{site_prefix}/assets/model.glb")).to eq("application/octet-stream")
      expect(body_of("#{site_prefix}/index.html")).to eq("<html>game</html>")
    end

    it "unpacks a zip that wraps the site in a single folder, as `zip -r game.zip game/` produces" do
      upload_zip({
                   "game/index.html" => "<html>wrapped</html>",
                   "game/assets/game.js" => "console.log(1)",
                 })

      described_class.perform(build)

      expect(site_keys).to eq([
                                "#{site_prefix}/assets/game.js",
                                "#{site_prefix}/index.html",
                              ])
      expect(body_of("#{site_prefix}/index.html")).to eq("<html>wrapped</html>")
      expect(content_type_of("#{site_prefix}/assets/game.js")).to eq("text/javascript")
      expect(build.reload.site_ready?).to be true
      expect(build.site_file_count).to eq(2)
    end

    it "rejects a zip whose index.html is more than one folder deep" do
      # Only a single wrapping folder is stripped, so a second one leaves no index.html at the root.
      upload_zip({
                   "dist/game/index.html" => "<html>nested</html>",
                   "dist/game/assets/game.js" => "x",
                 })

      expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /no index.html at its root/)
      expect(site_keys).to be_empty
    end

    it "keeps the zip next to the files it came from" do
      upload_zip({ "index.html" => "<html></html>" })

      described_class.perform(build)

      expect(s3.head_object(bucket: S3_BUCKET, key: build.storage_key)).to be_present
    end

    it "records what came out of the zip so the build can report itself ready" do
      upload_zip({ "index.html" => "<html></html>", "app.js" => "x" })

      described_class.perform(build)

      expect(build.reload.site_unpacked_at).to be_present
      expect(build.site_file_count).to eq(2)
      expect(build.site_byte_size).to eq("<html></html>".bytesize + 1)
      expect(build.site_unpack_error).to be_nil
      expect(build.site_ready?).to be true
    end

    it "unpacks an entry whose extension is long enough to overrun a temporary filename" do
      # 245 keeps the key's own segment inside S3's 255-byte limit while the temporary filename,
      # which adds its own prefix and random part, no longer fits in it.
      long_name = "assets/asset.#{"a" * 245}"
      upload_zip({ "index.html" => "<html></html>", long_name => "x" })

      described_class.perform(build)

      expect(build.reload.site_ready?).to be true
      expect(body_of("#{site_prefix}/#{long_name}")).to eq("x")
    end

    it "does nothing when the build is already unpacked" do
      upload_zip({ "index.html" => "<html></html>" })
      described_class.perform(build)
      unpacked_at = build.reload.site_unpacked_at

      expect_any_instance_of(Aws::S3::Client).not_to receive(:put_object)

      described_class.perform(build)

      expect(build.reload.site_unpacked_at).to eq(unpacked_at)
    end

    context "when the zip is not one we can serve" do
      it "rejects an entry that tries to leave the build's folder" do
        upload_zip({ "index.html" => "<html></html>", "../evil.html" => "x" })

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /outside its own folder/)
        expect(build.reload.site_unpack_error).to match(/outside its own folder/)
        expect(build.site_ready?).to be false
        expect(site_keys).to be_empty
        expect(s3.list_objects_v2(bucket: S3_BUCKET, prefix: "builds/#{product.id}/1/").contents.map(&:key)).to eq([build.storage_key])
      end

      it "rejects an absolute path" do
        upload_zip({ "index.html" => "<html></html>" }, raw_name: "/etc/passwd")

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /absolute path/)
        expect(site_keys).to be_empty
      end

      it "rejects a path with backslashes" do
        upload_zip({ "index.html" => "<html></html>", "assets\\evil.js" => "x" })

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /unsafe name/)
        expect(site_keys).to be_empty
      end

      it "rejects a symlink entry" do
        upload_zip({ "index.html" => "<html></html>" }, symlink: "link.html")

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /cannot contain symlinks/)
        expect(site_keys).to be_empty
      end

      it "rejects a zip with more files than a build may hold" do
        stub_const("ProductBuild::MAX_SITE_FILES", 1)
        upload_zip({ "index.html" => "<html></html>", "app.js" => "x" })

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /at most 1 files/)
        expect(build.reload.site_unpack_error).to match(/at most 1 files/)
      end

      it "rejects a zip whose files unpack to more than a build may hold" do
        stub_const("ProductBuild::MAX_SITE_BYTE_SIZE", 8)
        upload_zip({ "index.html" => "<html>much longer than the budget</html>" })

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /can unpack to at most/)
        expect(build.reload.site_unpack_error).to match(/can unpack to at most/)
        expect(site_keys).to be_empty
      end

      it "rejects a zip with no index.html at its root, even after a wrapping folder is stripped" do
        upload_zip({ "game/play.html" => "<html></html>" })

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /no index.html at its root/)
        expect(build.reload.site_unpack_error).to match(/no index.html at its root/)
        expect(site_keys).to be_empty
      end

      it "rejects a zip whose files are not all inside one folder" do
        upload_zip({ "game/index.html" => "<html></html>", "readme.md" => "x" })

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /more than one top-level entry/)
        expect(build.reload.site_unpack_error).to match(/more than one top-level entry/)
        expect(site_keys).to be_empty
      end

      it "rejects a zip with more than one top-level folder" do
        upload_zip({ "game/index.html" => "<html></html>", "other/index.html" => "<html></html>" })

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /more than one top-level entry/)
        expect(site_keys).to be_empty
        expect(s3.list_objects_v2(bucket: S3_BUCKET, prefix: "builds/#{product.id}/1/").contents.map(&:key)).to eq([build.storage_key])
      end

      it "rejects an archive whose directory holds more entries than a build may hold, without opening it" do
        stub_const("ProductBuild::MAX_SITE_FILES", 1)
        upload_zip(Array.new(1_028) { |i| ["file#{i}.txt", ""] }.to_h)

        # The whole point of walking the directory first: rubyzip would have every one of those
        # entries in memory by the time the iteration could reject them.
        expect(Zip::File).not_to receive(:open_buffer)

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /The zip has more entries than a build may hold/)
        expect(build.reload.site_unpack_error).to match(/The zip has more entries than a build may hold/)
        expect(site_keys).to be_empty
      end

      it "walks the directory a ZIP64 record points at, not the one the record before it names" do
        # rubyzip reads the ZIP64 record whenever both of its signatures are in the tail, whatever
        # the classic record says, so a classic offset pointing at nothing cannot be allowed to stand
        # for the archive's directory: the entries would be counted as zero and nothing would be
        # measured.
        stub_const("ProductBuild::MAX_SITE_FILES", 1)
        bytes = zip_bytes(Array.new(1_028) { |i| ["file#{i}.txt", ""] }.to_h)
        eocd_at = bytes.rindex(described_class::EOCD_SIGNATURE)
        cdir_offset = bytes[eocd_at + 16, 4].unpack1("V")
        cdir_size = bytes[eocd_at + 12, 4].unpack1("V")
        zip64_record = described_class::ZIP64_EOCD_SIGNATURE + [44].pack("Q<") + [0, 0].pack("vv") + [0, 0].pack("VV") +
                       [1_028, 1_028].pack("Q<Q<") + [cdir_size].pack("Q<") + [cdir_offset].pack("Q<")
        locator = described_class::ZIP64_EOCD_LOCATOR_SIGNATURE + [0].pack("V") + [bytes.bytesize].pack("Q<") + [1].pack("V")
        classic_lied = bytes.dup
        classic_lied[eocd_at + 10, 2] = [1].pack("v")
        classic_lied[eocd_at + 16, 4] = [0].pack("V")
        s3.put_object(bucket: S3_BUCKET, key: build.storage_key, body: classic_lied + zip64_record + locator)

        expect(Zip::File).not_to receive(:open_buffer)

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /The zip has more entries than a build may hold/)
        expect(site_keys).to be_empty
      end

      it "rejects an archive whose entry names take up more room than a build may hold" do
        # Two entries are well inside the count cap; a name carries its own length, so the bytes are
        # what has to be budgeted.
        stub_const("ProductBuilds::UnpackSiteService::ARCHIVE_METADATA_BYTE_BUDGET", 200)
        upload_zip({ "index.html" => "<html></html>", "assets/#{"a" * 500}.js" => "x" })

        expect(Zip::File).not_to receive(:open)

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /take up more room than a build may hold/)
        expect(site_keys).to be_empty
      end

      it "rejects an archive whose entries are pointed at the same bytes" do
        # Reading an entry means reading the archive, and a zip can point every one of its entries at
        # one stream: without a read budget the same megabytes are decompressed once per entry, so the
        # work is bounded by the archive's size instead of by its entry count.
        bytes = zip_bytes({ "index.html" => SecureRandom.bytes(1.megabyte), "assets/a.js" => "a", "assets/b.js" => "b" })
        s3.put_object(bucket: S3_BUCKET, key: build.storage_key, body: point_entries_at_first_local_header(bytes, 2))

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /reads more of its own bytes/)
        expect(build.reload.site_unpack_error).to match(/reads more of its own bytes/)
        expect(site_keys).to be_empty
      end

      it "rejects an archive whose directory does not hold the entries it declares" do
        # rubyzip reads the directory the archive says it has, whatever is really there, so an archive
        # that declares more entries than it holds is one rubyzip would keep reading past what was
        # measured — a handful of records and a declared count in the millions is how a zip makes the
        # worker allocate millions of entries it never wrote.
        bytes = zip_bytes({ "index.html" => "<html></html>", "assets/a.js" => "a" })
        eocd_at = bytes.rindex(described_class::EOCD_SIGNATURE)
        bytes[eocd_at + 10, 2] = [500].pack("v")
        s3.put_object(bucket: S3_BUCKET, key: build.storage_key, body: bytes)

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /directory does not hold the entries it says/)
        expect(build.reload.site_unpack_error).to match(/directory does not hold the entries it says/)
        expect(site_keys).to be_empty
      end

      it "rejects bytes that are not an archive at all" do
        s3.put_object(bucket: S3_BUCKET, key: build.storage_key, body: "not a zip")

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /could not be read/)
        expect(build.reload.site_unpack_error).to match(/could not be read/)
        expect(build.site_ready?).to be false
        expect(s3.list_objects_v2(bucket: S3_BUCKET, prefix: "builds/#{product.id}/1/").contents.map(&:key)).to eq([build.storage_key])
      end

      it "deletes the files it already copied when a later entry cannot be decompressed" do
        upload_zip({ "index.html" => "<html></html>", "assets/app.js" => "A" * 4096 }, corrupt_entry: 1)

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /could not be read/)
        expect(build.reload.site_unpack_error).to match(/could not be read/)
        expect(site_keys).to be_empty
        expect(s3.list_objects_v2(bucket: S3_BUCKET, prefix: "builds/#{product.id}/1/").contents.map(&:key)).to eq([build.storage_key])
      end
    end
  end
end
