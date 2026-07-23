# frozen_string_literal: true

require "spec_helper"

describe S3KeyUnicodeNormalization do
  # "música.pdf" with the "ú" as a single precomposed character (NFC form)
  let(:nfc_key) { "attachments/#{SecureRandom.hex}/original/m\u00FAsica.pdf" }
  # The same key with the "ú" decomposed into "u" + combining acute accent (NFD form)
  let(:nfd_key) { nfc_key.unicode_normalize(:nfd) }

  describe ".variants" do
    it "returns the other normalization forms of a key with accented characters" do
      expect(described_class.variants(nfc_key)).to eq([nfd_key])
      expect(described_class.variants(nfd_key)).to eq([nfc_key])
    end

    it "returns an empty array for plain-ASCII keys" do
      expect(described_class.variants("attachments/abc123/original/plain.pdf")).to eq([])
    end

    it "returns an empty array for keys that cannot be normalized" do
      invalid = "attachments/\xC3(".dup.force_encoding(Encoding::UTF_8)
      expect(described_class.variants(invalid)).to eq([])
    end
  end

  describe ".existing_variant" do
    it "returns the normalization form under which the object actually exists" do
      Aws::S3::Resource.new.bucket(S3_BUCKET).object(nfd_key).upload_file(
        File.new("spec/support/fixtures/test.pdf"),
        content_type: "application/pdf"
      )

      expect(described_class.existing_variant(nfc_key)).to eq(nfd_key)
    end

    it "returns nil when no variant exists in the bucket" do
      expect(described_class.existing_variant(nfc_key)).to be_nil
    end

    it "returns nil without calling S3 for plain-ASCII keys" do
      expect(Aws::S3::Resource).not_to receive(:new)
      expect(described_class.existing_variant("attachments/abc123/original/plain.pdf")).to be_nil
    end
  end
end
