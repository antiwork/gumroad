# frozen_string_literal: true

require "test_helper"

class CustomDomainsVerificationWorkerTest < ActiveSupport::TestCase
  self.described_class = CustomDomainsVerificationWorker



  context_ CustomDomainsVerificationWorker do
    let!(:custom_domain_one) { create(:custom_domain) }
    let!(:custom_domain_two) { create(:custom_domain, failed_verification_attempts_count: 3) }
    let!(:custom_domain_three) { create(:custom_domain, state: "verified") }
    let!(:custom_domain_four) { create(:custom_domain, state: "verified", deleted_at: 2.days.ago) }
    let!(:custom_domain_five) { create(:custom_domain, failed_verification_attempts_count: 2) }

  test "verifies every non-deleted domain in its own background job" do
      described_class.new.perform

      expect(CustomDomainVerificationWorker).to have_enqueued_sidekiq_job(custom_domain_one.id)
      expect(CustomDomainVerificationWorker).not_to have_enqueued_sidekiq_job(custom_domain_two.id)
      expect(CustomDomainVerificationWorker).to have_enqueued_sidekiq_job(custom_domain_three.id)
      expect(CustomDomainVerificationWorker).not_to have_enqueued_sidekiq_job(custom_domain_four.id)
      expect(CustomDomainVerificationWorker).to have_enqueued_sidekiq_job(custom_domain_five.id)
    end
  end
end
