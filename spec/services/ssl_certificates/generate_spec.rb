# frozen_string_literal: true

require "spec_helper"

describe SslCertificates::Generate do
  before do
    stub_const("SslCertificates::Base::CONFIG_FILE",
               File.join(Rails.root, "spec", "support", "fixtures", "ssl_certificates.yml.erb"))

    @custom_domain = create(:custom_domain, domain: "www.example.com")
    @obj = SslCertificates::Generate.new(@custom_domain)
  end

  it "inherits from SslCertificates::Base" do
    expect(described_class).to be < SslCertificates::Base
  end

  describe "#hourly_rate_limit_reached?" do
    before do
      allow_any_instance_of(described_class).to receive(:rate_limit).and_return(1)
      create(:custom_domain, domain: "www.example-1.com").set_ssl_certificate_issued_at!
    end

    context "when hourly limit is not reached" do
      it "returns false" do
        expect(@obj.send(:hourly_rate_limit_reached?)).to eq false
      end
    end

    context "when hourly limit is reached" do
      context "when there are no deleted domains" do
        before do
          create(:custom_domain, domain: "www.example-2.com").set_ssl_certificate_issued_at!
        end

        it "returns true" do
          expect(@obj.send(:hourly_rate_limit_reached?)).to eq true
        end
      end

      context "when there are deleted domains" do
        before do
          create(:custom_domain, domain: "www.example-2.com").set_ssl_certificate_issued_at!
          custom_domain_3 = create(:custom_domain, domain: "www.example-3.com")
          custom_domain_3.set_ssl_certificate_issued_at!
          custom_domain_3.mark_deleted!
        end

        it "returns true" do
          expect(@obj.send(:hourly_rate_limit_reached?)).to eq true
        end
      end
    end
  end

  describe "#can_order_certificates?" do
    context "with a valid certificate" do
      it "returns false when the domain already has a valid certificate" do
        @custom_domain.set_ssl_certificate_issued_at!
        expect(@obj.send(:can_order_certificates?)).to eq [false, "Has valid certificate"]
      end
    end

    context "when the domain is invalid" do
      before do
        @custom_domain.domain = "test_store.example.com"
        @custom_domain.save(validate: false)
      end

      it "returns false with an error message" do
        expect(@obj.send(:can_order_certificates?)).to eq [false, "Invalid domain"]
      end
    end

    context "when the hourly limit is reached" do
      it "returns false when the hourly rate limit is reached" do
        custom_domains_double = double("custom_domains collection")
        allow(CustomDomain).to receive(:certificates_younger_than).with(@obj.send(:rate_limit_hours)).and_return(custom_domains_double)
        allow(custom_domains_double).to receive(:count).and_return(@obj.send(:rate_limit) + 1)

        expect(@obj.send(:can_order_certificates?)).to eq [false, "Hourly limit reached"]
      end
    end

    describe "CNAME/ALIAS check" do
      before do
        allow_any_instance_of(CustomDomain).to receive(:cname_is_setup_correctly?).and_return(false)
        allow_any_instance_of(CustomDomain).to receive(:alias_is_setup_correctly?).and_return(false)
      end

      it "returns false when no domains are pointed to Gumroad" do
        expect(@obj.send(:can_order_certificates?)).to eq [false, "No domains pointed to Gumroad"]
      end
    end
  end

  describe "#domain_check_cache_key" do
    it "returns domin check cache key" do
      expect(@obj.send(:domain_check_cache_key)).to eq "domain_check_www.example.com"
    end
  end

  describe "#generate_certificate" do
    before do
      @letsencrypt_double = double("letsencrypt")
      allow(SslCertificates::LetsEncrypt).to receive(:new).with("test-domain").and_return(@letsencrypt_double)
    end

    it "invokes process method of LetsEncrypt service" do
      expect(@letsencrypt_double).to receive(:process)

      @obj.send(:generate_certificate, "test-domain")
    end
  end

  describe "#process" do
    context "when `can_order_certificates?` returns false" do
      before do
        allow_any_instance_of(described_class).to receive(:can_order_certificates?).and_return([false, "sample error message"])
      end

      it "logs a message" do
        expect(@obj).to receive(:log_message).with(@custom_domain.domain, "sample error message")

        @obj.process
      end
    end

    context "when the certificate is successfully created" do
      before do
        @domains_pointed_to_gumroad = ["example.com", "www.example.com"]
        allow(@obj).to receive(:can_order_certificates?).and_return(true)
        allow_any_instance_of(CustomDomainVerificationService).to receive(:domains_pointed_to_gumroad).and_return(@domains_pointed_to_gumroad)

        @domains_pointed_to_gumroad.each do |domain|
          allow(@obj).to receive(:generate_certificate).with(domain).and_return(true)
        end
      end

      it "set ssl_certificate_issued_at and logs a message" do
        @domains_pointed_to_gumroad.each do |domain|
          expect(@obj).to receive(:generate_certificate).with(domain)
          expect(@obj).to receive(:log_message).with(domain, "Issued SSL certificate.")
        end

        time = Time.current
        travel_to(time) do
          @obj.process
        end

        expect(@custom_domain.reload.ssl_certificate_issued_at.to_i).to eq time.to_i
      end
    end

    context "when the certificate generation fails" do
      before do
        allow_any_instance_of(described_class).to receive(:can_order_certificates?).and_return(true)
        allow_any_instance_of(described_class).to receive(:generate_certificate).and_return(false)
        allow_any_instance_of(CustomDomainVerificationService).to receive(:domains_pointed_to_gumroad).and_return([@custom_domain.domain])

        @custom_domain.set_ssl_certificate_issued_at!
      end

      it "writes the information to cache and resets custom_domain's ssl_certificate_issued_at attribute" do
        cache_double = double(".cache")
        allow(Rails).to receive(:cache).and_return(cache_double)

        expect(cache_double).to receive(:write).with("domain_check_#{@custom_domain.domain}", false, expires_in: @obj.send(:invalid_domain_cache_expires_in))
        expect(@obj).to receive(:log_message).with(@custom_domain.domain, "LetsEncrypt order failed. Next retry in about 8 hours.")

        @obj.process

        expect(@custom_domain.reload.ssl_certificate_issued_at).to be_nil
      end
    end
  end
end
