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

  it "sends the preview version only from the FX quote and presentment PaymentIntent calls" do
    app_files = Dir[Rails.root.join("app/**/*.rb")] + Dir[Rails.root.join("lib/**/*.rb")] + Dir[Rails.root.join("config/**/*.rb")]
    senders = app_files.select { |path| File.read(path).match?(/stripe_version.*API_VERSION|API_VERSION.*stripe_version/) }

    expect(senders.map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }).to match_array(
      %w[
        app/business/payments/charging/implementations/stripe/stripe_fx_quote.rb
        app/business/payments/charging/implementations/stripe/stripe_deferred_payment_intent.rb
        app/business/payments/charging/implementations/stripe/stripe_charge_processor.rb
      ]
    )
  end

  it "guards each PaymentIntent override on an FX quote actually being present" do
    # The quote-creation call is unconditionally on the preview version (it *is* the preview
    # endpoint). The two PaymentIntent paths must only opt in when a quote id is attached.
    %w[
      app/business/payments/charging/implementations/stripe/stripe_deferred_payment_intent.rb
      app/business/payments/charging/implementations/stripe/stripe_charge_processor.rb
    ].each do |relative_path|
      override_lines = File.readlines(Rails.root.join(relative_path)).grep(/stripe_version\].*API_VERSION/)

      expect(override_lines).to be_present, "expected #{relative_path} to still set the scoped FX preview version"
      override_lines.each do |line|
        expect(line).to include("if stripe_fx_quote_id.present?"),
                        "#{relative_path} sets the FX preview API version without checking for an FX quote: #{line.strip}"
      end
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
