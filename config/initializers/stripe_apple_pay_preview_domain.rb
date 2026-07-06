# frozen_string_literal: true

# Preview apps get a unique hostname (<branch>.apps.staging.gumroad.org), and Stripe only renders
# Apple Pay on domains registered with it — registration has no wildcard support, so each preview
# app must register its own hostname. The domain association file is served from
# public/.well-known/, so verification succeeds without any per-app setup.
#
# Staging branch deployments only: production and plain staging hostnames are registered
# out-of-band, and seller subdomains are handled by CreateStripeApplePayDomainWorker.
if Rails.env.staging? && ENV["BRANCH_DEPLOYMENT"] == "true" && ENV["CUSTOM_DOMAIN"].present?
  Rails.application.config.after_initialize do
    Thread.new do
      domain = ENV["CUSTOM_DOMAIN"]
      if Stripe::ApplePayDomain.list(domain_name: domain, limit: 1).data.empty?
        Stripe::ApplePayDomain.create(domain_name: domain)
        Rails.logger.info("Registered Apple Pay domain for preview app: #{domain}")
      end
    rescue StandardError => e
      # Best-effort: a failure here should never take the preview app down.
      Rails.logger.error("Failed to register Apple Pay domain #{domain}: #{e.message}")
    end
  end
end
