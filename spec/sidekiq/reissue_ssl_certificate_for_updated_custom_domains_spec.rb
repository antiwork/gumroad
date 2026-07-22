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

    context "when a record's persisted domain fails the current validation" do
      before do
        allow_any_instance_of(CustomDomainVerificationService).to receive(:has_valid_ssl_certificates?).and_return(false)
      end

      it "skips the record without aborting the sweep" do
        # A legacy record with an empty-label domain: reset_ssl_certificate_issued_at!
        # runs save!, which would raise RecordInvalid and (with retry: 0)
        # abort the whole sweep for every domain after it.
        invalid_record = build(:custom_domain, domain: "example..com")
        invalid_record.save(validate: false)
        invalid_record.update_column(:ssl_certificate_issued_at, Time.current)

        expect { described_class.new.perform }.not_to raise_error
        expect(invalid_record.reload.ssl_certificate_issued_at).to be_present
      end
    end
  end
end
