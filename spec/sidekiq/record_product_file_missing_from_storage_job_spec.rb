# frozen_string_literal: true

describe RecordProductFileMissingFromStorageJob do
  # A row old enough that its upload cannot still be in flight.
  def old_unanalyzed_file(created_at: described_class::UPLOAD_GRACE_PERIOD.ago - 1.day, **attrs)
    create(:product_file, analyze_completed: false, **attrs).tap do
      _1.update_column(:created_at, created_at)
    end
  end

  def stub_storage(file, exists:)
    allow_any_instance_of(ProductFile).to receive(:s3_object) do |instance|
      raise "unexpected storage lookup for #{instance.id}" unless instance.id == file.id

      double("s3_object", exists?: exists)
    end
  end

  before do
    # Plain-ASCII keys have no alternative normalization forms, so this is what
    # the real module returns for them; the Unicode case is covered explicitly.
    allow(S3KeyUnicodeNormalization).to receive(:existing_variant).and_return(nil)
  end

  describe "#perform" do
    it "records that there is nothing in storage behind a row whose upload never finished" do
      file = old_unanalyzed_file
      stub_storage(file, exists: false)

      described_class.new.perform(file.id)

      expect(file.reload.deleted_from_cdn?).to eq(true)
      # The row is left alive on purpose: the seller's file list is theirs, and a
      # dead row is not something to remove from their product without telling
      # them.
      expect(file.alive?).to eq(true)
    end

    # The lookup that enqueued this job happened during a save. By the time the
    # job runs the upload may have completed, so the absence is proved again here
    # rather than trusted.
    it "leaves the row alone when the object turns out to be in storage after all" do
      file = old_unanalyzed_file
      stub_storage(file, exists: true)

      described_class.new.perform(file.id)

      expect(file.reload.deleted_from_cdn?).to eq(false)
    end

    # A large file uploading over a slow connection is the case that must not be
    # retired: marking it would tell every later caller the file is missing right
    # before it arrives, and nothing would ever undo that.
    it "does not touch a row whose upload could still be in flight" do
      file = old_unanalyzed_file(created_at: 1.hour.ago)
      expect_any_instance_of(ProductFile).not_to receive(:s3_object)

      described_class.new.perform(file.id)

      expect(file.reload.deleted_from_cdn?).to eq(false)
    end

    # The grace period itself, pinned at a fixed age rather than derived from the
    # constant: a two-day-old row is past the one day the first version of this
    # job allowed, and still inside the three days a multi-gigabyte upload on a
    # slow link can need. Shortening the constant back would retire this row.
    it "does not touch a row that is two days old" do
      file = old_unanalyzed_file(created_at: 2.days.ago)
      expect_any_instance_of(ProductFile).not_to receive(:s3_object)

      described_class.new.perform(file.id)

      expect(file.reload.deleted_from_cdn?).to eq(false)
    end

    # The same accented filename can be stored under a different Unicode
    # normalization form than the key we persisted, so `exists?` says missing for
    # a file buyers can still download (the download path probes the variants).
    # Recording that row as empty would be wrong forever.
    it "leaves the row alone when the object exists under another Unicode form of the key" do
      file = old_unanalyzed_file
      stub_storage(file, exists: false)
      allow(S3KeyUnicodeNormalization).to receive(:existing_variant).with(file.s3_key).and_return("#{file.s3_key}-nfd")

      described_class.new.perform(file.id)

      expect(file.reload.deleted_from_cdn?).to eq(false)
    end

    # A storage fault while probing the variants means we could not tell whether
    # the object is there. The marker is permanent, so an unknown answer must not
    # produce one — the row is left alone and stays eligible for a later attempt.
    it "leaves the row alone when the variant check cannot reach storage" do
      file = old_unanalyzed_file
      stub_storage(file, exists: false)
      allow(S3KeyUnicodeNormalization).to receive(:existing_variant)
        .and_raise(Seahorse::Client::NetworkingError.new(SocketError.new("getaddrinfo failed")))

      described_class.new.perform(file.id)

      expect(file.reload.deleted_from_cdn?).to eq(false)
    end

    # The variant guard must not cost an extra storage request for the ordinary
    # case. A plain-ASCII key has no alternative normalization forms, so the real
    # module answers without asking storage at all — pinned here without the stub
    # the other examples use.
    it "asks storage nothing extra for a plain-ASCII key" do
      file = old_unanalyzed_file
      stub_storage(file, exists: false)
      allow(S3KeyUnicodeNormalization).to receive(:existing_variant).and_call_original
      expect(file.s3_key).to match(/\A[[:ascii:]]+\z/)
      expect(Aws::S3::Resource).not_to receive(:new)

      described_class.new.perform(file.id)

      expect(file.reload.deleted_from_cdn?).to eq(true)
    end

    it "does not touch a row whose analysis has since succeeded" do
      file = old_unanalyzed_file
      file.update!(analyze_completed: true)
      expect_any_instance_of(ProductFile).not_to receive(:s3_object)

      described_class.new.perform(file.id)

      expect(file.reload.deleted_from_cdn?).to eq(false)
    end

    it "does nothing when the row has been deleted since the lookup" do
      file = old_unanalyzed_file
      file.mark_deleted!
      expect_any_instance_of(ProductFile).not_to receive(:s3_object)

      expect { described_class.new.perform(file.id) }.not_to raise_error
    end

    it "does nothing when the row no longer exists" do
      expect { described_class.new.perform(-1) }.not_to raise_error
    end

    it "does not ask storage again for a row that is already marked" do
      file = old_unanalyzed_file(deleted_from_cdn_at: Time.current)
      expect_any_instance_of(ProductFile).not_to receive(:s3_object)

      described_class.new.perform(file.id)
    end

    # An external link has no storage object to look for; the URL is the
    # deliverable.
    it "does not touch an external link" do
      file = create(:external_link, analyze_completed: false)
      file.update_column(:created_at, 3.days.ago)
      expect_any_instance_of(ProductFile).not_to receive(:s3_object)

      described_class.new.perform(file.id)

      expect(file.reload.deleted_from_cdn?).to eq(false)
    end
  end
end
