# frozen_string_literal: true

require "spec_helper"

describe SslCertificates::Base do
  before do
    stub_const("SslCertificates::Base::CONFIG_FILE",
               Rails.root.join("spec", "support", "fixtures", "ssl_certificates.yml.erb"))

    @obj = SslCertificates::Base.new
  end

  describe "self.supported_environment?" do
    context "when the environment is production or staging" do
      before do
        allow(Rails.env).to receive(:production?).and_return(true)
      end

      it "returns true" do
        expect(SslCertificates::Base.supported_environment?).to be true
      end
    end

    context "when the environment is not production or staging" do
      it "returns false" do
        expect(SslCertificates::Base.supported_environment?).to be false
      end
    end
  end

  describe "#initialize" do
    it "sets the required config variables as methods" do
      expect(@obj.send(:account_email)).to eq "test-service-letsencrypt@gumroad.com"
      expect(@obj.send(:acme_url)).to eq "https://test.api.letsencrypt.org/directory"
      expect(@obj.send(:invalid_domain_cache_expires_in)).to eq 8.hours.seconds
      expect(@obj.send(:max_retries)).to eq 10
      expect(@obj.send(:nginx_sync_duration)).to eq 300.seconds
      expect(@obj.send(:rate_limit)).to eq 300
      expect(@obj.send(:rate_limit_hours)).to eq 3.hours.seconds
      expect(@obj.send(:renew_in)).to eq 60.days.seconds
      expect(@obj.send(:sleep_duration)).to eq 2.seconds
      expect(@obj.send(:ssl_env)).to eq "test"
    end
  end

  describe "#certificate_authority" do
    it "returns the certificate authority" do
      expect(@obj.send(:certificate_authority)).to eq SslCertificates::LetsEncrypt
    end
  end

  describe "#ssl_file_path" do
    it "returns the S3 SSL file path" do
      file_path = @obj.ssl_file_path("sample.com", "sample")

      expect(file_path).to eq "custom-domains-ssl/test/sample.com/ssl/sample"
    end
  end

  describe "#delete_from_s3" do
    before do
      s3_client = double("s3_client")
      @s3_bucket = double("s3_bucket")
      @s3_object = double("s3_object")
      allow(Aws::S3::Resource).to receive(:new).and_return(s3_client)
      allow(s3_client).to receive(:bucket).and_return(@s3_bucket)
      @s3_key = "custom-domains-ssl/test/www.example.com/public/sample_challenge_file"
      allow(@s3_bucket).to receive(:object).with(@s3_key).and_return(@s3_object)
      allow(@s3_object).to receive(:delete)
    end

    it "deletes the file from S3" do
      expect(@s3_bucket).to receive(:object).with(@s3_key).and_return(@s3_object)
      expect(@s3_object).to receive(:delete)

      @obj.send(:delete_from_s3, @s3_key)
    end
  end

  describe "#write_to_s3" do
    it "writes the content to S3" do
      test_key = "test_key"
      test_content = "test_content"

      test_bucket = "test-bucket"
      stub_const("SslCertificates::Base::SECRETS_S3_BUCKET", test_bucket)

      s3_double = double("aws_s3")
      aws_instance_profile_double = double("aws_instance_profile_double")
      allow(Aws::InstanceProfileCredentials).to receive(:new).and_return(aws_instance_profile_double)
      allow(Aws::S3::Resource).to receive(:new).with(credentials: aws_instance_profile_double).and_return(s3_double)

      bucket_double = double("s3_bucket")
      allow(s3_double).to receive(:bucket).with(test_bucket).and_return(bucket_double)

      obj_double = double("s3_obj")
      allow(bucket_double).to receive(:object).with(test_key).and_return(obj_double)

      expect(obj_double).to receive(:put).with(body: test_content)

      @obj.send(:write_to_s3, test_key, test_content)
    end
  end
end
