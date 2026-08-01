# frozen_string_literal: true

# Rack::Timeout with a second, longer budget for request paths that finalize money.
#
# The general web budget is short so one slow request cannot hold a Puma slot long enough
# to matter for fleet capacity. Checkout cannot take that budget: it calls the payment
# processor and only records the local success afterwards, so killing the request mid-flight
# leaves the buyer charged with no successful purchase. Those paths keep the old ceiling
# until finalization is idempotent and resumable.
#
# Delegating to a second Rack::Timeout instance rather than mutating `service_timeout`
# per request keeps the gem's own wait/expiry/SIGTERM accounting intact on both budgets.
class BudgetedRequestTimeout < Rack::Timeout
  # Paths that reach charge creation or its finalization. Custom domains and the api/discover
  # hosts mount these route sets at the same paths, so matching PATH_INFO covers every host.
  EXTENDED_BUDGET_PATHS = [
    # Not every /orders action reaches the processor: `confirm_error` only records a browser-side
    # confirm rejection that happens before any charge exists, so it stays on the general budget.
    %r{\A/orders\z},
    %r{\A/orders/prepare\z},
    %r{\A/orders/[^/]+/(confirm|finalize)\z},
    # Stripe's 3DS return_url. Finalizes the confirmed charge in-request, same as /orders/:id/finalize.
    %r{\A/checkout/returns/[^/]+\z},
    %r{\A/purchases/[^/]+/confirm\z},
    %r{\A/service_charges(\z|/[^/]+/confirm\z)},
    %r{\A/preorders/[^/]+/charge_preorder\z},
    # PUT /subscriptions/:id -> Subscription::UpdaterService, which charges the upgrade inline.
    %r{\A/subscriptions/[^/]+\z},
  ].freeze

  # Single source of truth for both budgets, so in-request guards can size themselves against
  # the ceiling that will actually kill them instead of a duplicated constant.
  module Budget
    GENERAL_DEFAULT_SECONDS = 15
    # Charge creation and its finalization keep the old ceiling: a kill after the processor
    # took the money but before the local success is recorded leaves the buyer charged with a
    # failed purchase, and checkout also waits up to 50s on an inventory lock. Lowering this
    # needs an idempotent, resumable finalization path first.
    CHECKOUT_DEFAULT_SECONDS = 120
    # In-request guards (Api::V2::SalesController's query cap) turn a slow request into an
    # explanatory 4xx before the timeout kills it, which needs at least a second of headroom
    # under the budget. Anything lower would invert that ordering.
    MINIMUM_SECONDS = 2

    class << self
      def general
        resolve("RACK_TIMEOUT_SERVICE_TIMEOUT", GENERAL_DEFAULT_SECONDS)
      end

      def checkout
        # A checkout budget below the general one would defeat the point of having two.
        [resolve("RACK_TIMEOUT_CHECKOUT_SERVICE_TIMEOUT", CHECKOUT_DEFAULT_SECONDS), general].max
      end

      private
        # rack-timeout treats 0 as `false` and disables the timeout outright, and a bare
        # `.to_i` turns "" / "abc" / a stray newline into exactly that. Running with no ceiling
        # is worse than the 120s this replaced, so anything unparseable or below the guard
        # headroom falls back to the default rather than to "unlimited".
        def resolve(env_name, default)
          configured = ENV[env_name]
          return default if configured.nil? || configured.strip.empty?

          if configured.match?(/\A\d+\z/) && configured.to_i >= MINIMUM_SECONDS
            configured.to_i
          else
            Rails.logger.warn("Ignoring invalid #{env_name}=#{configured.inspect} (minimum #{MINIMUM_SECONDS}s)")
            default
          end
        end
    end
  end

  def initialize(app, **options)
    super(app, **options, service_timeout: Budget.general)
    @checkout = Rack::Timeout.new(app, **options, service_timeout: Budget.checkout)
  end

  def call(env)
    return @checkout.call(env) if self.class.extended_budget_path?(env["PATH_INFO"])
    super
  end

  def self.extended_budget_path?(path)
    return false if path.nil? || path.empty?
    EXTENDED_BUDGET_PATHS.any? { path.match?(_1) }
  end
end
