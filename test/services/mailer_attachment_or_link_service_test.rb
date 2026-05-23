# frozen_string_literal: true

require "test_helper"

class MailerAttachmentOrLinkServiceTest < ActiveSupport::TestCase
  self.described_class = MailerAttachmentOrLinkService



  context_ MailerAttachmentOrLinkService do
  context_ "#perform" do
      before do
        @file = fixture_file_upload("test.png")
      end

  test "generates URL with given file when size is greater than 10 MB" do
        allow(@file).to receive(:size).and_return(MailerAttachmentOrLinkService::MAX_FILE_SIZE + 1)
        result = MailerAttachmentOrLinkService.new(file: @file, extension: "csv").perform
        expect(result[:file]).to be_nil
        expect(result[:url]).to match(/#{AWS_S3_ENDPOINT}\/gumroad-specs/o)
        expect(result[:url]).to match(Regexp.new "#{ExpiringS3FileService::DEFAULT_FILE_EXPIRY.to_i}")
      end

  test "returns original file if file size is less than 10 MB" do
        allow(@file).to receive(:size).and_return(MailerAttachmentOrLinkService::MAX_FILE_SIZE - 1)
        result = MailerAttachmentOrLinkService.new(file: @file, extension: "csv").perform
        expect(result[:file]).to eq(@file)
        expect(result[:url]).to be_nil
      end
    end
  end
end
