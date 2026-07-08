# frozen_string_literal: true

# Registers a staging preview app's hostname with Stripe so wallet buttons (Apple Pay) render on
# it. Each preview app gets a unique hostname (<branch>.apps.staging.gumroad.org), Stripe has no
# wildcard registration, and the domain association file is already served from
# public/.well-known/ — so registration is the only missing step, and the app can do it for
# itself.
#
# Uses Stripe::PaymentMethodDomain rather than the legacy Stripe::ApplePayDomain used elsewhere:
# it both registers the domain and reports whether Apple Pay is actually ACTIVE on it (the
# Stripe<->Apple handshake), including Stripe's error message when it isn't — a domain can be
# "registered" while Apple Pay is still inactive on it, which the legacy endpoint can't detect.
class StagingApplePayDomainRegistration
  Result = Struct.new(:active, :message, keyword_init: true) do
    def active?
      active
    end
  end

  # Staging branch deployments only: production and plain staging hostnames are registered
  # out-of-band, and seller subdomains are handled by CreateStripeApplePayDomainWorker.
  def self.applicable?
    Rails.env.staging? && ENV["BRANCH_DEPLOYMENT"] == "true" && ENV["CUSTOM_DOMAIN"].present?
  end

  # Idempotent: create returns the existing record for an already-registered domain, and
  # validate re-runs domain verification, refreshing apple_pay.status.
  def self.register!
    domain = ENV["CUSTOM_DOMAIN"]
    pm_domain = Stripe::PaymentMethodDomain.create(domain_name: domain)
    pm_domain = Stripe::PaymentMethodDomain.validate(pm_domain.id)
    status = pm_domain.apple_pay.status
    error = status == "active" ? nil : pm_domain.apple_pay.try(:status_details)&.try(:error_message)

    Result.new(
      active: status == "active",
      message: ["Apple Pay on #{domain}: #{status}", error].compact.join(" — "),
    )
  end
end
