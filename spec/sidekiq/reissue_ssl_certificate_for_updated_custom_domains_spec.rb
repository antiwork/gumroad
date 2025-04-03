# frozen_string_literal: true

require "spec_helper"

describe ReissueSslCertificateForUpdatedCustomDomains do
  describe "#perform" do
    before do
      custom_domain = create(:custom_domain)
      custom_domain.set_ssl_certificate_issued_at!
    end

    context "when valid certificates are not found for the domain" do
      before do
        allow_any_instance_of(CustomDomainVerificationService).to receive(:has_valid_ssl_certificates?).and_return(false)
      end

      it "generates new certificates for the domain" do
        expect_any_instance_of(CustomDomain).to receive(:reset_ssl_certificate_issued_at!)
        expect_any_instance_of(CustomDomain).to receive(:generate_ssl_certificate)

        described_class.new.perform
      end
    end

    context "when valid certificates are found for the domain" do
      before do
        allow_any_instance_of(CustomDomainVerificationService).to receive(:has_valid_ssl_certificates?).and_return(true)
      end

      it "doesn't generate new certificates for the domain" do
        expect_any_instance_of(CustomDomain).not_to receive(:reset_ssl_certificate_issued_at!)
        expect_any_instance_of(CustomDomain).not_to receive(:generate_ssl_certificate)

        described_class.new.perform
      end
    end
  end
end
