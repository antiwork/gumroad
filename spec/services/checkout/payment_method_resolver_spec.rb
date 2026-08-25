# frozen_string_literal: true

require "spec_helper"

describe Checkout::PaymentMethodResolver do
  let(:seller) { create(:user) }

  def resolve(sellers: [seller], buyer_country: "US", **opts)
    described_class.new(sellers:, buyer_country:, **opts).resolve
  end

  describe "#resolve" do
    context "with a single-seller, one-time, platform-account cart" do
      it "is client-confirm eligible with no fallback reason" do
        resolution = resolve

        expect(resolution.client_confirm_eligible?).to be(true)
        expect(resolution.fallback_reason).to be_nil
      end

      it "scopes Elements to the platform account" do
        expect(resolve.stripe_connect_account_id).to be_nil
      end

      it "resolves the full inline dynamic method set as eligible" do
        expect(resolve.eligible_payment_method_types)
          .to eq(%w[card link klarna afterpay_clearpay affirm ideal bancontact upi pix cashapp us_bank_account alipay])
      end

      it "enables the launched methods on Stripe for a US buyer, gating the rest behind later units" do
        resolution = resolve(buyer_country: "US")

        expect(resolution.payment_method_types).to eq(%w[card link cashapp])
        # The launched set is always a subset of the eligible policy set.
        expect(resolution.eligible_payment_method_types).to include(*resolution.payment_method_types)
      end

      it "keeps ACH Direct Debit launch-gated out even for a US buyer — withdrawn platform-wide because its ~4-business-day settlement delays content delivery (gumroad-private#1143)" do
        expect(resolve(buyer_country: "US").payment_method_types).not_to include("us_bank_account")
      end

      context "when the seller has opted back into ACH payments from the checkout settings page" do
        before { seller.update!(ach_payments_enabled: true) }

        it "re-adds ACH Direct Debit for a US buyer" do
          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card link cashapp us_bank_account])
        end

        it "still drops it for a non-US buyer — the opt-in never bypasses the US region lock" do
          expect(resolve(buyer_country: "GB").payment_method_types).to eq(%w[card link])
        end

        it "still drops it when the buyer country is unknown, failing safe" do
          expect(resolve(buyer_country: nil).payment_method_types).to eq(%w[card link])
        end

        it "keeps it on a PPP-discounted US checkout — ACH is region-locked, which the U13 matrix accepts" do
          expect(resolve(buyer_country: "US", ppp_discounted: true).payment_method_types).to eq(%w[card cashapp us_bank_account])
        end

        it "records ACH Direct Debit in the enabled payment methods" do
          allow(Rails.logger).to receive(:info)

          resolve(buyer_country: "US")

          expect(Rails.logger).to have_received(:info).with(
            a_string_matching(/buyer_country="US".*enabled=\["card", "link", "cashapp", "us_bank_account"\]/)
          )
        end
      end

      it "drops US-locked methods (Cash App/ACH) for a non-US buyer, keeping card and Link" do
        expect(resolve(buyer_country: "GB").payment_method_types).to eq(%w[card link])
      end

      it "drops US-locked methods when the buyer country is unknown, failing safe to card and Link" do
        expect(resolve(buyer_country: nil).payment_method_types).to eq(%w[card link])
      end

      it "launches Link with no per-seller flag — it auto-enables with the Payment Element" do
        expect(resolve.payment_method_types).to include("link")
      end

      it "still gates the remaining redirect methods behind later units" do
        expect(resolve.payment_method_types).not_to include("klarna", "afterpay_clearpay", "affirm", "ideal", "bancontact", "upi", "pix")
      end

      context "with the Klarna launch flag (checkout_local_method_klarna) active for the seller" do
        before { Feature.activate_user(:checkout_local_method_klarna, seller) }
        after { Feature.deactivate_user(:checkout_local_method_klarna, seller) }

        it "enables Klarna for a US buyer on a cart inside the USD amount window" do
          expect(resolve(buyer_country: "US", cart_total_usd_cents: 10_00).payment_method_types)
            .to eq(%w[card link cashapp klarna])
        end

        it "keeps the eligible policy set unchanged — the flag only widens the launched set" do
          expect(resolve(buyer_country: "US", cart_total_usd_cents: 10_00).eligible_payment_method_types)
            .to eq(%w[card link klarna afterpay_clearpay affirm ideal bancontact upi pix cashapp us_bank_account alipay])
        end

        it "drops Klarna for a non-US buyer — v1 offers it on the USD lane to US buyers only" do
          expect(resolve(buyer_country: "GB", cart_total_usd_cents: 10_00).payment_method_types)
            .to eq(%w[card link])
        end

        it "drops Klarna when the buyer country is unknown, failing safe" do
          expect(resolve(buyer_country: nil, cart_total_usd_cents: 10_00).payment_method_types)
            .to eq(%w[card link])
        end

        it "drops Klarna below Stripe's USD transaction floor" do
          expect(resolve(buyer_country: "US", cart_total_usd_cents: 99).payment_method_types)
            .not_to include("klarna")
        end

        it "offers Klarna at the window edges" do
          expect(resolve(buyer_country: "US", cart_total_usd_cents: 1_00).payment_method_types).to include("klarna")
          expect(resolve(buyer_country: "US", cart_total_usd_cents: 4_000_00).payment_method_types).to include("klarna")
        end

        it "drops Klarna above Stripe's USD transaction ceiling — fail eligibility closed rather than erroring at confirm" do
          expect(resolve(buyer_country: "US", cart_total_usd_cents: 4_000_01).payment_method_types)
            .not_to include("klarna")
        end

        it "drops Klarna when the cart total is unknown, failing safe" do
          expect(resolve(buyer_country: "US", cart_total_usd_cents: nil).payment_method_types)
            .not_to include("klarna")
        end

        it "drops Klarna from the eligible AND launched sets on recurring carts — memberships are excluded from v1" do
          resolution = resolve(buyer_country: "US", cart_total_usd_cents: 10_00, recurring: true)

          expect(resolution.eligible_payment_method_types).not_to include("klarna")
        end

        it "drops Klarna on PPP-discounted checkouts — no Stripe-owned funding country to verify pre-charge" do
          expect(resolve(buyer_country: "US", cart_total_usd_cents: 10_00, ppp_discounted: true).payment_method_types)
            .to eq(%w[card cashapp])
        end

        it "leaves card/Link/Cash App and the forced-currency methods exactly as before the flag" do
          expect(resolve(buyer_country: "US", cart_total_usd_cents: 10_00).payment_method_types)
            .to include("card", "link", "cashapp")
          expect(resolve(buyer_country: "US", cart_total_usd_cents: 10_00).payment_method_types)
            .not_to include("ideal", "bancontact", "upi", "afterpay_clearpay", "affirm")
        end

        context "when a forced-currency method surface is active (Stripe test mode, EUR cart)" do
          before do
            allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
            Feature.activate_user(:buyer_currency_charging, seller)
            Feature.activate_user(:buyer_local_currency, seller)
          end

          after do
            Feature.deactivate_user(:buyer_currency_charging, seller)
            Feature.deactivate_user(:buyer_local_currency, seller)
          end

          it "withholds Klarna whenever a forced-currency method survives — Klarna is vetted for USD intents only" do
            methods = resolve(buyer_country: "US", cart_product_currency: "eur", cart_total_usd_cents: 10_00).payment_method_types

            expect(methods).to include("ideal", "bancontact")
            expect(methods).not_to include("klarna")
          end
        end

        context "for a direct-charge (connect) seller" do
          let(:seller) { create(:user, check_merchant_account_is_linked: true) }
          let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }

          before do
            connect_account.update!(stripe_capabilities_snapshot: {
                                      "capabilities" => { "link_payments" => "active", "cashapp_payments" => "active", "klarna_payments" => "active" },
                                      "refreshed_at" => Time.current.iso8601,
                                    })
          end

          it "offers Klarna when the connected account is US-based with an active klarna_payments capability" do
            expect(resolve(buyer_country: "US", cart_total_usd_cents: 10_00).payment_method_types).to include("klarna")
          end

          it "drops Klarna when the connected account is not US-based even with the capability active — Stripe's cross-border rule would fail the entire intent create (the gumroad-private#1026 failure mode)" do
            connect_account.update!(country: "DE")

            expect(resolve(buyer_country: "US", cart_total_usd_cents: 10_00).payment_method_types).not_to include("klarna")
          end

          it "drops Klarna when the account's klarna_payments capability is not active" do
            connect_account.update!(stripe_capabilities_snapshot: {
                                      "capabilities" => { "link_payments" => "active", "cashapp_payments" => "active" },
                                      "refreshed_at" => Time.current.iso8601,
                                    })

            expect(resolve(buyer_country: "US", cart_total_usd_cents: 10_00).payment_method_types).not_to include("klarna")
          end
        end
      end

      it "keeps Klarna off without its launch flag even for an eligible US cart — the 0% default" do
        expect(resolve(buyer_country: "US", cart_total_usd_cents: 10_00).payment_method_types)
          .to eq(%w[card link cashapp])
      end

      context "with the Alipay launch flag (checkout_local_method_alipay) active for the seller" do
        before { Feature.activate_user(:checkout_local_method_alipay, seller) }
        after { Feature.deactivate_user(:checkout_local_method_alipay, seller) }

        it "enables Alipay on the canonical-USD lane for a US buyer" do
          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card link cashapp alipay])
        end

        it "keeps the eligible policy set unchanged — the flag only widens the launched set" do
          expect(resolve(buyer_country: "US").eligible_payment_method_types)
            .to eq(%w[card link klarna afterpay_clearpay affirm ideal bancontact upi pix cashapp us_bank_account alipay])
        end

        it "offers Alipay to a non-US buyer — unlike Klarna it carries no buyer-country lock, and most of the target cohort buys from outside mainland China" do
          expect(resolve(buyer_country: "HK").payment_method_types).to eq(%w[card link alipay])
        end

        it "offers Alipay when the buyer country is unknown — there is no region lock to fail closed on" do
          expect(resolve(buyer_country: nil).payment_method_types).to eq(%w[card link alipay])
        end

        it "offers Alipay regardless of cart total — Stripe publishes no Alipay transaction window to fail closed on" do
          expect(resolve(buyer_country: "US", cart_total_usd_cents: 1).payment_method_types).to include("alipay")
          expect(resolve(buyer_country: "US", cart_total_usd_cents: 100_000_00).payment_method_types).to include("alipay")
          expect(resolve(buyer_country: "US", cart_total_usd_cents: nil).payment_method_types).to include("alipay")
        end

        it "drops Alipay from the eligible set on recurring carts — memberships are out of scope for the first launch" do
          resolution = resolve(buyer_country: "US", recurring: true)

          expect(resolution.eligible_payment_method_types).not_to include("alipay")
        end

        it "drops Alipay on PPP-discounted checkouts — the wallet exposes no funding country to verify pre-charge" do
          expect(resolve(buyer_country: "US", ppp_discounted: true).payment_method_types).to eq(%w[card cashapp])
        end

        it "leaves every other method exactly as it was before the flag" do
          methods = resolve(buyer_country: "US").payment_method_types

          expect(methods).to include("card", "link", "cashapp")
          expect(methods).not_to include("klarna", "ideal", "bancontact", "upi", "afterpay_clearpay", "affirm", "us_bank_account")
        end

        context "when a forced-currency method surface is active (Stripe test mode, EUR cart)" do
          before do
            allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
            Feature.activate_user(:buyer_currency_charging, seller)
            Feature.activate_user(:buyer_local_currency, seller)
          end

          after do
            Feature.deactivate_user(:buyer_currency_charging, seller)
            Feature.deactivate_user(:buyer_local_currency, seller)
          end

          it "withholds Alipay whenever a forced-currency method survives — Alipay is vetted for USD intents only, and an entry Stripe rejects fails the whole intent create" do
            methods = resolve(buyer_country: "US", cart_product_currency: "eur").payment_method_types

            expect(methods).to include("ideal", "bancontact")
            expect(methods).not_to include("alipay")
          end
        end

        context "for a direct-charge (connect) seller" do
          let(:seller) { create(:user, check_merchant_account_is_linked: true) }
          let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }

          before do
            connect_account.update!(stripe_capabilities_snapshot: {
                                      "capabilities" => { "link_payments" => "active", "alipay_payments" => "active" },
                                      "refreshed_at" => Time.current.iso8601,
                                    })
          end

          it "offers Alipay when the connected account has an active alipay_payments capability" do
            expect(resolve(buyer_country: "US").payment_method_types).to include("alipay")
          end

          it "drops Alipay on a non-US connected account — this lane's intents are USD and Stripe only allows USD Alipay on US-based accounts, so the entry would fail the whole intent create" do
            connect_account.update!(country: "DE")

            expect(resolve(buyer_country: "US").payment_method_types).not_to include("alipay")
          end

          it "drops Alipay when the connected account's country is unknown — fails closed" do
            connect_account.update!(country: nil)

            expect(resolve(buyer_country: "US").payment_method_types).not_to include("alipay")
          end

          it "drops Alipay when the account's alipay_payments capability is not active — a connected account that never enabled Alipay must never see it listed" do
            connect_account.update!(stripe_capabilities_snapshot: {
                                      "capabilities" => { "link_payments" => "active" },
                                      "refreshed_at" => Time.current.iso8601,
                                    })

            expect(resolve(buyer_country: "US").payment_method_types).not_to include("alipay")
          end
        end
      end

      it "keeps Alipay off without its launch flag even for an eligible cart — the 0% default" do
        expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card link cashapp])
      end

      context "with the internal buyer-currency flags enabled in Stripe test mode" do
        let(:platform_merchant_account) { MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) }

        before do
          allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
          Feature.activate_user(:buyer_currency_charging, seller)
          Feature.activate_user(:buyer_local_currency, seller)
        end

        it "surfaces the EUR forced-currency methods for manual presentment QA when the cart is priced in EUR" do
          expect(resolve(cart_product_currency: "eur").payment_method_types).to include("ideal", "bancontact")
        end

        it "surfaces UPI for manual presentment QA only for Indian buyers when the cart is priced in INR" do
          expect(resolve(buyer_country: "IN", cart_product_currency: "inr").payment_method_types).to include("upi")
          expect(resolve(buyer_country: "GB", cart_product_currency: "inr").payment_method_types).not_to include("upi")
          expect(resolve(buyer_country: nil, cart_product_currency: "inr").payment_method_types).not_to include("upi")
        end

        it "still surfaces UPI when the seller has turned off buyer-local-currency display" do
          seller.update!(disable_buyer_local_currency: true)

          expect(resolve(buyer_country: "IN", cart_product_currency: "inr").payment_method_types).to include("upi")
        end

        it "keeps them off a USD-priced cart — Stripe rejects an element/intent listing EUR-only methods in USD" do
          expect(resolve(cart_product_currency: "usd").payment_method_types).not_to include("ideal", "bancontact")
        end

        it "keeps them off when the cart currency is unknown (multi-item carts pass nil), failing safe" do
          expect(resolve(cart_product_currency: nil).payment_method_types).not_to include("ideal", "bancontact")
        end

        it "keeps them out when the buyer-currency charging flag is off" do
          Feature.deactivate_user(:buyer_currency_charging, seller)

          expect(resolve(cart_product_currency: "eur").payment_method_types).not_to include("ideal", "bancontact")
        end

        it "keeps them out of live mode without the per-method launch flags" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)

          expect(resolve(cart_product_currency: "eur").payment_method_types).not_to include("ideal", "bancontact")
        end

        it "launches iDEAL in live mode when its per-method launch flag is on, without pulling Bancontact along" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_ideal, seller)

          methods = resolve(cart_product_currency: "eur").payment_method_types
          expect(methods).to include("ideal")
          expect(methods).not_to include("bancontact")
        end

        it "launches Bancontact in live mode when its per-method launch flag is on, without pulling iDEAL along" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_bancontact, seller)

          methods = resolve(cart_product_currency: "eur").payment_method_types
          expect(methods).to include("bancontact")
          expect(methods).not_to include("ideal")
        end

        # Regression test for the 2026-07-23 iDEAL dark-ramp (gumroad-private#933): the
        # EUR mismatch marker is the expected steady state once iDEAL/SEPA capabilities
        # make the account settle EUR in EUR, and the resolver only offers these methods
        # on carts priced in the forced currency (no FX quote involved) — so the marker
        # must not hide the method tab.
        it "keeps a launched forced-currency method offered when the charged account has learned a mismatch for that currency" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_ideal, seller)
          platform_merchant_account.record_settlement_currency_mismatch!(Currency::EUR)

          expect(resolve(cart_product_currency: Currency::EUR).payment_method_types).to include("ideal")
        end

        it "keeps a launched forced-currency method offered when the charged account holds a non-USD balance" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_ideal, seller)
          platform_merchant_account.update!(currency: Currency::CAD)

          expect(resolve(cart_product_currency: Currency::EUR).payment_method_types).to include("ideal")
        end

        # gumroad-private#1409: a seller who is not a Stripe Connect seller is charged
        # with a DESTINATION charge — the intent is created on the Gumroad platform
        # account and their own account only receives the transfer.
        it "offers a launched forced-currency method to a destination-charge seller whose own account settles in a non-USD currency" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_upi, seller)
          create(:merchant_account, user: seller, charge_processor_id: StripeChargeProcessor.charge_processor_id, currency: Currency::GBP, country: "GB")

          expect(resolve(buyer_country: "IN", cart_product_currency: "inr").payment_method_types).to include("upi")
        end

        # gumroad-private#1442. Most eurozone sellers settle in euros, and the old gate
        # required the charging account to hold US dollars — which withheld iDEAL and
        # Bancontact from exactly the sellers they exist for. The cart is priced in the
        # method's forced currency, so the charge is the listed price with no FX quote:
        # a EUR intent on a EUR-settling account is the simplest case Stripe supports.
        it "offers a launched forced-currency method to a DIRECT-charge (Stripe Connect) seller whose own account settles in that same currency" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          connect_seller = create(:user, check_merchant_account_is_linked: true)
          connect_account = create(:merchant_account_stripe_connect, user: connect_seller, currency: Currency::EUR, country: "BE")
          connect_account.update!(stripe_capabilities_snapshot: { "capabilities" => { "ideal_payments" => "active" }, "refreshed_at" => Time.current.iso8601 })
          Feature.activate_user(:buyer_currency_charging, connect_seller)
          Feature.activate_user(:buyer_local_currency, connect_seller)
          Feature.activate_user(:checkout_local_method_ideal, connect_seller)

          expect(resolve(sellers: [connect_seller], cart_product_currency: Currency::EUR).payment_method_types).to include("ideal")
        end

        # The per-account capability snapshot, not a settlement-currency rule, is what
        # keeps a method off an account that cannot take it. Listing a method the account
        # has not activated fails the ENTIRE intent create, card included
        # (gumroad-private#1026), so this gate has to keep holding after the settlement
        # gate is gone.
        it "still withholds a launched forced-currency method from a Stripe Connect seller whose account has not activated it" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          connect_seller = create(:user, check_merchant_account_is_linked: true)
          connect_account = create(:merchant_account_stripe_connect, user: connect_seller, currency: Currency::EUR, country: "BE")
          connect_account.update!(stripe_capabilities_snapshot: { "capabilities" => { "ideal_payments" => "inactive" }, "refreshed_at" => Time.current.iso8601 })
          Feature.activate_user(:buyer_currency_charging, connect_seller)
          Feature.activate_user(:buyer_local_currency, connect_seller)
          Feature.activate_user(:checkout_local_method_ideal, connect_seller)

          expect(resolve(sellers: [connect_seller], cart_product_currency: Currency::EUR).payment_method_types).not_to include("ideal")
        end

        it "keeps a launched forced-currency method when the charged account's mismatch is for another currency" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_ideal, seller)
          platform_merchant_account.record_settlement_currency_mismatch!(Currency::GBP)

          expect(resolve(cart_product_currency: Currency::EUR).payment_method_types).to include("ideal")
        end

        it "launches UPI in live mode when its per-method launch flag is on for an Indian buyer, without pulling EUR methods along" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_upi, seller)

          methods = resolve(buyer_country: "IN", cart_product_currency: "inr").payment_method_types
          expect(methods).to include("upi")
          expect(methods).not_to include("ideal", "bancontact")
        end

        it "keeps launched UPI off non-India buyers even when the cart is priced in INR" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_upi, seller)

          expect(resolve(buyer_country: "US", cart_product_currency: "inr").payment_method_types).not_to include("upi")
        end

        it "retains launched UPI on a PPP-discounted INR checkout from India — region-locked methods pass the U13 matrix" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_upi, seller)

          expect(resolve(buyer_country: "IN", cart_product_currency: "inr", ppp_discounted: true).payment_method_types).to include("upi")
        end

        it "launches Pix in live mode when its per-method launch flag is on for a Brazilian buyer, without pulling other local methods along" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_pix, seller)

          methods = resolve(buyer_country: "BR", cart_product_currency: "brl").payment_method_types
          expect(methods).to include("pix")
          expect(methods).not_to include("ideal", "bancontact", "upi")
        end

        it "keeps launched Pix off non-Brazil buyers even when the cart is priced in BRL" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_pix, seller)

          expect(resolve(buyer_country: "US", cart_product_currency: "brl").payment_method_types).not_to include("pix")
        end

        it "keeps launched Pix off a Brazilian buyer whose cart is not priced in BRL — Stripe only accepts Pix on BRL intents" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_pix, seller)

          expect(resolve(buyer_country: "BR", cart_product_currency: "usd").payment_method_types).not_to include("pix")
        end

        it "keeps Pix off a BRL cart from Brazil while its launch flag is off, even with other local methods launched" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_upi, seller)

          expect(resolve(buyer_country: "BR", cart_product_currency: "brl").payment_method_types).not_to include("pix")
        end

        it "retains launched Pix on a PPP-discounted BRL checkout from Brazil — region-locked methods pass the U13 matrix" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_pix, seller)

          expect(resolve(buyer_country: "BR", cart_product_currency: "brl", ppp_discounted: true).payment_method_types).to include("pix")
        end

        it "never offers Pix on a recurring cart — Pix is buyer-present, one-time only" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_pix, seller)

          resolution = resolve(buyer_country: "BR", cart_product_currency: "brl", recurring: true)
          expect(resolution.eligible_payment_method_types).not_to include("pix")
        end

        it "keeps a launched method off carts not priced in its forced currency, even in live mode" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_ideal, seller)

          expect(resolve(cart_product_currency: "usd").payment_method_types).not_to include("ideal")
        end

        it "still requires the buyer-currency seller flags in live mode with a launch flag on" do
          allow(Checkout::BuyerCurrencyEligibility).to receive(:stripe_test_mode?).and_return(false)
          Feature.activate_user(:checkout_local_method_ideal, seller)
          Feature.deactivate_user(:buyer_currency_charging, seller)

          expect(resolve(cart_product_currency: "eur").payment_method_types).not_to include("ideal")
        end

        it "still offers forced-currency methods when the seller opted out of buyer-local-currency display" do
          seller.update!(disable_buyer_local_currency: true)

          expect(resolve(cart_product_currency: "eur").payment_method_types).to include("ideal", "bancontact")
        end
      end

      it "returns an explicit list of method-type strings, never Stripe's automatic_payment_methods shape" do
        expect(resolve.payment_method_types).to be_an(Array).and(all(be_a(String)))
      end

      context "with a PPP-discounted checkout (U13 method matrix)" do
        it "keeps card and the US-locked methods for a US buyer — verifiable + region-matched" do
          expect(resolve(ppp_discounted: true).payment_method_types).to eq(%w[card cashapp])
        end

        it "resolves card-only for a non-US PPP buyer (region-locked methods already dropped)" do
          expect(resolve(buyer_country: "BR", ppp_discounted: true).payment_method_types).to eq(["card"])
        end

        it "gates Link out — no Stripe-owned funding country to verify pre-charge" do
          expect(resolve(ppp_discounted: true).payment_method_types).to eq(%w[card cashapp])
          expect(resolve(ppp_discounted: false).payment_method_types).to eq(%w[card link cashapp])
        end

        it "logs the PPP gate input" do
          resolver = described_class.new(sellers: [seller], buyer_country: "US", ppp_discounted: true)
          allow(Rails.logger).to receive(:info)

          resolver.resolve

          expect(Rails.logger).to have_received(:info).with(a_string_matching(/ppp_discounted=true/))
        end
      end
    end

    context "with a recurring (subscription) lifecycle" do
      it "disables Afterpay/Clearpay, Affirm, and UPI in the eligible set — none support recurring or off-session collection" do
        eligible = resolve(recurring: true).eligible_payment_method_types

        expect(eligible).not_to include("afterpay_clearpay", "affirm", "upi")
        expect(eligible).to include("card", "link")
      end

      # A euro-priced membership must never claim iDEAL or Bancontact: both are single bank
      # approvals, and collecting renewals off them would need a SEPA Direct Debit mandate
      # checkout doesn't ask for. Recurring carts fall back to Lane A before a Stripe method
      # list is built, so this only shows up in the logged eligible-policy set today — but that
      # set is what later units intersect with, so it must not claim a method that can't renew.
      it "disables the EUR bank methods on recurring carts — a membership can't be renewed off a one-shot bank approval" do
        eligible = resolve(recurring: true).eligible_payment_method_types

        expect(eligible).not_to include("ideal", "bancontact")
      end

      it "keeps a launched Bancontact off a recurring EUR cart entirely" do
        Feature.activate_user(:buyer_currency_charging, seller)
        Feature.activate_user(:buyer_local_currency, seller)
        Feature.activate_user(:checkout_local_method_bancontact, seller)

        resolution = resolve(recurring: true, cart_product_currency: "eur")

        expect(resolution.eligible_payment_method_types).not_to include("bancontact")
        expect(resolution.payment_method_types).to be_nil
      end

      it "stays on Lane A because subscription setup on the client-confirmed path is deferred" do
        resolution = resolve(recurring: true)

        expect(resolution.client_confirm_eligible?).to be(false)
        expect(resolution.fallback_reason).to eq("recurring_charge")
        expect(resolution.payment_method_types).to be_nil
      end

      context "with the narrow UPI Autopay registration shape" do
        before do
          allow(Stripe).to receive(:api_key).and_return("sk_test_upi_autopay")
          Feature.activate_user(:buyer_currency_charging, seller)
          Feature.activate_user(:buyer_local_currency, seller)
          Feature.activate(described_class::UPI_RECURRING_SERVICING_FEATURE)
          Feature.activate_user(described_class::UPI_RECURRING_LAUNCH_FEATURE, seller)
        end

        after do
          Feature.deactivate_user(:buyer_currency_charging, seller)
          Feature.deactivate_user(:buyer_local_currency, seller)
          Feature.deactivate(described_class::UPI_RECURRING_SERVICING_FEATURE)
          Feature.deactivate_user(described_class::UPI_RECURRING_LAUNCH_FEATURE, seller)
        end

        it "enables exactly card and UPI for an Indian buyer on an INR cart" do
          resolution = resolve(
            recurring: true,
            recurring_upi_registration: true,
            buyer_country: "IN",
            cart_product_currency: Currency::INR
          )

          expect(resolution.client_confirm_eligible?).to be(true)
          expect(resolution.eligible_payment_method_types).to eq(%w[card upi])
          expect(resolution.payment_method_types).to eq(%w[card upi])
        end

        it "falls back to the existing card lane when UPI does not survive the buyer-country gate" do
          resolution = resolve(
            recurring: true,
            recurring_upi_registration: true,
            buyer_country: "US",
            cart_product_currency: Currency::INR
          )

          expect(resolution.client_confirm_eligible?).to be(false)
          expect(resolution.fallback_reason).to eq("recurring_upi_unavailable")
          expect(resolution.payment_method_types).to be_nil
        end

        it "requires the dedicated recurring acquisition flag even in Stripe test mode" do
          Feature.deactivate_user(described_class::UPI_RECURRING_LAUNCH_FEATURE, seller)

          resolution = resolve(
            recurring: true,
            recurring_upi_registration: true,
            buyer_country: "IN",
            cart_product_currency: Currency::INR
          )

          expect(resolution.client_confirm_eligible?).to be(false)
          expect(resolution.fallback_reason).to eq("recurring_upi_unavailable")
        end

        it "requires renewal servicing to be active before acquisition" do
          Feature.deactivate(described_class::UPI_RECURRING_SERVICING_FEATURE)

          resolution = resolve(
            recurring: true,
            recurring_upi_registration: true,
            buyer_country: "IN",
            cart_product_currency: Currency::INR
          )

          expect(resolution.client_confirm_eligible?).to be(false)
          expect(resolution.fallback_reason).to eq("recurring_upi_unavailable")
        end
      end
    end

    context "with a multi-seller cart" do
      let(:other_seller) { create(:user) }

      it "resolves to card + PayPal only and keeps the cart on Lane A" do
        resolution = resolve(sellers: [seller, other_seller])

        expect(resolution.client_confirm_eligible?).to be(false)
        expect(resolution.fallback_reason).to eq("multi_seller")
        expect(resolution.eligible_payment_method_types).to eq(%w[card paypal])
        expect(resolution.payment_method_types).to be_nil
        expect(resolution.stripe_connect_account_id).to be_nil
      end
    end

    context "with a connected-account (direct-charge) seller" do
      let(:seller) { create(:user, check_merchant_account_is_linked: true) }
      let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }

      it "is client-confirm eligible with Elements scoped to the connected account" do
        resolution = resolve

        expect(resolution.client_confirm_eligible?).to be(true)
        expect(resolution.fallback_reason).to be_nil
        expect(resolution.stripe_connect_account_id).to eq(connect_account.charge_processor_merchant_id)
      end

      context "when the account has no availability snapshot yet" do
        it "fails safe to card only for a US buyer and enqueues a background refresh — even Link waits for the snapshot, since link_payments is absent on many connected accounts and listing it fails the intent create" do
          expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).to receive(:perform_async).with(connect_account.id)

          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card])
        end

        it "resolves card only for a non-US buyer too" do
          expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).to receive(:perform_async).with(connect_account.id)

          expect(resolve(buyer_country: "GB").payment_method_types).to eq(%w[card])
        end

        it "keeps the checkout render alive when the refresh enqueue itself fails — the refresh is best-effort" do
          expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).to receive(:perform_async).and_raise(RedisClient::CannotConnectError)

          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card])
        end
      end

      context "when the snapshot is older than SNAPSHOT_MAX_AGE" do
        before do
          connect_account.update!(stripe_capabilities_snapshot: {
                                    "capabilities" => { "link_payments" => "active", "cashapp_payments" => "active", "us_bank_account_ach_payments" => "active" },
                                    "refreshed_at" => (StripeConnectPaymentMethodAvailabilityService::SNAPSHOT_MAX_AGE + 1.hour).ago.iso8601,
                                  })
        end

        it "still uses the stale snapshot (checkout never blocks) but enqueues a background re-fetch — the self-heal for webhooks dropped by the worker's until_executed lock" do
          expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).to receive(:perform_async).with(connect_account.id)

          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card link cashapp])
        end
      end

      context "when the snapshot says the account accepts both US-locked methods" do
        before do
          connect_account.update!(stripe_capabilities_snapshot: {
                                    "capabilities" => { "link_payments" => "active", "cashapp_payments" => "active", "us_bank_account_ach_payments" => "active" },
                                    "refreshed_at" => Time.current.iso8601,
                                  })
        end

        it "offers Cash App Pay to a US buyer without enqueueing a refresh — an active ACH capability does not re-add the launch-gated method" do
          expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).not_to receive(:perform_async)

          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card link cashapp])
        end

        it "re-adds ACH for a US buyer when the seller has opted in — the account's capability snapshot permits it" do
          seller.update!(ach_payments_enabled: true)

          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card link cashapp us_bank_account])
        end

        it "still drops them for a non-US buyer — our region policy applies regardless of the account's capabilities" do
          expect(resolve(buyer_country: "GB").payment_method_types).to eq(%w[card link])
        end
      end

      context "when the snapshot says the account accepts only Cash App Pay" do
        before do
          connect_account.update!(stripe_capabilities_snapshot: {
                                    "capabilities" => { "link_payments" => "active", "cashapp_payments" => "active", "us_bank_account_ach_payments" => "inactive" },
                                    "refreshed_at" => Time.current.iso8601,
                                  })
        end

        it "offers exactly the accepted method to a US buyer" do
          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card link cashapp])
        end

        it "keeps ACH out even for an opted-in seller — the opt-in never overrides the account's capabilities" do
          seller.update!(ach_payments_enabled: true)

          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card link cashapp])
        end
      end

      context "when the snapshot says the account's Link capability is not active" do
        before do
          connect_account.update!(stripe_capabilities_snapshot: {
                                    "capabilities" => { "cashapp_payments" => "active" },
                                    "refreshed_at" => Time.current.iso8601,
                                  })
        end

        it "drops Link too — the capability intersection covers every method, not just the US-locked pair" do
          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card cashapp])
        end
      end

      context "when the snapshot says the account accepts neither US-locked method" do
        before do
          connect_account.update!(stripe_capabilities_snapshot: {
                                    "capabilities" => { "card_payments" => "active", "link_payments" => "active" },
                                    "refreshed_at" => Time.current.iso8601,
                                  })
        end

        it "resolves card and Link for a US buyer without enqueueing a refresh — the empty snapshot is an answer, not a miss" do
          expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).not_to receive(:perform_async)

          expect(resolve(buyer_country: "US").payment_method_types).to eq(%w[card link])
        end

        it "resolves card-only for a US PPP buyer — Link is PPP-gated and the account accepts no US-locked methods" do
          expect(resolve(buyer_country: "US", ppp_discounted: true).payment_method_types).to eq(["card"])
        end
      end

      it "drops US-locked methods for a non-US buyer while keeping the connected-account scope" do
        connect_account.update!(stripe_capabilities_snapshot: {
                                  "capabilities" => { "link_payments" => "active", "cashapp_payments" => "active", "us_bank_account_ach_payments" => "active" },
                                  "refreshed_at" => Time.current.iso8601,
                                })

        resolution = resolve(buyer_country: "GB")

        expect(resolution.stripe_connect_account_id).to eq(connect_account.charge_processor_merchant_id)
        expect(resolution.payment_method_types).to eq(%w[card link])
      end

      it "falls back to Lane A when the connected account has no Charge Processor Merchant ID" do
        connect_account.update_column(:charge_processor_merchant_id, nil)

        resolution = resolve

        expect(resolution.client_confirm_eligible?).to be(false)
        expect(resolution.fallback_reason).to eq("direct_charge_account_unlinked")
        expect(resolution.stripe_connect_account_id).to be_nil
        expect(resolution.payment_method_types).to be_nil
      end
    end

    context "with a seller who has a connect account but charges routed to Gumroad" do
      let(:seller) { create(:user, check_merchant_account_is_linked: false) }
      before { create(:merchant_account_stripe_connect, user: seller) }

      it "is client-confirm eligible with platform-scoped Elements, matching the charge routing" do
        resolution = resolve

        expect(resolution.client_confirm_eligible?).to be(true)
        expect(resolution.stripe_connect_account_id).to be_nil
        expect(resolution.payment_method_types).to eq(%w[card link cashapp])
      end
    end

    context "with a commission product" do
      it "keeps the cart on Lane A" do
        resolution = resolve(commission: true)

        expect(resolution.client_confirm_eligible?).to be(false)
        expect(resolution.fallback_reason).to eq("commission")
      end
    end

    context "with a future-charge setup cart (preorder / free trial)" do
      it "keeps the cart on Lane A" do
        resolution = resolve(setup_for_future: true)

        expect(resolution.client_confirm_eligible?).to be(false)
        expect(resolution.fallback_reason).to eq("setup_flow")
      end
    end

    it "logs the decision with enough detail to explain why a buyer saw a method" do
      resolver = described_class.new(sellers: [seller])
      allow(Rails.logger).to receive(:info)

      resolver.resolve

      expect(Rails.logger).to have_received(:info).with(
        a_string_matching(/client_confirm_eligible=true.*enabled=\["card", "link"\].*launch_gated_out=.*stripe_connect_account_id=nil/)
      )
    end

    it "logs the buyer country and the US-locked method launch for a US buyer" do
      resolver = described_class.new(sellers: [seller], buyer_country: "US")
      allow(Rails.logger).to receive(:info)

      resolver.resolve

      expect(Rails.logger).to have_received(:info).with(
        a_string_matching(/buyer_country="US".*enabled=\["card", "link", "cashapp"\]/)
      )
    end

    it "memoizes so the decision is logged once per resolver" do
      resolver = described_class.new(sellers: [seller])
      allow(Rails.logger).to receive(:info)

      2.times { resolver.resolve }

      expect(Rails.logger).to have_received(:info).with(a_string_matching(/\[Checkout::PaymentMethodResolver\]/)).once
    end
  end
end
