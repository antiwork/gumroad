# frozen_string_literal: true

require "spec_helper"

describe ReissueSslCertificateForUpdatedCustomDomains do
  describe "#perform" do
    let(:custom_domain) { create(:custom_domain) }

    before do
      custom_domain.set_ssl_certificate_issued_at!
      allow_any_instance_of(CustomDomainVerificationService)
        .to receive(:domains_resolving_to_gumroad)
        .and_return([custom_domain.domain])
    end

    context "when valid certificates are not found for the domain" do
      before do
        allow_any_instance_of(CustomDomainVerificationService).to receive(:has_valid_ssl_certificates?).and_return(false)
        allow_any_instance_of(CustomDomainVerificationService).to receive(:has_valid_ssl_certificate_for?).and_return(false)
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
        expect_any_instance_of(CustomDomainVerificationService).not_to receive(:domains_resolving_to_gumroad)
        expect_any_instance_of(CustomDomain).not_to receive(:reset_ssl_certificate_issued_at!)
        expect_any_instance_of(CustomDomain).not_to receive(:generate_ssl_certificate)

        described_class.new.perform
      end
    end

    context "when a record's persisted domain fails the current validation" do
      before do
        allow_any_instance_of(CustomDomainVerificationService).to receive(:has_valid_ssl_certificates?).and_return(false)
        allow_any_instance_of(CustomDomainVerificationService).to receive(:has_valid_ssl_certificate_for?).and_return(false)
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

    context "when the aggregate certificate check fails" do
      let(:verification_service) { instance_double(CustomDomainVerificationService) }

      before do
        allow(CustomDomainVerificationService).to receive(:new).with(domain: custom_domain.domain).and_return(verification_service)
        allow(verification_service).to receive(:has_valid_ssl_certificates?).with(no_args).and_return(false)
        allow(verification_service).to receive(:domains_resolving_to_gumroad).and_return(["www.example.com"])
      end

      it "keeps the issuance timestamp when every resolving variant has a valid certificate" do
        expect(verification_service).to receive(:has_valid_ssl_certificate_for?).with("www.example.com").and_return(true)
        expect_any_instance_of(CustomDomain).not_to receive(:reset_ssl_certificate_issued_at!)
        expect_any_instance_of(CustomDomain).not_to receive(:generate_ssl_certificate)

        described_class.new.perform
      end

      it "regenerates certificates when a resolving variant does not have a valid certificate" do
        allow(verification_service).to receive(:domains_resolving_to_gumroad).and_return(["example.com", "www.example.com"])
        expect(verification_service).to receive(:has_valid_ssl_certificate_for?).with("example.com").and_return(true)
        expect(verification_service).to receive(:has_valid_ssl_certificate_for?).with("www.example.com").and_return(false)
        calls = []
        allow_any_instance_of(CustomDomain).to receive(:reset_ssl_certificate_issued_at!) { calls << :reset }
        allow_any_instance_of(CustomDomain).to receive(:generate_ssl_certificate) { calls << :generate }

        described_class.new.perform

        expect(calls).to eq([:reset, :generate])
      end

      it "keeps the issuance timestamp when no variants resolve to Gumroad" do
        allow(verification_service).to receive(:domains_resolving_to_gumroad).and_return([])
        expect(verification_service).not_to receive(:has_valid_ssl_certificate_for?)
        expect_any_instance_of(CustomDomain).not_to receive(:reset_ssl_certificate_issued_at!)
        expect_any_instance_of(CustomDomain).not_to receive(:generate_ssl_certificate)

        described_class.new.perform
      end
    end

    context "when processing multiple custom domains" do
      let(:second_custom_domain) { create(:custom_domain, domain: "second.example.com") }
      let(:first_verification_service) { instance_double(CustomDomainVerificationService) }
      let(:second_verification_service) { instance_double(CustomDomainVerificationService) }

      before do
        second_custom_domain.set_ssl_certificate_issued_at!
        allow(CustomDomainVerificationService).to receive(:new) do |domain:|
          {
            custom_domain.domain => first_verification_service,
            second_custom_domain.domain => second_verification_service,
          }.fetch(domain)
        end
        allow(second_verification_service).to receive(:has_valid_ssl_certificates?).with(no_args).and_return(false)
        allow(second_verification_service).to receive(:domains_resolving_to_gumroad).and_return([second_custom_domain.domain])
        allow(second_verification_service).to receive(:has_valid_ssl_certificate_for?).with(second_custom_domain.domain).and_return(false)
      end

      it "continues after a domain passes the aggregate certificate check" do
        allow(first_verification_service).to receive(:has_valid_ssl_certificates?).with(no_args).and_return(true)

        described_class.new.perform

        expect(custom_domain.reload.ssl_certificate_issued_at).to be_present
        expect(second_custom_domain.reload.ssl_certificate_issued_at).to be_nil
      end

      it "continues after a domain has no resolving variants" do
        allow(first_verification_service).to receive(:has_valid_ssl_certificates?).with(no_args).and_return(false)
        allow(first_verification_service).to receive(:domains_resolving_to_gumroad).and_return([])

        described_class.new.perform

        expect(custom_domain.reload.ssl_certificate_issued_at).to be_present
        expect(second_custom_domain.reload.ssl_certificate_issued_at).to be_nil
      end
    end
  end
end
