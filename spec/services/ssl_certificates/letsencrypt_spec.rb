# frozen_string_literal: true

require "spec_helper"

describe SslCertificates::LetsEncrypt do
  before do
    stub_const("SslCertificates::Base::CONFIG_FILE",
               File.join(Rails.root, "spec", "support", "fixtures", "ssl_certificates.yml.erb"))

    @custom_domain = create(:custom_domain, domain: "www.example.com")
    @obj = SslCertificates::LetsEncrypt.new(@custom_domain.domain)
  end

  it "inherits from SslCertificates::Base" do
    expect(described_class).to be < SslCertificates::Base
  end

  describe "#initialize" do
    it "initializes custom_domain" do
      expect(@obj.send(:domain)).to eq @custom_domain.domain
    end

    describe "certificate_private_key" do
      context "when initialized" do
        it { expect(@obj.send(:certificate_private_key).class).to eq OpenSSL::PKey::RSA }
      end

      context "when the key size is 2048" do
        it { expect(@obj.certificate_private_key.n.num_bits).to eq 2048 }
      end
    end
  end

  describe "#upload_certificate_to_s3" do
    it "invokes write_to_s3 twice to upload key and cert" do
      sample_path = "/sample/path"
      allow_any_instance_of(described_class).to receive(:ssl_file_path).and_return(sample_path)

      certificate = "cert 123"
      key = "key 123"

      expect(@obj).to receive(:write_to_s3).with(sample_path, certificate)
      expect(@obj).to receive(:write_to_s3).with(sample_path, key)

      @obj.send(:upload_certificate_to_s3, certificate, key)
    end
  end

  describe "#finalize_with_csr" do
    it "finalizes order and return certificate" do
      order_double = double("order")
      certificate_double = double("certificate")
      allow(order_double).to receive(:status).and_return("processed")
      allow(order_double).to receive(:certificate).and_return(certificate_double)

      csr_double = double("csr_double")
      allow(Acme::Client::CertificateRequest).to receive(:new).and_return(csr_double)

      http_challenge_double = double("http_challenge")

      expect(order_double).to receive(:finalize).with(csr: csr_double)
      expect(order_double).to receive(:certificate)

      returned_object = @obj.send(:finalize_with_csr, order_double, http_challenge_double)

      expect(returned_object).to eq certificate_double
    end
  end

  describe "#poll_validation_status" do
    before do
      @http_challenge_double = double("http_challenge")
      allow(@http_challenge_double).to receive(:status).and_return("pending")
      allow(@http_challenge_double).to receive(:reload)

      allow_any_instance_of(Object).to receive(:sleep)

      @max_tries = @obj.send(:max_retries)
    end

    it "polls for validation status 'max_tries' times" do
      expect(@http_challenge_double).to receive(:status).exactly(@max_tries).times
      expect_any_instance_of(Object).to receive(:sleep).exactly(@max_tries).times
      expect(@http_challenge_double).to receive(:reload).exactly(@max_tries).times

      @obj.send(:poll_validation_status, @http_challenge_double)
    end
  end

  describe "#request_validation" do
    before do
      @http_challenge_double = double("http_challenge")
      allow(@http_challenge_double).to receive(:request_validation)
    end

    it "requests for HTTP validation" do
      expect(@http_challenge_double).to receive(:request_validation)

      @obj.send(:request_validation, @http_challenge_double)
    end
  end

  describe "#prepare_http_challenge" do
    before do
      @sample_token        = "sample_token"
      @sample_file_content = "sample content"
      @http_challenge_double = double("http_challenge")
      allow(@http_challenge_double).to receive(:token).and_return(@sample_token)
      allow(@http_challenge_double).to receive(:file_content).and_return(@sample_file_content)
    end

    it "stores validation content in Redis" do
      expect($redis).to receive(:setex).with(RedisKey.acme_challenge(@sample_token), described_class::CHALLENGE_TTL, @sample_file_content)

      @obj.send(:prepare_http_challenge, @http_challenge_double)
    end
  end

  describe "#delete_http_challenge" do
    before do
      @sample_token = "sample_token"
      @http_challenge_double = double("http_challenge")
      allow(@http_challenge_double).to receive(:token).and_return(@sample_token)
    end

    it "deletes validation content from Redis" do
      expect($redis).to receive(:del).with(RedisKey.acme_challenge(@sample_token))

      @obj.send(:delete_http_challenge, @http_challenge_double)
    end
  end

  describe "#order_certificate" do
    before do
      client_double = double("client_double")
      @order_double = double("order_double")
      allow_any_instance_of(described_class).to receive(:client).and_return(client_double)
      allow(client_double).to receive(:new_order).and_return(@order_double)

      @authorization_double = double("authorization_double")
      allow(@order_double).to receive(:authorizations).and_return([@authorization_double])
      @http_challenge_double = double("http_challenge_double")
      allow(@authorization_double).to receive(:http).and_return(@http_challenge_double)
    end

    it "orders the certificate" do
      expect(@order_double).to receive(:authorizations)

      returned_objects = @obj.send(:order_certificate)

      expect(returned_objects).to eq [@order_double, @http_challenge_double]
    end
  end

  describe "#client" do
    before do
      account_private_key_double = double("account_private_key_double")
      allow_any_instance_of(described_class).to receive(:account_private_key)
        .and_return(account_private_key_double)

      @client_double = double("client_double")
      allow(Acme::Client).to receive(:new).and_return(@client_double)
      allow(@client_double).to receive(:new_account)
    end

    context "when ACME account doesn't exist" do
      before do
        allow(@client_double).to receive(:account).and_raise(Acme::Client::Error::AccountDoesNotExist)
      end

      it "creates the ACME account" do
        expect(@client_double).to receive(:new_account)
        client = @obj.send(:client)
        expect(client).to eq @client_double
      end
    end

    context "when ACME account exists" do
      before do
        account_double = double("account")
        allow(@client_double).to receive(:account).and_return(account_double)
      end

      it "doesn't create the ACME account" do
        expect(@client_double).not_to receive(:new_account)
        client = @obj.send(:client)
        expect(client).to eq @client_double
      end

      it "caches the account status" do
        allow(@client_double).to receive(:account).once

        2.times do
          @obj.send(:client)
        end
      end
    end
  end

  describe "#account_private_key" do
    before do
      @pkey_double = double("pkey_double")
      @private_key = "private_key"
      allow(OpenSSL::PKey::RSA).to receive(:new).and_return(@pkey_double)
      ENV["LETS_ENCRYPT_ACCOUNT_PRIVATE_KEY"] = @private_key
    end

    after do
      ENV["LETS_ENCRYPT_ACCOUNT_PRIVATE_KEY"] = nil
    end

    it "returns account private key" do
      expect(OpenSSL::PKey::RSA).to receive(:new).with(@private_key).and_return(@pkey_double)
      expect(@obj.send(:account_private_key)).to eq @pkey_double
    end
  end

  describe "#process" do
    before do
      @order_double          = double("order_double")
      @http_challenge_double = double("http_challenge_double")
      @certificate_double    = double("certificate_double")
      @sample_token          = "challenge-token"

      allow_any_instance_of(described_class).to receive(:order_certificate)
        .and_return([@order_double, @http_challenge_double])
      allow_any_instance_of(described_class).to receive(:prepare_http_challenge).with(@http_challenge_double)
      allow_any_instance_of(Object).to receive(:sleep)
      allow_any_instance_of(described_class).to receive(:request_validation).with(@http_challenge_double)
      allow_any_instance_of(described_class).to receive(:poll_validation_status).with(@http_challenge_double)
      allow_any_instance_of(described_class).to receive(:upload_certificate_to_s3)
        .with(@certificate_double, @obj.send(:certificate_private_key))
      allow_any_instance_of(described_class).to receive(:finalize_with_csr)
                                                  .with(@order_double, @http_challenge_double).and_return(@certificate_double)
      allow(@http_challenge_double).to receive(:token).and_return(@sample_token)
      allow($redis).to receive(:del)
    end

    context "when the order is successful" do
      it "processes the LetsEncrypt order" do
        expect(@obj).to receive(:order_certificate).and_return([@order_double, @http_challenge_double])
        expect(@obj).to receive(:prepare_http_challenge).with(@http_challenge_double)
        expect(@obj).to receive(:request_validation).with(@http_challenge_double)
        expect(@obj).to receive(:poll_validation_status).with(@http_challenge_double)
        expect(@obj).to receive(:finalize_with_csr).with(@order_double, @http_challenge_double)
          .and_return(@certificate_double)
        expect(@obj).to receive(:upload_certificate_to_s3).with(@certificate_double, @obj.send(:certificate_private_key))
        @obj.process
      end

      it "deletes the http challenge from Redis" do
        expect($redis).to receive(:del).with(RedisKey.acme_challenge(@sample_token))

        @obj.process
      end
    end

    context "when the order fails" do
      it "logs message and returns false" do
        allow_any_instance_of(described_class).to receive(:finalize_with_csr)
          .with(@order_double, @http_challenge_double).and_raise("sample error message")

        expect(@obj).to receive(:order_certificate).and_return([@order_double, @http_challenge_double])
        expect(@obj).to receive(:prepare_http_challenge).with(@http_challenge_double)
        expect(@obj).to receive(:request_validation).with(@http_challenge_double)
        expect(@obj).to receive(:poll_validation_status).with(@http_challenge_double)
        expect(@obj).to receive(:log_message).with(@custom_domain.domain, "SSL Certificate cannot be issued. Error: sample error message")

        expect(@obj.process).to be false
        expect(@custom_domain.ssl_certificate_issued_at).to be_nil
      end

      it "deletes the http challenge from Redis" do
        expect($redis).to receive(:del).with(RedisKey.acme_challenge(@sample_token))

        @obj.process
      end
    end
  end
end
