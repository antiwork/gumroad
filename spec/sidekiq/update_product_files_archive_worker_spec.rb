# frozen_string_literal: true

require "spec_helper"

describe UpdateProductFilesArchiveWorker, :vcr do
  describe "#perform" do
    before do
      @long_file_name = "2d04543f25c2abbea7740c6abf71d07a12abff9b6ef45f1fabab0b6efb4679643f87131f869bbc7a2a146c3730ee57c65839"

      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    end

    context "when rich content provider is not present" do
      before do
        installment = create(:installment)
        installment.product_files << create(:product_file, link: nil, installment:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/magic.mp3")
        installment.product_files << create(:product_file, link: nil, installment:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/magic.mp3")
        installment.product_files << create(:product_file, link: nil, installment:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/#{@long_file_name}.csv")
        installment.product_files << create(:product_file, link: nil, installment:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/#{@long_file_name}.csv")
        installment.product_files << create(:product_file, link: nil, installment:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/#{@long_file_name}.csv")
        installment.product_files << create(:product_file, link: nil, installment:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/#{@long_file_name}.csv")
        installment.product_files << create(:streamable_video, link: nil, installment:)
        installment.product_files << create(:streamable_video, link: nil, installment:, stream_only: true)
        installment.product_files << create(:product_file, link: nil, installment:, url: "https://www.gumroad.com", filetype: "link")

        @product_files_archive = installment.product_files_archives.create!
        @product_files_archive.product_files = installment.product_files
        @product_files_archive.save!
        @product_files_archive.set_url_if_not_present
        @product_files_archive.save!
      end

      it "creates a zip archive of product files while skipping external link and stream only files" do
        expect(@product_files_archive.queueing?).to be(true)
        UpdateProductFilesArchiveWorker.new.perform(@product_files_archive.id)
        @product_files_archive.reload
        expect(@product_files_archive.ready?).to be(true)
        expect(@product_files_archive.url).to match(/gumroad-specs\/attachments_zipped/)
        expect(@product_files_archive.url).to end_with("zip")

        temp_file = Tempfile.new
        @product_files_archive.s3_object.download_file(temp_file.path)
        temp_file.rewind

        entries = []
        Zip::File.open(temp_file.path) do |zipfile|
          zipfile.each do |entry|
            entries << entry.name.force_encoding("UTF-8")
          end
        end

        temp_file.close!

        expect(entries.count).to eq(7)
        expect(entries).to include("magic.mp3")

        # Makes sure all file names in the generated zip are unique
        expect(entries).to include("magic-1.mp3")

        # Truncates long file names
        truncated_long_filename = @long_file_name.truncate_bytes(described_class::MAX_FILENAME_BYTESIZE, omission: nil)
        expect(entries).to include("#{truncated_long_filename}.csv")

        # Makes sure all file names are unique, even when filename is truncated
        expect(entries).to include("#{truncated_long_filename}-1.csv")

        expect(@product_files_archive.s3_object.content_type).to eq("application/zip")
      end

      it "defers instead of overlapping a run already building the same archive" do
        $redis.set(described_class.lock_key(@product_files_archive.id), "other-run")
        described_class.jobs.clear

        described_class.new.perform(@product_files_archive.id)

        expect(@product_files_archive.reload.queueing?).to be(true)
        expect(described_class).to have_enqueued_sidekiq_job(@product_files_archive.id).in(described_class::LOCKED_RETRY_DELAY)
        expect($redis.get(described_class.lock_key(@product_files_archive.id))).to eq("other-run")
      end

      it "releases the archive lock when the run finishes" do
        @product_files_archive.mark_deleted!

        described_class.new.perform(@product_files_archive.id)

        expect($redis.get(described_class.lock_key(@product_files_archive.id))).to be_nil
      end

      it "leaves the archive hidden when it was reset for a rebuild mid-build" do
        allow(StreamingZipWriter).to receive(:new).and_wrap_original do |original, *args, **options|
          ProductFilesArchive.where(id: @product_files_archive.id).update_all(product_files_archive_state: "queueing")
          original.call(*args, **options)
        end

        described_class.new.perform(@product_files_archive.id)

        expect(@product_files_archive.reload.product_files_archive_state).to eq("queueing")
      end

      context "when product files archive is marked as deleted" do
        before do
          @product_files_archive.mark_deleted!
        end

        it "doesn't update the archive" do
          expect do
            expect(described_class.new.perform(@product_files_archive.id)).to be_nil
          end.not_to change { @product_files_archive.reload.product_files_archive_state }
        end
      end
    end

    context "when the estimated archive size is over the limit" do
      before do
        installment = create(:installment)
        installment.product_files << create(:product_file, link: nil, installment:)
        @product_files_archive = installment.product_files_archives.create!
        @product_files_archive.product_files = installment.product_files
        @product_files_archive.save!
        installment.product_files.each do |product_file|
          product_file.update_columns(size: described_class::PRODUCT_FILES_ARCHIVE_FILE_SIZE_LIMIT + 1)
        end
      end

      it "marks the archive too large rather than failed" do
        described_class.new.perform(@product_files_archive.id)

        expect(@product_files_archive.reload.product_files_archive_state).to eq("too_large")
      end
    end

    context "when streaming the archive to S3" do
      let(:s3_client) { Aws::S3::Client.new }
      let(:installment) { create(:installment) }
      let(:source_keys) { [] }
      let(:aborted_upload_ids) { [] }

      before do
        allow_any_instance_of(Aws::S3::Client).to receive(:abort_multipart_upload).and_wrap_original do |original, params|
          aborted_upload_ids << params[:upload_id]
          original.call(params)
        end
      end

      after { source_keys.each { s3_client.delete_object(bucket: S3_BUCKET, key: _1) } }

      def source_url(bytes)
        key = "specs/streaming-archive-#{SecureRandom.hex}.bin"
        s3_client.put_object(bucket: S3_BUCKET, key:, body: bytes)
        source_keys << key
        "#{S3_BASE_URL}#{key}"
      end

      def add_file(owner, bytes, **attributes)
        create(:product_file, link: owner.is_a?(Link) ? owner : nil, installment: owner.is_a?(Installment) ? owner : nil,
                              url: source_url(bytes), **attributes)
      end

      def archive_for(owner, product_files)
        archive = owner.product_files_archives.create!(product_files:)
        archive.set_url_if_not_present
        archive.save!
        archive
      end

      def zip_entries(archive)
        body = s3_client.get_object(bucket: S3_BUCKET, key: archive.s3_key).body.read
        entries = {}
        Zip::File.open_buffer(body) do |zip|
          zip.each { |entry| entries[entry.name.force_encoding("UTF-8")] = [entry.crc, entry.get_input_stream.read] }
        end
        entries
      end

      def open_uploads(archive)
        s3_client.list_multipart_uploads(bucket: S3_BUCKET, prefix: archive.s3_key).uploads.select { _1.key == archive.s3_key }
      end

      it "stores every file byte for byte across bounded, concurrent upload parts" do
        stub_const("#{described_class}::UPLOAD_PART_SIZE", 5.megabytes)
        stub_const("#{described_class}::UPLOAD_CONCURRENCY", 2)
        large = Random.new(1).bytes(11.megabytes + 3)
        files = [
          add_file(installment, large, display_name: "Lesson"),
          add_file(installment, "second", display_name: "Lesson"),
          add_file(installment, "", display_name: "Empty"),
        ]
        archive = archive_for(installment, files)
        part_sizes = []
        part_body_classes = []
        in_flight = 0
        max_in_flight = 0
        lock = Mutex.new
        allow_any_instance_of(Aws::S3::Client).to receive(:upload_part).and_wrap_original do |original, params|
          lock.synchronize do
            part_sizes << params[:body].size
            part_body_classes << params[:body].class
            in_flight += 1
            max_in_flight = [max_in_flight, in_flight].max
          end
          sleep 0.2
          original.call(params)
        ensure
          lock.synchronize { in_flight -= 1 }
        end

        described_class.new.perform(archive.id)

        expect(archive.reload).to be_ready
        expect(zip_entries(archive)).to eq(
          "Lesson.bin" => [Zlib.crc32(large), large],
          "Lesson-1.bin" => [Zlib.crc32("second"), "second"],
          "Empty.bin" => [0, ""],
        )
        expect(part_sizes.first(2)).to eq([5.megabytes, 5.megabytes])
        expect(part_sizes.size).to eq(3)
        expect(max_in_flight).to eq(2)
        # In-memory parts were not reused, so process memory grew with the archive.
        expect(part_body_classes.uniq).to eq([Tempfile])
        stored = s3_client.head_object(bucket: S3_BUCKET, key: archive.s3_key, part_number: 1)
        expect(stored.parts_count).to eq(3)
        expect(stored.content_type).to eq("application/zip")
        expect(open_uploads(archive)).to be_empty
      end

      it "resumes a dropped source read at the byte it stopped" do
        source = Random.new(2).bytes(3.megabytes)
        archive = archive_for(installment, [add_file(installment, source, display_name: "Video")])
        ranges = []
        delivered = 0
        allow_any_instance_of(Aws::S3::Client).to receive(:get_object).and_wrap_original do |original, params, &block|
          ranges << params[:range]
          next original.call(params, &block) if ranges.size > 1 || block.nil?

          original.call(params) do |chunk|
            # Net::HTTP yields about 16 KiB per chunk, so measure what was handed over.
            partial = chunk.byteslice(0, 1.megabyte + 5)
            delivered = partial.bytesize
            block.call(partial)
            raise Errno::ECONNRESET
          end
        end

        described_class.new.perform(archive.id)

        expect(archive.reload).to be_ready
        expect(ranges).to eq(["bytes=0-#{source.bytesize - 1}", "bytes=#{delivered}-#{source.bytesize - 1}"])
        expect(zip_entries(archive)).to eq("Video.bin" => [Zlib.crc32(source), source])
      end

      it "fails and aborts the upload when a source keeps dropping before any byte arrives" do
        archive = archive_for(installment, [add_file(installment, Random.new(3).bytes(2.megabytes), display_name: "Video")])
        reads = 0
        allow_any_instance_of(Aws::S3::Client).to receive(:get_object).and_wrap_original do |original, params, &block|
          next original.call(params, &block) if block.nil?

          reads += 1
          original.call(params) { raise Errno::ECONNRESET }
        end

        expect { described_class.new.perform(archive.id) }.to raise_error(Seahorse::Client::NetworkingError)

        expect(reads).to eq(described_class::SOURCE_READ_ATTEMPTS)
        expect(archive.reload).to be_failed
        expect(aborted_upload_ids.size).to eq(1)
        expect(open_uploads(archive)).to be_empty
        expect(archive.s3_object.exists?).to be(false)
      end

      it "keeps reading a source that drops more often than the attempt limit, as long as each read makes progress" do
        source = Random.new(8).bytes(1.megabyte)
        archive = archive_for(installment, [add_file(installment, source, display_name: "Video")])
        drops = 0
        allow_any_instance_of(Aws::S3::Client).to receive(:get_object).and_wrap_original do |original, params, &block|
          next original.call(params, &block) if block.nil? || drops > described_class::SOURCE_READ_ATTEMPTS + 1

          original.call(params) do |chunk|
            block.call(chunk.byteslice(0, 1.kilobyte))
            drops += 1
            raise Errno::ECONNRESET
          end
        end

        described_class.new.perform(archive.id)

        expect(drops).to be > described_class::SOURCE_READ_ATTEMPTS
        expect(archive.reload).to be_ready
        expect(zip_entries(archive)).to eq("Video.bin" => [Zlib.crc32(source), source])
      end

      it "fails a source that needs more reads than the read limit, even when each read makes progress" do
        stub_const("#{described_class}::MAX_SOURCE_READS", 5)
        archive = archive_for(installment, [add_file(installment, Random.new(8).bytes(1.megabyte), display_name: "Video")])
        reads = 0
        allow_any_instance_of(Aws::S3::Client).to receive(:get_object).and_wrap_original do |original, params, &block|
          next original.call(params, &block) if block.nil?

          reads += 1
          original.call(params) do |chunk|
            block.call(chunk.byteslice(0, 1.kilobyte))
            raise Errno::ECONNRESET
          end
        end

        expect { described_class.new.perform(archive.id) }.to raise_error(Seahorse::Client::NetworkingError, /more than 5 reads/)

        expect(reads).to eq(5)
        expect(archive.reload).to be_failed
      end

      it "fails and aborts the upload when a source read completes without bytes" do
        archive = archive_for(installment, [add_file(installment, Random.new(8).bytes(2.megabytes), display_name: "Video")])
        reads = 0
        allow_any_instance_of(Aws::S3::Client).to receive(:get_object).and_wrap_original do |original, params, &block|
          next original.call(params, &block) if block.nil?

          reads += 1
          original.call(params) { |_chunk| }
        end

        expect { described_class.new.perform(archive.id) }.to raise_error(Seahorse::Client::NetworkingError)

        expect(reads).to eq(described_class::SOURCE_READ_ATTEMPTS)
        expect(archive.reload).to be_failed
        expect(aborted_upload_ids.size).to eq(1)
        expect(open_uploads(archive)).to be_empty
        expect(archive.s3_object.exists?).to be(false)
      end

      it "does not abort another run's upload after losing the lock during source checks" do
        archive = archive_for(installment, [add_file(installment, "bytes", display_name: "Notes")])
        other_upload_id = nil
        allow_any_instance_of(Aws::S3::Client).to receive(:head_object).and_wrap_original do |original, params|
          unless other_upload_id
            other_upload_id = s3_client.create_multipart_upload(bucket: S3_BUCKET, key: archive.s3_key).upload_id
            $redis.set(described_class.lock_key(archive.id), "other-run")
          end
          original.call(params)
        end

        described_class.new.perform(archive.id)

        expect(archive.reload).to be_in_progress
        expect($redis.get(described_class.lock_key(archive.id))).to eq("other-run")
        expect(aborted_upload_ids).not_to include(other_upload_id)
        expect(open_uploads(archive).map(&:upload_id)).to include(other_upload_id)
      ensure
        if other_upload_id
          s3_client.abort_multipart_upload(bucket: S3_BUCKET, key: archive.s3_key, upload_id: other_upload_id) rescue nil
        end
      end

      it "fails instead of mixing two versions when a source is replaced mid-build" do
        file = add_file(installment, "original bytes", display_name: "Notes")
        archive = archive_for(installment, [file])
        allow(StreamingZipWriter).to receive(:new).and_wrap_original do |original, *args, **options|
          s3_client.put_object(bucket: S3_BUCKET, key: file.s3_key, body: "replaced bytes")
          original.call(*args, **options)
        end

        expect { described_class.new.perform(archive.id) }.to raise_error(Aws::S3::Errors::PreconditionFailed)

        expect(archive.reload).to be_failed
        expect(aborted_upload_ids.size).to eq(1)
        expect(open_uploads(archive)).to be_empty
        expect(archive.s3_object.exists?).to be(false)
      end

      it "leaves an archive that was reset for a rebuild queued when its build then fails" do
        file = add_file(installment, "original bytes", display_name: "Notes")
        archive = archive_for(installment, [file])
        allow(StreamingZipWriter).to receive(:new).and_wrap_original do |original, *args, **options|
          s3_client.put_object(bucket: S3_BUCKET, key: file.s3_key, body: "replaced bytes")
          ProductFilesArchive.where(id: archive.id).update_all(product_files_archive_state: "queueing")
          original.call(*args, **options)
        end

        expect { described_class.new.perform(archive.id) }.not_to raise_error

        expect(archive.reload).to be_queueing
        expect(open_uploads(archive)).to be_empty
      end

      it "leaves an interrupted build's upload for the requeued run to abort" do
        bytes = Random.new(4).bytes(2.megabytes)
        archive = archive_for(installment, [add_file(installment, bytes, display_name: "Video")])
        interrupt = true
        allow_any_instance_of(Aws::S3::Client).to receive(:get_object).and_wrap_original do |original, params, &block|
          next original.call(params, &block) if block.nil? || !interrupt

          original.call(params) do |chunk|
            block.call(chunk)
            interrupt = false
            raise Sidekiq::Shutdown
          end
        end

        expect { described_class.new.perform(archive.id) }.to raise_error(Sidekiq::Shutdown)

        # The SDK aborts only on StandardError, so the interrupted upload stays open.
        expect(archive.reload).to be_in_progress
        expect(open_uploads(archive).size).to eq(1)
        expect(archive.s3_object.exists?).to be(false)
        expect($redis.get(described_class.lock_key(archive.id))).to be_nil

        described_class.new.perform(archive.id)

        expect(archive.reload).to be_ready
        expect(aborted_upload_ids.size).to eq(1)
        expect(open_uploads(archive)).to be_empty
        expect(zip_entries(archive)).to eq("Video.bin" => [Zlib.crc32(bytes), bytes])
      end

      it "stops without touching the archive once another run holds its lock" do
        files = [add_file(installment, "first", display_name: "One"), add_file(installment, "second", display_name: "Two")]
        archive = archive_for(installment, files)
        allow_any_instance_of(Aws::S3::Client).to receive(:get_object).and_wrap_original do |original, params, &block|
          $redis.set(described_class.lock_key(archive.id), "other-run")
          original.call(params, &block)
        end

        described_class.new.perform(archive.id)

        expect(archive.reload).to be_in_progress
        expect($redis.get(described_class.lock_key(archive.id))).to eq("other-run")
        expect(aborted_upload_ids.size).to eq(1)
        expect(open_uploads(archive)).to be_empty
        expect(archive.s3_object.exists?).to be(false)
      end

      it "retries through Sidekiq without touching the archive when its lock key vanishes" do
        files = [add_file(installment, "first", display_name: "One"), add_file(installment, "second", display_name: "Two")]
        archive = archive_for(installment, files)
        vanished = false
        allow_any_instance_of(Aws::S3::Client).to receive(:get_object).and_wrap_original do |original, params, &block|
          $redis.del(described_class.lock_key(archive.id)) unless vanished
          vanished = true
          original.call(params, &block)
        end

        expect { described_class.new.perform(archive.id) }.to raise_error(described_class::LockLostError)

        expect(archive.reload).to be_in_progress
        expect(aborted_upload_ids.size).to eq(1)
        expect(open_uploads(archive)).to be_empty
        expect(archive.s3_object.exists?).to be(false)
        expect(described_class.get_sidekiq_options["retry"]).to eq(5)

        described_class.new.perform(archive.id)

        expect(archive.reload).to be_ready
        expect(zip_entries(archive).transform_values(&:last)).to eq("One.bin" => "first", "Two.bin" => "second")
      end

      it "leaves the archive to the run that took its lock when this run then fails" do
        file = add_file(installment, "original bytes", display_name: "Notes")
        archive = archive_for(installment, [file])
        allow(StreamingZipWriter).to receive(:new).and_wrap_original do |original, *args, **options|
          s3_client.put_object(bucket: S3_BUCKET, key: file.s3_key, body: "replaced bytes")
          original.call(*args, **options)
        end
        allow_any_instance_of(Aws::S3::Client).to receive(:get_object).and_wrap_original do |original, params, &block|
          $redis.set(described_class.lock_key(archive.id), "other-run") if block
          original.call(params, &block)
        end

        expect { described_class.new.perform(archive.id) }.not_to raise_error

        expect(archive.reload).to be_in_progress
        expect($redis.get(described_class.lock_key(archive.id))).to eq("other-run")
        expect(open_uploads(archive)).to be_empty
      end

      it "does not mark the archive ready when another run took its lock during the upload" do
        archive = archive_for(installment, [add_file(installment, "bytes", display_name: "Notes")])
        allow_any_instance_of(Aws::S3::Client).to receive(:complete_multipart_upload).and_wrap_original do |original, params|
          original.call(params).tap { $redis.set(described_class.lock_key(archive.id), "other-run") }
        end

        described_class.new.perform(archive.id)

        expect(archive.reload).to be_in_progress
        expect($redis.get(described_class.lock_key(archive.id))).to eq("other-run")
      end

      it "does not report a failure that another run's lock takeover caused" do
        archive = archive_for(installment, [add_file(installment, "bytes", display_name: "Notes")])
        allow_any_instance_of(Aws::S3::Client).to receive(:upload_part).and_wrap_original do |_original, _params|
          $redis.set(described_class.lock_key(archive.id), "other-run")
          raise Aws::S3::Errors::NoSuchUpload.new(nil, "aborted by the other run")
        end
        expect(ErrorNotifier).not_to receive(:notify)

        described_class.new.perform(archive.id)

        expect(archive.reload).to be_in_progress
      end

      it "stops reading sources as soon as an upload part fails" do
        stub_const("#{described_class}::UPLOAD_PART_SIZE", 5.megabytes)
        stub_const("#{described_class}::UPLOAD_CONCURRENCY", 1)
        files = [add_file(installment, Random.new(7).bytes(16.megabytes), display_name: "Large"),
                 add_file(installment, "second", display_name: "Second")]
        archive = archive_for(installment, files)
        reads = []
        allow_any_instance_of(Aws::S3::Client).to receive(:get_object).and_wrap_original do |original, params, &block|
          next original.call(params, &block) if block.nil?

          reads << params[:key]
          # Delivered in pieces, as Net::HTTP does, so writes continue after the upload closes its pipe.
          original.call(params) { |chunk| (0...chunk.bytesize).step(64.kilobytes) { block.call(chunk.byteslice(_1, 64.kilobytes)) } }
        end
        allow_any_instance_of(Aws::S3::Client).to receive(:upload_part).and_wrap_original do |original, params|
          raise Seahorse::Client::NetworkingError.new(Errno::ECONNRESET.new, "part lost") if params[:part_number] == 1

          original.call(params)
        end

        expect { described_class.new.perform(archive.id) }.to raise_error(Seahorse::Client::NetworkingError, /part lost/)

        expect(reads).to eq([files.first.s3_key])
        expect(archive.reload).to be_failed
        expect(aborted_upload_ids.size).to eq(1)
        expect(open_uploads(archive)).to be_empty
        expect(archive.s3_object.exists?).to be(false)
      end

      it "marks an archive left in progress failed once its retries run out and no run holds its lock" do
        archive = archive_for(installment, [add_file(installment, "bytes", display_name: "Notes")])
        archive.mark_in_progress!

        described_class.sidekiq_retries_exhausted_block.call({ "args" => [archive.id] }, described_class::LockLostError.new)

        expect(archive.reload).to be_failed
      end

      it "leaves an archive in progress when its retries run out while another run holds its lock" do
        archive = archive_for(installment, [add_file(installment, "bytes", display_name: "Notes")])
        archive.mark_in_progress!
        $redis.set(described_class.lock_key(archive.id), "other-run")

        described_class.sidekiq_retries_exhausted_block.call({ "args" => [archive.id] }, described_class::LockLostError.new)

        expect(archive.reload).to be_in_progress
      end

      it "aborts an unfinished upload a killed run left on the archive key, and no other" do
        archive = archive_for(installment, [add_file(installment, "bytes", display_name: "Notes")])
        orphan = s3_client.create_multipart_upload(bucket: S3_BUCKET, key: archive.s3_key).upload_id
        s3_client.upload_part(bucket: S3_BUCKET, key: archive.s3_key, upload_id: orphan, part_number: 1, body: "orphaned part")
        neighbour_key = "#{archive.s3_key}.neighbour"
        neighbour = s3_client.create_multipart_upload(bucket: S3_BUCKET, key: neighbour_key).upload_id

        described_class.new.perform(archive.id)

        expect(archive.reload).to be_ready
        expect(aborted_upload_ids).to eq([orphan])
        expect(open_uploads(archive)).to be_empty
        expect(s3_client.list_multipart_uploads(bucket: S3_BUCKET, prefix: neighbour_key).uploads.map(&:upload_id)).to eq([neighbour])
      ensure
        s3_client.abort_multipart_upload(bucket: S3_BUCKET, key: neighbour_key, upload_id: neighbour) if neighbour
      end

      it "sizes an entry that may deflate past 4 GiB with a second read pinned to the same ETag" do
        video = Random.new(8).bytes(3.megabytes)
        file = add_file(installment, video, display_name: "Video")
        archive = archive_for(installment, [file])
        allow(StreamingZipWriter).to receive(:compressed_size_needed?).and_return(true)
        reads = []
        allow_any_instance_of(Aws::S3::Client).to receive(:get_object).and_wrap_original do |original, params, &block|
          reads << params.slice(:key, :if_match) if block
          original.call(params, &block)
        end
        compressed_sizes = []
        allow_any_instance_of(StreamingZipWriter).to receive(:write_entry).and_wrap_original do |original, name, **options, &block|
          compressed_sizes << options[:compressed_size]
          original.call(name, **options, &block)
        end

        described_class.new.perform(archive.id)

        expect(archive.reload).to be_ready
        etag = s3_client.head_object(bucket: S3_BUCKET, key: file.s3_key).etag
        expect(reads).to eq([{ key: file.s3_key, if_match: etag }] * 2)
        expect(compressed_sizes.first).to be > 3.megabytes
        expect(zip_entries(archive)).to eq("Video.bin" => [Zlib.crc32(video), video])
      end

      it "fails without publishing when a source changes between its sizing read and its write" do
        file = add_file(installment, Random.new(9).bytes(1.megabyte), display_name: "Video")
        archive = archive_for(installment, [file])
        allow(StreamingZipWriter).to receive(:compressed_size_needed?).and_return(true)
        reads = 0
        allow_any_instance_of(Aws::S3::Client).to receive(:get_object).and_wrap_original do |original, params, &block|
          reads += 1 if block
          s3_client.put_object(bucket: S3_BUCKET, key: file.s3_key, body: "replaced bytes") if block && reads == 2
          original.call(params, &block)
        end

        expect { described_class.new.perform(archive.id) }.to raise_error(Aws::S3::Errors::PreconditionFailed)

        expect(reads).to eq(2)
        expect(archive.reload).to be_failed
        expect(aborted_upload_ids.size).to eq(1)
        expect(open_uploads(archive)).to be_empty
        expect(archive.s3_object.exists?).to be(false)
      end

      it "marks an archive with no downloadable files failed instead of storing an empty ZIP" do
        archive = archive_for(installment, [create(:external_link, link: nil, installment:)])

        described_class.new.perform(archive.id)

        expect(archive.reload).to be_failed
        expect(archive.s3_object.exists?).to be(false)
      end

      it "builds a non-bundle archive with more files than the bundle entry limit" do
        stub_const("#{described_class}::MAX_ARCHIVE_ENTRIES", 1)
        archive = archive_for(installment, [add_file(installment, "a", display_name: "A"), add_file(installment, "b", display_name: "B")])

        described_class.new.perform(archive.id)

        expect(archive.reload).to be_ready
        expect(zip_entries(archive).transform_values(&:last)).to eq("A.bin" => "a", "B.bin" => "b")
      end

      context "for a bundle purchase" do
        let(:bundle) { create(:product, :bundle) }

        def bundle_archive(sizes)
          files = bundle.bundle_products.map(&:product).zip(sizes).map do |product, bytes|
            add_file(product, bytes, display_name: "Part")
          end
          archive_for(bundle, files)
        end

        it "builds a ZIP whose recorded size is over the product archive limit" do
          archive = bundle_archive(["one", "two"])
          archive.product_files.each { _1.update_columns(size: described_class::PRODUCT_FILES_ARCHIVE_FILE_SIZE_LIMIT) }

          described_class.new.perform(archive.id)

          expect(archive.reload).to be_ready
          expect(zip_entries(archive).transform_values(&:last)).to eq("Bundle Product 1/Part.bin" => "one", "Bundle Product 2/Part.bin" => "two")
        end

        it "marks a bundle archive with more files than the entry limit too large" do
          stub_const("#{described_class}::MAX_ARCHIVE_ENTRIES", 1)
          archive = bundle_archive(["one", "two"])
          expect_any_instance_of(Aws::S3::Client).not_to receive(:head_object)

          described_class.new.perform(archive.id)

          expect(archive.reload).to be_too_large
        end

        it "enforces the bundle limit on the sizes S3 reports when none are recorded" do
          stub_const("#{described_class}::BUNDLE_ARCHIVE_FILE_SIZE_LIMIT", 1.megabyte)
          archive = bundle_archive([Random.new(5).bytes(700.kilobytes), Random.new(6).bytes(700.kilobytes)])
          archive.product_files.each { _1.update_columns(size: nil) }
          expect_any_instance_of(Aws::S3::Client).not_to receive(:get_object)

          described_class.new.perform(archive.id)

          expect(archive.reload).to be_too_large
          expect(archive.s3_object.exists?).to be(false)
        end
      end
    end

    context "when rich content provider is present" do
      before do
        @product = create(:product)
        @product_file1 = create(:readable_document, display_name: "जीवन में यश एवम् समृद्धी प्राप्त करने के कहीं न बताये जाने वाले १०० उपाय")
        @product_file2 = create(:readable_document, display_name: "कैसे जीवन का आनंद ले")
        @product_file3 = create(:readable_document, display_name: "File 3")
        @product_file4 = create(:readable_document, display_name: "आनंद और सुखी जीवन के लिए जाने कुछ रहस्य जो आपको नहीं पता होंगे और जिन्हें आपको जानना चाहिए")
        @product_file5 = create(:readable_document, display_name: "File 5")
        @product.product_files = [@product_file1, @product_file2, @product_file3, @product_file4, @product_file5]
        @product.save!
        @page1 = create(:rich_content, entity: @product, description: [
                          { "type" => "fileEmbed", "attrs" => { "id" => @product_file1.external_id, "uid" => "file-1" } },
                        ])
        @page2 = create(:rich_content, entity: @product, title: "Page 2", description: [
                          { "type" => "fileEmbedGroup", "attrs" => { "name" => "" }, "content" => [
                            { "type" => "fileEmbed", "attrs" => { "id" => @product_file2.external_id, "uid" => "0c042930-2df1-4583-82ef-a63172138683" } },
                          ] },
                          { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Some text" }] },
                          { "type" => "fileEmbedGroup", "attrs" => { "name" => "" }, "content" => [
                            { "type" => "fileEmbed", "attrs" => { "id" => @product_file3.external_id, "uid" => "0c042930-2df1-4583-82ef-a6317213868f" } },
                          ] },
                        ])
        @folder_id = SecureRandom.uuid
        @page3 = create(:rich_content, entity: @product, description: [
                          { "type" => "fileEmbedGroup", "attrs" => { "name" => "आनंदमय जीवन जिने के ५ सरल उपाय", "uid": @folder_id }, "content" => [
                            { "type" => "fileEmbed", "attrs" => { "id" => @product_file4.external_id, "uid" => "0c042930-2df1-4583-82ef-a6317213868w" } },
                            { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Lorem ipsum" }] },
                            { "type" => "fileEmbed", "attrs" => { "id" => @product_file5.external_id, "uid" => "0c042930-2df1-4583-82ef-a63172138681" } },
                          ] },
                        ])
        @product_files_archive = @product.product_files_archives.create!
        @product_files_archive.product_files = @product.product_files
        @product_files_archive.save!
        @product_files_archive.set_url_if_not_present
        @product_files_archive.save!

        @folder_archive = @product.product_files_archives.create!(folder_id: @folder_id)
        @folder_archive.product_files = [@product_file4, @product_file5]
        @folder_archive.save!
        @folder_archive.set_url_if_not_present
        @folder_archive.save!
      end

      it "creates a zip archive of embedded ungrouped files and grouped files while skipping external link and stream only files" do
        UpdateProductFilesArchiveWorker.new.perform(@product_files_archive.id)
        @product_files_archive.reload
        expect(@product_files_archive.url).to end_with("zip")

        temp_file = Tempfile.new
        @product_files_archive.s3_object.download_file(temp_file.path)
        temp_file.rewind

        entries = []
        Zip::File.open(temp_file.path) do |zipfile|
          zipfile.each do |entry|
            entries << entry.name.force_encoding("UTF-8")
          end
        end

        temp_file.close!

        expect(entries.count).to eq(5)
        expect(entries).to match_array([
                                         # Truncates long file name "जीवन में यश एवम् समृद्धी प्राप्त करने के कहीं न बताये जाने वाले १०० उपाय" enclosed in a folder named "Page 1" (title of the page)
                                         "Untitled 1/जीवन में यश एवम् समृद्धी प्राप्त करने .pdf",

                                         # Enclose the file in nested folders, "Page 2" (title of the page) and "Untitled 2" (name of the file group)
                                         "Page 2/Untitled 1/कैसे जीवन का आनंद ले.pdf",

                                         # Enclose the file in a folder named "Page 2" (title of the page)
                                         "Page 2/Untitled 2/File 3.pdf",

                                         # Truncates long file name "आनंद और सुखी जीवन के लिए जाने कुछ रहस्य जो आपको नहीं पता होंगे और जिन्हें आपको जानना चाहिए" enclosed in nested folders, "Untitled 2" (fallback title of the page) and "आनंदमय जीवन जिने के ५ सरल उपाय" (name of the file group, which gets truncated as well)
                                         "Untitled 2/आनंदमय जीवन जिने के ५ स/आनंद और सुखी जीवन के लिए जा.pdf",

                                         # Enclose the file in nested folders, "Untitled 2" (fallback title of the page) and "आनंदमय जीवन जिने के ५ सरल उपाय" (name of the file group)
                                         "Untitled 2/आनंदमय जीवन जिने के ५ सरल उपाय/File 5.pdf"
                                       ])
      end

      it "creates a zip archive of folder files" do
        UpdateProductFilesArchiveWorker.new.perform(@folder_archive.id)
        @folder_archive.reload
        expect(@folder_archive.url).to end_with("zip")
        expect(@folder_archive.url).to include("आनंदमय_जीवन_जिने_के_५_सरल_उपाय")

        temp_file = Tempfile.new
        @folder_archive.s3_object.download_file(temp_file.path)
        temp_file.rewind

        entries = []
        Zip::File.open(temp_file.path) do |zipfile|
          zipfile.each do |entry|
            entries << entry.name.force_encoding("UTF-8")
          end
        end

        temp_file.close!

        expect(entries.count).to eq(2)
        expect(entries).to match_array(
          [
            "आनंद और सुखी जीवन के लिए जाने कुछ रहस्य जो आपको नहीं पता .pdf",
            "File 5.pdf"
          ])
      end
    end
  end
end
