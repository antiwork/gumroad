# frozen_string_literal: true

require "spec_helper"

describe CustomDomainVerificationService do
  let(:domain) { "example.com" }
  subject(:service) { described_class.new(domain:) }

  describe "#process" do
    describe "domain CNAME configuration" do
      let(:domain) { "store.example.com" }

      context "when there exists a CNAME record pointing to the correct domain" do
        before do
          allow_any_instance_of(Resolv::DNS)
            .to receive(:getresources)
            .with(domain, Resolv::DNS::Resource::IN::CNAME)
            .and_return([double(name: "domains-staging.gumroad.com")])
        end

        it "returns success response" do
          expect(service.process).to eq(true)
        end
      end

      context "when there doesn't exist a CNAME record pointing to the correct domain" do
        before do
          allow_any_instance_of(Resolv::DNS)
            .to receive(:getresources)
            .with(domain, Resolv::DNS::Resource::IN::CNAME)
            .and_return([double(name: "wrong-domain.gumroad.com")])
        end

        describe "domain ALIAS configuration" do
          before do
            allow_any_instance_of(Resolv::DNS)
              .to receive(:getresources)
              .with(CUSTOM_DOMAIN_CNAME, Resolv::DNS::Resource::IN::A)
              .and_return([double(address: "100.0.0.1"), double(address: "100.0.0.2")])

            allow_any_instance_of(Resolv::DNS)
              .to receive(:getresources)
              .with(CUSTOM_DOMAIN_STATIC_IP_HOST, Resolv::DNS::Resource::IN::A)
              .and_return([double(address: "100.0.0.10"), double(address: "100.0.0.20")])
          end

          context "when the domain is pointed to CUSTOM_DOMAIN_CNAME using ALIAS records" do
            before do
              allow_any_instance_of(Resolv::DNS)
                .to receive(:getresources)
                .with(domain, Resolv::DNS::Resource::IN::A)
                .and_return([double(address: "100.0.0.1"), double(address: "100.0.0.2")])
            end

            it "returns success response" do
              expect(service.process).to eq(true)
            end
          end

          context "when the domain is pointed to CUSTOM_DOMAIN_STATIC_IP_HOST using ALIAS records" do
            before do
              allow_any_instance_of(Resolv::DNS)
                .to receive(:getresources)
                .with(domain, Resolv::DNS::Resource::IN::A)
                .and_return([double(address: "100.0.0.20"), double(address: "100.0.0.10")])
            end

            it "returns success response" do
              expect(service.process).to eq(true)
            end
          end

          context "when the domain is not pointed to either CUSTOM_DOMAIN_CNAME or CUSTOM_DOMAIN_STATIC_IP_HOST using ALIAS records" do
            before do
              allow_any_instance_of(Resolv::DNS)
                .to receive(:getresources)
                .with(domain, Resolv::DNS::Resource::IN::A)
                .and_return([double(address: "100.0.0.2")])
            end

            it "returns error response" do
              expect(service.process).to eq(false)
            end
          end
        end
      end
    end

    context "when the domain is invalid" do
      let(:domain) { "http://example.com" }

      it "returns error response" do
        expect(service.process).to eq(false)
      end
    end
  end

  describe "#domains_pointed_to_gumroad" do
    before(:each) do
      allow_any_instance_of(Resolv::DNS)
        .to receive(:getresources)
        .with(anything, Resolv::DNS::Resource::IN::CNAME)
        .and_return([double(name: CUSTOM_DOMAIN_CNAME)])
    end

    context "when it is a root domain" do
      it "returns the root domain and the one with www prefix" do
        expect(service.domains_pointed_to_gumroad).to eq ["example.com", "www.example.com"]
      end
    end

    context "when it's a domain with subdomain'" do
      let(:domain) { "test.example.com" }

      it "returns the domain" do
        expect(service.domains_pointed_to_gumroad).to eq ["test.example.com"]
      end
    end
  end

  describe "#has_valid_ssl_certificates?" do
    before(:each) do
      allow_any_instance_of(Resolv::DNS)
        .to receive(:getresources)
        .with(anything, Resolv::DNS::Resource::IN::CNAME)
        .and_return([double(name: CUSTOM_DOMAIN_CNAME)])

      allow(SslCertificates::Base).to receive(:new).and_return(double(ssl_file_path: "path/cert"))
      s3_double = double("s3")
      allow(Aws::S3::Resource).to receive(:new).and_return(s3_double)
      s3_object = double("s3_object")
      allow(s3_double).to receive(:bucket).and_return(double(object: s3_object))
      allow(s3_object).to receive(:exists?).and_return(true)
      allow(s3_object).to receive(:get).and_return(double(body: double(read: double)))
      allow(OpenSSL::X509::Certificate).to receive(:new).and_return(double(not_after: 5.days.from_now))
    end

    it "returns true when valid SSL certificates are found for all associated domains" do
      expect(OpenSSL::X509::Certificate).to receive(:new).twice

      expect_any_instance_of(Redis::Namespace).to receive(:get).with("ssl_cert_check:example.com")
      expect_any_instance_of(Redis::Namespace).to receive(:set).with("ssl_cert_check:example.com", true, ex: 10.days)

      expect_any_instance_of(Redis::Namespace).to receive(:get).with("ssl_cert_check:www.example.com")
      expect_any_instance_of(Redis::Namespace).to receive(:set).with("ssl_cert_check:www.example.com", true, ex: 10.days)

      expect(service.has_valid_ssl_certificates?).to eq true
    end
  end
end
