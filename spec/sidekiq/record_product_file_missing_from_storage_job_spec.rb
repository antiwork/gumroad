# frozen_string_literal: true

describe RecordProductFileMissingFromStorageJob do
  # A row old enough that its upload cannot still be in flight.
  def old_unanalyzed_file(created_at: 3.days.ago, **attrs)
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
    # before it arrives.
    it "does not touch a row whose upload could still be in flight" do
      file = old_unanalyzed_file(created_at: 1.hour.ago)
      expect_any_instance_of(ProductFile).not_to receive(:s3_object)

      described_class.new.perform(file.id)

      expect(file.reload.deleted_from_cdn?).to eq(false)
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
