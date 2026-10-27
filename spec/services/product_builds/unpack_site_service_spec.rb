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

  def upload_zip(entries, symlink: nil, raw_name: nil)
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
    s3.put_object(bucket: S3_BUCKET, key: build.storage_key, body: buffer.string)
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

      it "rejects a zip with no index.html at its root" do
        upload_zip({ "game/index.html" => "<html></html>" })

        expect { described_class.perform(build) }.to raise_error(described_class::UnpackError, /no index.html at its root/)
        expect(build.reload.site_unpack_error).to match(/no index.html at its root/)
      end
    end
  end
end
