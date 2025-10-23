# frozen_string_literal: true

require "spec_helper"

describe "S3Retrievable" do
  let!(:model) do
    model = create_mock_model do |t|
      t.string :url
    end
    model.attr_accessor :user
    model.include S3Retrievable
    model.has_s3_fields :url
    model
  end

  subject(:s3_retrievable_object) do
    model.new.tap do |test_class|
      test_class.url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/nyt.pdf"
    end
  end

  shared_examples "s3 retrievable instance method" do |method_name|
    context "when the s3 attribute value is empty" do
      before { s3_retrievable_object.url = nil }

      it "returns nil" do
        expect(s3_retrievable_object.public_send(method_name)).to be nil
      end
    end
  end

  describe "#unique_url_identifier" do
    it "returns url as an identifier" do
      expect(s3_retrievable_object.unique_url_identifier).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/nyt.pdf")
    end

    context "when it has an s3 guid" do
      before do
        s3_retrievable_object.url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/23b2d41ac63a40b5afa1a99bf38a0982/original/nyt.pdf"
      end

      it "returns s3 guid" do
        expect(s3_retrievable_object.unique_url_identifier).to eq("23b2d41ac63a40b5afa1a99bf38a0982")
      end
    end
  end

  describe "#download_original" do
    it "downloads file from s3 into a tempfile" do
      s3_object_double = double
      expect(s3_object_double).to receive(:download_file)
      expect(s3_retrievable_object).to receive(:s3_object).and_return(s3_object_double)
      yielded = false
      s3_retrievable_object.download_original do |original_file|
        yielded = true
        expect(original_file).to be_kind_of(Tempfile)
        expect(File.extname(original_file)).to eq(".pdf")
      end
      expect(yielded).to eq(true)
    end

    it "requires a block" do
      expect { s3_retrievable_object.download_original }.to raise_error(ArgumentError, /requires a block/)
    end

    it "raises a descriptive exception if the S3 object doesn't exist" do
      record = model.create!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/missing.txt")

      expect do
        record.download_original { }
      end.to raise_error(Aws::S3::Errors::NotFound, /Key = attachments\/missing.txt .* #{model.name}.id = #{record.id}/)
    end
  end

  describe "#s3_filename" do
    it "returns filename" do
      expect(s3_retrievable_object.s3_filename).to eq("nyt.pdf")
    end

    include_examples "s3 retrievable instance method", "s3_filename"
  end

  describe "#s3_url" do
    it "returns s3 url value" do
      expect(s3_retrievable_object.s3_url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/nyt.pdf")
    end

    include_examples "s3 retrievable instance method", "s3_url"
  end

  describe "#s3_extension" do
    it "returns file extension" do
      expect(s3_retrievable_object.s3_extension).to eq(".pdf")
    end

    include_examples "s3 retrievable instance method", "s3_extension"
  end

  describe "#s3_display_extension" do
    it "returns formatted file extension" do
      expect(s3_retrievable_object.s3_display_extension).to eq("PDF")
    end

    include_examples "s3 retrievable instance method", "s3_display_extension"
  end

  describe "#s3_display_name" do
    it "returns file name without extension" do
      expect(s3_retrievable_object.s3_display_name).to eq("nyt")
    end

    include_examples "s3 retrievable instance method", "s3_display_name"
  end

  describe "#s3_directory_uri" do
    before do
      s3_retrievable_object.url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/23b2d41ac63a40b5afa1a99bf38a0982/original/nyt.pdf"
    end

    it "returns file directory" do
      expect(s3_retrievable_object.s3_directory_uri).to eq("attachments/23b2d41ac63a40b5afa1a99bf38a0982/original")
    end

    include_examples "s3 retrievable instance method", "s3_directory_uri"
  end

  describe "#restore_deleted_s3_object!" do
    context "when the versioned object exists" do
      let!(:record) { model.create!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{SecureRandom.hex}") }

      before do
        Aws::S3::Resource.new.bucket(S3_BUCKET).object(record.s3_key).upload_file(
          File.new(Rails.root.join("spec/support/fixtures/test.pdf")),
          content_type: "application/pdf"
        )
        expect(record.s3_object.exists?).to eq(true)
      end

      it "returns nil if S3 object is available" do
        expect(record.restore_deleted_s3_object!).to eq(nil)
      end

      it "returns true if S3 object was restored" do
        bucket = Aws::S3::Resource.new(
          region: AWS_DEFAULT_REGION,
          credentials: Aws::Credentials.new(GlobalConfig.get("S3_DELETER_ACCESS_KEY_ID"), GlobalConfig.get("S3_DELETER_SECRET_ACCESS_KEY"))
        ).bucket(S3_BUCKET)

        bucket.object(record.s3_key).delete
        expect(record.s3_object.exists?).to eq(false)

        expect(record.restore_deleted_s3_object!).to eq(true)
        expect(record.s3_object.exists?).to eq(true)
      end
    end

    context "when the versioned object is missing" do
      let!(:record) { model.create!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{SecureRandom.hex}") }

      it "retuns false" do
        expect(record.restore_deleted_s3_object!).to eq(false)
      end
    end
  end

  describe "#confirm_s3_key!" do
    it "updates the url if possible" do
      s3_directory = "#{SecureRandom.hex}/#{SecureRandom.hex}/original"

      Aws::S3::Resource.new.bucket(S3_BUCKET).object("#{s3_directory}/file.pdf").upload_file(
        File.new("spec/support/fixtures/test.pdf"),
        content_type: "application/pdf"
      )

      record = model.create!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{s3_directory}/incorrect-file-name.pdf")

      record.confirm_s3_key!
      expect(record.s3_key).to eq(s3_directory + "/file.pdf")
    end

    it "does nothing if the file exists on S3" do
      previous_url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/sample.mov"
      record = model.create!(url: previous_url)

      record.confirm_s3_key!
      expect(record.s3_key).to eq("specs/sample.mov")
    end
  end

  describe ".s3" do
    it "only includes s3 files" do
      s3_retrievable_object.save!
      model.create!(url: "https://example.com")

      expect(model.s3).to match_array(s3_retrievable_object)
    end
  end

  describe ".with_s3_key" do
    it "only includes s3 files matching the s3 key" do
      foo = model.create!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/foo.pdf")
      foo2 = model.create!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/foo.pdf")
      other = model.create!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/other.pdf")
      model.create!(url: "https://example.com")

      expect(model.with_s3_key("attachments/foo.pdf")).to match_array([foo, foo2])
      expect(model.with_s3_key("attachments/other.pdf")).to match_array([other])
    end
  end
end
