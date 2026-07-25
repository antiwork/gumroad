# frozen_string_literal: true

require "spec_helper"

# Buyer-currency charging runs on Stripe's FX Quotes API, which is still a *preview* API:
# offered as is, with no warranty and no committed deprecation window. We accept that risk
# (see docs/stripe_fx_quotes_preview_api.md) on one condition — the preview version must stay
# *scoped* to the FX-quote calls, so a plain USD charge, a payout, a refund, or account
# onboarding never rides a preview API version.
#
# These examples exist to fail loudly if that scoping erodes: a global version bump onto a
# preview train, or an FX-quote version override leaking onto charges that have no quote.
describe "Stripe FX Quotes preview API pin" do
  it "pins a preview API version in exactly one place" do
    expect(StripeFxQuote::API_VERSION).to match(/\A\d{4}-\d{2}-\d{2}\.preview\z/)
  end

  it "keeps the global Stripe API version off any preview train" do
    # Every other Stripe call in the app inherits this version. A preview train here would
    # silently move payouts, refunds, and onboarding onto an unsupported API.
    expect(Stripe.api_version).not_to include("preview")
  end

  # Ruby files that are allowed to name a per-request Stripe API version at all. Deliberately
  # matched on the bare `stripe_version` option rather than on `StripeFxQuote::API_VERSION`, so a
  # new override written as a raw version string, a local alias, a helper method, or an expression
  # spread over several lines still trips this list.
  let(:allowed_stripe_version_senders) do
    {
      "app/business/payments/charging/implementations/stripe/stripe_fx_quote.rb" =>
        "creates the FX quote itself — this *is* the preview endpoint",
      "app/business/payments/charging/implementations/stripe/stripe_deferred_payment_intent.rb" =>
        "attaches an FX quote to a deferred PaymentIntent",
      "app/business/payments/charging/implementations/stripe/stripe_charge_processor.rb" =>
        "attaches an FX quote to a PaymentIntent",
      "app/services/stripe_tax_forms_api.rb" =>
        "passes the global (stable) Stripe.api_version through explicitly, not a preview version",
    }
  end

  def ruby_sources
    Dir[Rails.root.join("app/**/*.rb")] + Dir[Rails.root.join("lib/**/*.rb")] + Dir[Rails.root.join("config/**/*.rb")]
  end

  def relative(path) = Pathname.new(path).relative_path_from(Rails.root).to_s

  it "sets a per-request Stripe API version only in the known, reviewed places" do
    senders = ruby_sources.filter_map { |path| relative(path) if File.read(path).include?("stripe_version") }

    expect(senders).to match_array(allowed_stripe_version_senders.keys),
                       "a new file overrides the Stripe API version per request. If that is intended, add it to " \
                       "allowed_stripe_version_senders with the reason, and make sure it is not sending a preview " \
                       "version outside the FX quote flow."
  end

  it "hardcodes a preview API version nowhere but the FX quote class" do
    # Catches an override that skips the constant entirely and writes a preview version inline.
    carriers = ruby_sources.filter_map { |path| relative(path) if File.read(path).match?(/\d{4}-\d{2}-\d{2}\.preview/) }

    expect(carriers).to eq(["app/business/payments/charging/implementations/stripe/stripe_fx_quote.rb"])
  end

  it "guards each PaymentIntent override on an FX quote actually being present" do
    # The quote-creation call is unconditionally on the preview version (it *is* the preview
    # endpoint). The two PaymentIntent paths must only opt in when a quote id is attached.
    %w[
      app/business/payments/charging/implementations/stripe/stripe_deferred_payment_intent.rb
      app/business/payments/charging/implementations/stripe/stripe_charge_processor.rb
    ].each do |relative_path|
      override_lines = File.readlines(Rails.root.join(relative_path)).grep(/stripe_version/)

      # Both files set the version on exactly one line, guarded inline. If a refactor spreads that
      # over several lines the count check fails on purpose: re-read the new shape and update this
      # spec deliberately rather than letting an unguarded override slip through.
      expect(override_lines.length).to eq(1),
                                       "expected #{relative_path} to set the scoped FX preview version on exactly one " \
                                       "line, found #{override_lines.length}"
      expect(override_lines.first).to include("StripeFxQuote::API_VERSION"),
                                      "expected #{relative_path} to use the shared pinned constant"
      expect(override_lines.first).to include("if stripe_fx_quote_id.present?"),
                                      "#{relative_path} sets the FX preview API version without checking for an FX " \
                                      "quote: #{override_lines.first.strip}"
    end
  end

  it "leaves a USD PaymentIntent on the stable API version" do
    captured = nil
    allow(Stripe::PaymentIntent).to receive(:create) do |_params, opts = {}|
      captured = opts
      Stripe::PaymentIntent.construct_from(id: "pi_no_quote", status: "requires_payment_method",
                                           client_secret: "pi_no_quote_secret")
    end

    StripeDeferredPaymentIntent.create(
      merchant_account: nil,
      amount_cents: 1_00,
      amount_for_gumroad_cents: 30,
      reference: "no-quote-reference",
      description: "Test product",
      idempotency_key: "no-quote-key",
      payment_method_types: ["card"],
      currency: "usd"
    )

    expect(captured).not_to have_key(:stripe_version)
  end
end
