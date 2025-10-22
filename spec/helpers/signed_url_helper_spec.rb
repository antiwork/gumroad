# frozen_string_literal: true

require "spec_helper"

describe SignedUrlHelper do
  before do
    pdf_path = "attachments/23b2d41ac63a40b5afa1a99bf38a0982/original/nyt.pdf"
    pdf_uri = URI.parse("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{pdf_path}").to_s

    @file = create(:product_file, url: pdf_uri.to_s)
    s3_double = double
    s3_res_double = double
    response_double = double
    bucket_double = double
    @s3_object_double = double

    allow(Aws::S3::Client).to receive(:new).times.and_return(s3_double)
    allow(s3_double).to receive(:list_objects).times.and_return([response_double])
    allow(response_double).to receive_message_chain(:contents, :map).and_return([pdf_path])
    allow(Aws::S3::Resource).to receive(:new).times.and_return(s3_res_double)
    allow(s3_res_double).to receive(:bucket).times.and_return(bucket_double)
    allow(bucket_double).to receive(:object).times.and_return(@s3_object_double)
    allow(@s3_object_double).to receive(:public_url).times.and_return(pdf_uri)
  end

  it "returns the correct validation duration" do
    expect(signed_url_validity_time_for_file_size(10)).to eq SignedUrlHelper::SIGNED_S3_URL_VALID_FOR_MINIMUM
    expect(signed_url_validity_time_for_file_size(1_000_000_000)).to eq SignedUrlHelper::SIGNED_S3_URL_VALID_FOR_MAXIMUM
    expect(signed_url_validity_time_for_file_size(200_000_000)).to eq((200_000_000 / 1_024 / 50).seconds)
  end

  it "returns a CloudFront read url with the proper cache_group paramter if file size >= 8GB" do
    allow(@s3_object_double).to receive(:content_length).and_return(8_000_000_000)

    expect(signed_download_url_for_s3_key_and_filename(@file.s3_key, @file.s3_filename, cache_group: "read"))
      .to match(/cloudfront\.net.*cache_group=read/)
  end

  it "returns a Cloudflare read url with the proper cache_group paramter if file size < 8GB" do
    allow(@s3_object_double).to receive(:content_length).and_return(1_000_000_000)

    expect(signed_download_url_for_s3_key_and_filename(@file.s3_key, @file.s3_filename, cache_group: "read"))
      .to match(/staging-files\.gumroad\.com.*cache_group=read.*verify=/)
  end

  it "contains the cache_key parameter in the query string for files with specific extensions" do
    allow(@s3_object_double).to receive(:content_length).and_return(1_000_000_000)

    expect(signed_download_url_for_s3_key_and_filename(@file.s3_key, @file.s3_filename))
      .to_not include("cache_key=caIWHGT4Qhqo6KoxDMNXwQ")

    %w(jpg jpeg png epub brushset scrivtemplate zip).each do |extension|
      file_path = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/23b2d41ac63a40b5afa1a99bf38a0982/original/nyt.#{extension}"
      file = create(:product_file, url: URI.parse(file_path).to_s)

      expect(signed_download_url_for_s3_key_and_filename(file.s3_key, file.s3_filename))
          .to match(/staging-files\.gumroad\.com.*cache_key=caIWHGT4Qhqo6KoxDMNXwQ.*/)
    end
  end

  it "raises a descriptive exception if the S3 object doesn't exist" do
    RSpec::Mocks.space.proxy_for(Aws::S3::Client).reset
    RSpec::Mocks.space.proxy_for(Aws::S3::Resource).reset

    expect do
      signed_download_url_for_s3_key_and_filename("attachments/missing.txt", "filename")
    end.to raise_error(Aws::S3::Errors::NotFound, /Key = attachments\/missing.txt/)
  end

  describe "#file_needs_cache_key?" do
    context "when cache key is needed" do
      it "returns true" do
        expect(file_needs_cache_key?("file.jpg")).to be_truthy
      end
    end

    context "when cache key is not needed" do
      it "returns false" do
        expect(file_needs_cache_key?("file.mp3")).to be_falsey
      end
    end
  end

  describe "#cf_worker_cache_extensions_and_keys" do
    it "returns a hash with extensions and cache keys" do
      expect(cf_worker_cache_extensions_and_keys).to be_a(Hash)
      expect(cf_worker_cache_extensions_and_keys[".jpg"]).to eq "caIWHGT4Qhqo6KoxDMNXwQ"
    end
  end

  describe "#cf_cache_key" do
    context "when cache key is configured for the extension" do
      it "returns the cache key" do
        expect(cf_cache_key("filename.zip")).to eq "caIWHGT4Qhqo6KoxDMNXwQ"
      end
    end

    context "when cache key is not configured for the extension" do
      it "returns nil" do
        expect(cf_cache_key("filename.mp3")).to be_nil
      end
    end

    describe "set keys from Redis" do
      before do
        Rails.cache.clear
      end

      it "Overrides cache key with the key from Redis" do
        expect(cf_worker_cache_extensions_and_keys[".jpg"]).to eq "caIWHGT4Qhqo6KoxDMNXwQ"

        $redis.hset(RedisKey.cf_cache_invalidated_extensions_and_cache_keys, ".jpg", Digest::SHA1.hexdigest("2020-10-09"))
        Rails.cache.delete("set_cf_worker_cache_keys_from_redis")

        expect(cf_worker_cache_extensions_and_keys[".jpg"]).to eq Digest::SHA1.hexdigest("2020-10-09")
      end

      it "uses Rails.cache to read the value from Redis only once as long as the Rails cache is present" do
        expect(cf_worker_cache_extensions_and_keys[".mp3"]).to be_nil

        $redis.hset(RedisKey.cf_cache_invalidated_extensions_and_cache_keys, ".mp4", Digest::SHA1.hexdigest("2020-10-09"))

        expect(cf_worker_cache_extensions_and_keys[".mp3"]).to be_nil
      end
    end
  end
end
