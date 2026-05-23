# frozen_string_literal: true

require "test_helper"

class SignedUrlHelperTest < ActionView::TestCase
  self.described_class = SignedUrlHelper
  tests SignedUrlHelper



  context_ SignedUrlHelper do
    let(:pdf_path) { "attachments/23b2d41ac63a40b5afa1a99bf38a0982/original/nyt.pdf" }
    let(:pdf_uri) { URI.parse("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{pdf_path}").to_s }
    let(:s3_object_double) { double(:s3_object) }
    let!(:file) { create(:product_file, url: pdf_uri.to_s) }

    before do
      s3_double = double(:s3_client)
      s3_res_double = double(:s3_resource)
      response_double = double(:response)
      bucket_double = double(:bucket)

      allow(Aws::S3::Client).to receive(:new).times.and_return(s3_double)
      allow(s3_double).to receive(:list_objects).times.and_return([response_double])
      allow(response_double).to receive_message_chain(:contents, :map).and_return([pdf_path])
      allow(Aws::S3::Resource).to receive(:new).times.and_return(s3_res_double)
      allow(s3_res_double).to receive(:bucket).times.and_return(bucket_double)
      allow(bucket_double).to receive(:object).times.and_return(s3_object_double)
      allow(s3_object_double).to receive(:public_url).times.and_return(pdf_uri)
    end

  context_ "when using minio" do
  test "returns a minio presigned url" do
        presigned_url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{pdf_path}?X-Amz-Signature=test"
        allow(s3_object_double).to receive(:content_length).and_return(1000)
        expect(s3_object_double).to receive(:presigned_url).with(
          :get,
          expires_in: 10.minutes.to_i,
          response_content_disposition: "attachment; filename=\"#{file.s3_filename}\""
        ).and_return(presigned_url)
        expect(signed_download_url_for_s3_key_and_filename(file.s3_key, file.s3_filename)).to eq(presigned_url)
      end
    end

  context_ "when not using minio" do
      before do
        stub_const("USING_MINIO", false)
        stub_const("CLOUDFRONT_DOWNLOAD_DISTRIBUTION_URL", "https://cloudfront.net")
        stub_const("FILE_DOWNLOAD_DISTRIBUTION_URL", "https://staging-files.gumroad.com")
      end

  test "returns the correct validation duration" do
        expect(signed_url_validity_time_for_file_size(10)).to eq SignedUrlHelper::SIGNED_S3_URL_VALID_FOR_MINIMUM
        expect(signed_url_validity_time_for_file_size(1_000_000_000)).to eq SignedUrlHelper::SIGNED_S3_URL_VALID_FOR_MAXIMUM
        expect(signed_url_validity_time_for_file_size(200_000_000)).to eq((200_000_000 / 1_024 / 50).seconds)
      end

  test "returns a CloudFront read url with the proper cache_group paramter if file size >= 8GB" do
        allow(s3_object_double).to receive(:content_length).and_return(8_000_000_000)

        expect(signed_download_url_for_s3_key_and_filename(file.s3_key, file.s3_filename, cache_group: "read"))
          .to match(/cloudfront\.net.*cache_group=read/)
      end

  test "returns a Cloudflare read url with the proper cache_group paramter if file size < 8GB" do
        allow(s3_object_double).to receive(:content_length).and_return(1_000_000_000)

        expect(signed_download_url_for_s3_key_and_filename(file.s3_key, file.s3_filename, cache_group: "read"))
          .to match(/staging-files\.gumroad\.com.*cache_group=read.*verify=/)
      end

  test "contains the cache_key parameter in the query string for files with specific extensions" do
        allow(s3_object_double).to receive(:content_length).and_return(1_000_000_000)

        expect(signed_download_url_for_s3_key_and_filename(file.s3_key, file.s3_filename))
          .not_to include("cache_key=caIWHGT4Qhqo6KoxDMNXwQ")

        %w(jpg jpeg png epub brushset scrivtemplate zip).each do |extension|
          file_path = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/23b2d41ac63a40b5afa1a99bf38a0982/original/nyt.#{extension}"
          file = create(:product_file, url: URI.parse(file_path).to_s)

          expect(signed_download_url_for_s3_key_and_filename(file.s3_key, file.s3_filename))
              .to match(/staging-files\.gumroad\.com.*cache_key=caIWHGT4Qhqo6KoxDMNXwQ.*/)
        end
      end

  test "raises a descriptive exception if the S3 object doesn't exist" do
        expect do
          signed_download_url_for_s3_key_and_filename("attachments/missing.txt", "filename")
        end.to raise_error(Aws::S3::Errors::NotFound, /Key = attachments\/missing.txt/)
      end

  context_ "#file_needs_cache_key?" do
  context_ "when cache key is needed" do
  test "returns true" do
            expect(file_needs_cache_key?("file.jpg")).to be_truthy
          end
        end

  context_ "when cache key is not needed" do
  test "returns false" do
            expect(file_needs_cache_key?("file.mp3")).to be_falsey
          end
        end
      end

  context_ "#cf_worker_cache_extensions_and_keys" do
  test "returns a hash with extensions and cache keys" do
          expect(cf_worker_cache_extensions_and_keys).to be_a(Hash)
          expect(cf_worker_cache_extensions_and_keys[".jpg"]).to eq "caIWHGT4Qhqo6KoxDMNXwQ"
        end
      end

  context_ "#cf_cache_key" do
  context_ "when cache key is configured for the extension" do
  test "returns the cache key" do
            expect(cf_cache_key("filename.zip")).to eq "caIWHGT4Qhqo6KoxDMNXwQ"
          end
        end

  context_ "when cache key is not configured for the extension" do
  test "returns nil" do
            expect(cf_cache_key("filename.mp3")).to be_nil
          end
        end

  context_ "set keys from Redis" do
          before do
            Rails.cache.clear
          end

  test "Overrides cache key with the key from Redis" do
            expect(cf_worker_cache_extensions_and_keys[".jpg"]).to eq "caIWHGT4Qhqo6KoxDMNXwQ"

            $redis.hset(RedisKey.cf_cache_invalidated_extensions_and_cache_keys, ".jpg", Digest::SHA1.hexdigest("2020-10-09"))
            Rails.cache.delete("set_cf_worker_cache_keys_from_redis")

            expect(cf_worker_cache_extensions_and_keys[".jpg"]).to eq Digest::SHA1.hexdigest("2020-10-09")
          end

  test "uses Rails.cache to read the value from Redis only once as long as the Rails cache is present" do
            expect(cf_worker_cache_extensions_and_keys[".mp3"]).to be_nil

            $redis.hset(RedisKey.cf_cache_invalidated_extensions_and_cache_keys, ".mp4", Digest::SHA1.hexdigest("2020-10-09"))

            expect(cf_worker_cache_extensions_and_keys[".mp3"]).to be_nil
          end
        end
      end
    end
  end
end
