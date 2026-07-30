# frozen_string_literal: true

require "spec_helper"

describe RefreshCustomDomainRoutabilityWorker do
  let(:custom_domain) { create(:custom_domain, :verified_with_certificate, domain: "shop.example.com") }
  let(:resolving_domains) { [] }
  let(:verification_service) { double(domains_resolving_to_gumroad: resolving_domains) }

  before do
    allow(CustomDomainVerificationService)
      .to receive(:new)
      .with(domain: custom_domain.domain)
      .and_return(verification_service)
  end

  it "deduplicates jobs until execution finishes" do
    expect(described_class.sidekiq_options["lock"]).to eq(:until_executed)
  end

  context "when the configured hostname resolves to Gumroad" do
    let(:resolving_domains) { [custom_domain.domain] }

    it "persists a positive routability result" do
      described_class.new.perform(custom_domain.id)

      expect(custom_domain.reload).to be_routable
      expect(custom_domain.routability_checked_at).to be_present
    end
  end

  context "when only the configured hostname's counterpart resolves to Gumroad" do
    let(:resolving_domains) { ["example.com"] }

    it "persists a negative routability result" do
      described_class.new.perform(custom_domain.id)

      expect(custom_domain.reload).not_to be_routable
      expect(custom_domain.routability_checked_at).to be_present
      expect(custom_domain).to be_verified
    end
  end

  context "when the custom domain is no longer active" do
    let(:resolving_domains) { [] }

    it "does not perform DNS verification" do
      custom_domain.update_columns(ssl_certificate_issued_at: 8.days.ago)

      expect(CustomDomainVerificationService).not_to receive(:new)

      described_class.new.perform(custom_domain.id)
    end
  end

  context "when another refresh has already stored a current result" do
    let(:resolving_domains) { [] }

    it "does not perform DNS verification" do
      custom_domain.set_routability!(true)

      expect(CustomDomainVerificationService).not_to receive(:new)

      described_class.new.perform(custom_domain.id)
    end
  end
end
