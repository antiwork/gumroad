# frozen_string_literal: true

require "test_helper"

class ExpiringS3FileServiceTest < ActiveSupport::TestCase
  self.described_class = ExpiringS3FileService



  context_ ExpiringS3FileService do
  context_ "#perform" do
      before do
        @file = fixture_file_upload("test.png")
        stub_const("S3_BUCKET", "gumroad-specs")
      end

  test "generates URL with given data and default values" do
        result = ExpiringS3FileService.new(file: @file, extension: "pdf").perform
        expect(result).to match(/#{AWS_S3_ENDPOINT}\/gumroad-specs\/File/o)
        expect(result).to match(/pdf/)
        expect(result).to match(Regexp.new "#{ExpiringS3FileService::DEFAULT_FILE_EXPIRY.to_i}")
      end

  test "generates URL with given filename" do
        result = ExpiringS3FileService.new(file: @file, filename: "test.pdf").perform
        expect(result).to match(/#{AWS_S3_ENDPOINT}\/gumroad-specs\/test.pdf/o)
      end

  test "generates URL with given path, prefix, extension, expiry" do
        result = ExpiringS3FileService.new(file: @file,
                                           prefix: "prefix",
                                           extension: "txt",
                                           path: "folder",
                                           expiry: 1.hour).perform
        expect(result).to match(
          /#{AWS_S3_ENDPOINT}\/gumroad-specs\/folder\/prefix_.*txt.*3600/o
                          )
      end

  test "generates presigned URL with the 'response-content-disposition' query parameter set to 'attachment'" do
        presigned_url = ExpiringS3FileService.new(file: @file, filename: "sales.csv").perform

        expect(presigned_url).to match(/response-content-disposition=attachment/)
      end

  context_ "when specified without the filename and without the extension" do
  test "raises an error" do
          expect { ExpiringS3FileService.new(file: @file).perform }
            .to raise_error(ArgumentError, "Either filename or extension is required")
        end
      end

  context_ "when specified without the file object" do
  test "raises an error" do
          expect { ExpiringS3FileService.new.perform }
            .to raise_error(ArgumentError, "missing keyword: :file")
        end
      end

  context_ "when specified with the extension but no filename" do
  test "uploads file with the content type inferred from the file's extension" do
          allow_any_instance_of(Aws::S3::Object)
            .to receive(:upload_file).with(@file, content_type: "text/csv")

          ExpiringS3FileService.new(file: @file, extension: "csv").perform
        end
      end

  context_ "when specified with the filename but no extension" do
  test "uploads file with the content type inferred from the file's name" do
          allow_any_instance_of(Aws::S3::Object)
            .to receive(:upload_file).with(@file, content_type: "application/pdf")

          ExpiringS3FileService.new(file: @file, filename: "sales.pdf").perform
        end
      end

  context_ "when specified with the both filename and extension" do
  test "uploads file with the content type inferred from the file's name" do
          allow_any_instance_of(Aws::S3::Object)
            .to receive(:upload_file).with(@file, content_type: "application/pdf")

          ExpiringS3FileService.new(file: @file, filename: "sales.pdf", extension: "csv").perform
        end
      end
    end
  end
end
