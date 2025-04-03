# frozen_string_literal: true

require "spec_helper"

describe PublicFile do
  describe "associations" do
    it { is_expected.to belong_to(:seller).class_name("User").optional }
    it { is_expected.to belong_to(:resource).optional(false) }
    it { is_expected.to have_one_attached(:file) }
  end

  describe "validations" do
    describe "public_id" do
      subject(:public_file) { build(:public_file, public_id: "existingvalue001") }
      it { is_expected.to validate_uniqueness_of(:public_id).case_insensitive }
      it { is_expected.to allow_value("existingvalue002").for(:public_id) }
      it { is_expected.not_to allow_value("existingvaluelong").for(:public_id) }
      it { is_expected.not_to allow_value("existingvalue00$").for(:public_id) }
    end
    it { is_expected.to validate_presence_of(:original_file_name) }
    it { is_expected.to validate_presence_of(:display_name) }
  end

  describe "callbacks" do
    describe "#set_original_file_name" do
      it "sets original_file_name from file if not present" do
        public_file = build(:public_file, :with_audio, original_file_name: nil)
        public_file.valid?
        expect(public_file.original_file_name).to eq("test.mp3")
      end

      it "keeps existing original_file_name if present" do
        public_file = build(:public_file, :with_audio, original_file_name: "custom.mp3")
        public_file.valid?
        expect(public_file.original_file_name).to eq("custom.mp3")
      end

      it "does not set original_file_name if file is not attached" do
        public_file = build(:public_file, original_file_name: nil)
        public_file.valid?
        expect(public_file.original_file_name).to be_nil
      end
    end

    describe "#set_default_display_name" do
      it "sets display_name from original_file_name if not present" do
        public_file = build(:public_file, :with_audio, display_name: nil, original_file_name: "test.mp3")
        public_file.valid?
        expect(public_file.display_name).to eq("test")
      end

      it "sets display_name to Untitled if original_file_name is a dotfile" do
        public_file = build(:public_file, :with_audio, display_name: nil, original_file_name: ".DS_Store")
        public_file.valid?
        expect(public_file.display_name).to eq("Untitled")
      end

      it "keeps existing display_name if present" do
        public_file = build(:public_file, :with_audio, display_name: "My Audio")
        public_file.valid?
        expect(public_file.display_name).to eq("My Audio")
      end

      it "does not set display_name if file is not attached" do
        public_file = build(:public_file, display_name: nil, original_file_name: nil)
        public_file.valid?
        expect(public_file.display_name).to be_nil
      end
    end

    describe "#set_file_group_and_file_type" do
      it "sets file_type and file_group based on original_file_name" do
        public_file = build(:public_file, :with_audio)
        public_file.valid?
        expect(public_file.file_type).to eq("mp3")
        expect(public_file.file_group).to eq("audio")
      end

      it "does not set file_type and file_group if original_file_name is nil" do
        public_file = build(:public_file, original_file_name: nil)
        public_file.valid?
        expect(public_file.file_type).to be_nil
        expect(public_file.file_group).to be_nil
      end
    end

    describe "#set_public_id" do
      it "generates a public_id if not present" do
        allow(described_class).to receive(:generate_public_id).and_return("helloworld123456")
        public_file = build(:public_file, :with_audio, public_id: nil)
        public_file.valid?
        expect(public_file.public_id).to eq("helloworld123456")
      end

      it "keeps existing public_id if present" do
        public_file = build(:public_file, :with_audio, public_id: "helloworld123456")
        public_file.valid?
        expect(public_file.public_id).to eq("helloworld123456")
      end
    end
  end

  describe ".generate_public_id" do
    it "generates a unique 16-character long alphanumeric public_id" do
      public_id = described_class.generate_public_id
      expect(public_id).to match(/^[a-z0-9]{16}$/)
    end

    it "generates unique public_ids" do
      existing_public_id = described_class.generate_public_id
      create(:public_file, public_id: existing_public_id)

      new_public_id = described_class.generate_public_id
      expect(new_public_id).not_to eq(existing_public_id)
    end

    it "retries until finding a unique public_id" do
      allow(SecureRandom).to receive(:alphanumeric).and_return("helloworld123456", "helloworld123457")
      create(:public_file, public_id: "helloworld123456")

      expect(described_class.generate_public_id).to eq("helloworld123457")
    end

    it "raises error after max retries" do
      allow(SecureRandom).to receive(:alphanumeric).and_return("helloworld123456", "helloworld123457")
      create(:public_file, public_id: "helloworld123456")

      expect { described_class.generate_public_id(max_retries: 1) }
        .to raise_error("Failed to generate unique public_id after 1 attempts")
    end
  end

  describe "#analyzed?" do
    it "returns true if blob is analyzed" do
      public_file = create(:public_file, :with_audio)
      public_file.file.analyze
      expect(public_file).to be_analyzed
    end

    it "returns false if blob is not analyzed" do
      public_file = create(:public_file, :with_audio)
      allow(public_file.blob).to receive(:analyzed?).and_return(false)
      expect(public_file).not_to be_analyzed
    end

    it "returns false if blob is nil" do
      public_file = build(:public_file)
      expect(public_file).not_to be_analyzed
    end
  end

  describe "#file_size" do
    it "returns blob byte_size" do
      public_file = create(:public_file, :with_audio)
      public_file.file.analyze
      expect(public_file.file_size).to be > (30_000)
    end

    it "returns nil if blob is nil" do
      public_file = build(:public_file)
      allow(public_file).to receive(:blob).and_return(nil)
      expect(public_file.file_size).to be_nil
    end
  end

  describe "#metadata" do
    it "returns blob metadata" do
      public_file = create(:public_file, :with_audio)
      public_file.file.analyze
      expect(public_file.metadata["identified"]).to be(true)
      expect(public_file.metadata["duration"]).to be > 5
      expect(public_file.metadata["sample_rate"]).to be > 44_000
      expect(public_file.metadata["analyzed"]).to be(true)
    end

    it "returns empty hash if blob is nil" do
      public_file = build(:public_file)
      expect(public_file.metadata).to eq({})
    end
  end

  describe "#scheduled_for_deletion?" do
    it "returns true if scheduled_for_deletion_at is present" do
      public_file = build(:public_file, scheduled_for_deletion_at: Time.current)
      expect(public_file).to be_scheduled_for_deletion
    end

    it "returns false if scheduled_for_deletion_at is nil" do
      public_file = build(:public_file, scheduled_for_deletion_at: nil)
      expect(public_file).not_to be_scheduled_for_deletion
    end
  end

  describe "#schedule_for_deletion!" do
    it "sets scheduled_for_deletion_at to 10 days from now" do
      public_file = create(:public_file)
      public_file.schedule_for_deletion!
      expect(public_file.scheduled_for_deletion_at).to be_within(5.second).of(10.days.from_now)
    end
  end
end
