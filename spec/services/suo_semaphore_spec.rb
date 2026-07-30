# frozen_string_literal: true

describe SuoSemaphore do
  describe ".custom_domain_certificate" do
    it "bounds a custom domain's certificate-generation lock" do
      semaphore = described_class.custom_domain_certificate(123)

      expect(semaphore.key).to eq("locks:custom_domain:123:certificate")
      expect(semaphore.options[:stale_lock_expiration]).to eq(1.hour.to_i)
    end
  end
end
