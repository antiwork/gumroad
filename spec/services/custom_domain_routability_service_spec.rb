# frozen_string_literal: true

require "spec_helper"

describe CustomDomainRoutabilityService do
  let(:custom_domain) { create(:custom_domain, :verified_with_certificate, domain: "shop.example.com") }
  let(:verification_service) do
    double(
      domains_resolving_to_gumroad: resolving_domains,
      has_valid_ssl_certificate_for?: has_valid_certificate
    )
  end
  let(:observed_at) { Time.current.change(usec: 123_456) }
  let(:service) { described_class.new(custom_domain, verification_service:, observed_at:) }

  before do
    custom_domain
    GenerateSslCertificate.clear
  end

  context "when the configured hostname does not resolve to Gumroad" do
    let(:resolving_domains) { ["example.com"] }
    let(:has_valid_certificate) { true }

    it "persists a negative result without checking its certificate" do
      expect(verification_service).not_to receive(:has_valid_ssl_certificate_for?)

      service.process

      expect(custom_domain.reload).not_to be_routable
      expect(custom_domain.routability_checked_at).to eq(observed_at)
      expect(GenerateSslCertificate).not_to have_enqueued_sidekiq_job(custom_domain.id)
    end
  end

  context "when the configured hostname resolves and has a valid certificate" do
    let(:resolving_domains) { [custom_domain.domain] }
    let(:has_valid_certificate) { true }

    it "persists a positive result" do
      service.process

      expect(custom_domain.reload).to be_routable
      expect(custom_domain.routability_checked_at).to eq(observed_at)
      expect(GenerateSslCertificate).not_to have_enqueued_sidekiq_job(custom_domain.id)
    end
  end

  context "when the configured hostname resolves without a valid certificate" do
    let(:resolving_domains) { [custom_domain.domain] }
    let(:has_valid_certificate) { false }

    it "keeps the host unroutable and forces certificate issuance" do
      service.process

      expect(custom_domain.reload).not_to be_routable
      expect(custom_domain.ssl_certificate_issued_at).to be_nil
      expect(custom_domain.routability_checked_at).to eq(observed_at)
      expect(GenerateSslCertificate).to have_enqueued_sidekiq_job(custom_domain.id)
    end
  end
end
