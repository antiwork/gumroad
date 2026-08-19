# frozen_string_literal: true

require "spec_helper"

describe StripeMerchantAccountManager, :vcr do
  include StripeMerchantAccountHelper

  API_VERSION = Stripe.api_version

  let(:user) { create(:user, unpaid_balance_cents: 10, email: "chuck@gum.com", username: "chuck") }

  describe "#create_account" do
    describe "all info provided of an individual" do
      let(:user_compliance_info) { create(:user_compliance_info, user:) }
      let(:bank_account) { create(:ach_account_stripe_succeed, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          country: "US",
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "San Francisco",
              state: "California",
              postal_code: "94107",
              country: "US"
            },
            id_number: "000000000",
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          default_currency: "usd",
          bank_account: {
            country: "US",
            currency: "usd",
            routing_number: "110000000",
            account_number: "000123456789"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params" do
        allow_any_instance_of(User).to receive(:external_id).and_return("4585558742839")
        allow_any_instance_of(UserComplianceInfo).to receive(:external_id).and_return("G_-mnBf9b1j9A7a4ub4nFQ==")
        allow_any_instance_of(TosAgreement).to receive(:external_id).and_return("G_-mnBf9b1j9A7a4ub4nFQ==")
        allow_any_instance_of(BankAccount).to receive(:external_id).and_return("G_-mnBf9b1j9A7a4ub4nFQ==")
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original
        merchant_account = subject.create_account(user, passphrase: "1234")
        stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
        expect(stripe_account["metadata"]["user_id"]).to eq(user.external_id)
        expect(stripe_account["metadata"]["user_compliance_info_id"]).to eq(user_compliance_info.external_id)
        expect(stripe_account["metadata"]["tos_agreement_id"]).to eq(tos_agreement.external_id)
        expect(stripe_account["metadata"]["bank_account_id"]).to eq(bank_account.external_id)
      end

      it "returns a merchant account" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
      end

      it "returns a merchant account with country set" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.country).to eq("US")
      end

      it "returns a merchant account with currency set" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.currency).to eq("usd")
      end

      it "saves the stripe connect account id on our bank account record" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
      end

      it "saves the stripe bank account id on our bank account record" do
        subject.create_account(user, passphrase: "1234")
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
      end

      it "saves the stripe bank account fingerprint on our bank account record" do
        subject.create_account(user, passphrase: "1234")
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end

      it "raises the Stripe::InvalidRequestError" do
        error_message = "Invalid account number: must contain only digits, and be at most 12 digits long"
        allow(Stripe::Account).to receive(:create).and_raise(Stripe::InvalidRequestError.new(error_message, nil))
        expect do
          subject.create_account(user, passphrase: "1234")
        end.to raise_error(Stripe::InvalidRequestError)
      end

      it "cleans up the merchant account when onboarding is interrupted by a non-Stripe error" do
        allow(Stripe::Account).to receive(:create).and_raise(Timeout::Error.new("execution expired"))
        expect do
          subject.create_account(user, passphrase: "1234")
        end.to raise_error(Timeout::Error)

        merchant_account = user.merchant_accounts.stripe.last
        expect(merchant_account).to be_present
        expect(merchant_account.alive?).to be(false)
      end

      it "keeps an already-alive account when a later step fails" do
        allow(described_class).to receive(:save_stripe_bank_account_info).and_raise(StandardError.new("bank sync failed"))
        expect do
          subject.create_account(user, passphrase: "1234")
        end.to raise_error(StandardError, "bank sync failed")

        merchant_account = user.merchant_accounts.stripe.last
        expect(merchant_account.charge_processor_alive_at).to be_present
        expect(merchant_account.alive?).to be(true)
        expect(merchant_account.charge_processor_merchant_id).to be_present
      end

      context "when user compliance info contains whitespaces" do
        let(:user_compliance_info) do
          create(:user_compliance_info,
                 user:,
                 first_name: "  Chuck  ",
                 last_name: "  Bartowski  ",
                 street_address: " address_full_match",
                 zip_code: " 94107 ",
                 city: "San Francisco ")
        end

        it "strips out params whitespaces" do
          expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original
          merchant_account = subject.create_account(user, passphrase: "1234")
          expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
          expect(merchant_account.charge_processor_merchant_id).to be_present
        end
      end

      context "with stripe connect account" do
        before do
          allow_any_instance_of(MerchantAccount).to receive(:is_a_stripe_connect_account?).and_return(true)
        end

        it "generates default abandoned cart workflow" do
          expect(DefaultAbandonedCartWorkflowGeneratorService).to receive(:new).with(seller: user).and_call_original
          expect_any_instance_of(DefaultAbandonedCartWorkflowGeneratorService).to receive(:generate)
          subject.create_account(user, passphrase: "1234")
        end
      end

      context "with non-connect account" do
        before do
          allow_any_instance_of(MerchantAccount).to receive(:is_a_stripe_connect_account?).and_return(false)
        end

        it "does not generate abandoned cart workflow" do
          expect(DefaultAbandonedCartWorkflowGeneratorService).not_to receive(:new)
          subject.create_account(user, passphrase: "1234")
        end
      end
    end

    describe "all info provided of an individual with a US Debit card" do
      let(:user_compliance_info) { create(:user_compliance_info, user:) }
      let(:bank_account) { create(:card_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id
          },
          country: "US",
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "San Francisco",
              state: "California",
              postal_code: "94107",
              country: "US"
            },
            id_number: "000000000",
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          default_currency: "usd",
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      let(:expected_bank_account_params) do
        {
          metadata: {
            bank_account_id: bank_account.external_id
          },
          bank_account: /^tok_/,
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          }
        }
      end

      it "creates an account at stripe with all the account params" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original
        subject.create_account(user, passphrase: "1234")
      end

      it "returns a merchant account" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
      end

      it "returns a merchant account with country set" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.country).to eq("US")
      end

      it "returns a merchant account with currency set" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.currency).to eq("usd")
      end
    end

    describe "all info provided of an individual but their bank account doesn't match the default currency of the country" do
      before do
        allow(Rails.env).to receive(:production?).and_return(true)
      end

      let(:user_compliance_info) { create(:user_compliance_info, user:, country: "Canada") }
      let(:bank_account) { create(:ach_account_stripe_succeed, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      it "raises an error" do
        expect { subject.create_account(user, passphrase: "1234") }.to raise_error(MerchantRegistrationUserNotReadyError)
      end
    end

    describe "all info provided of an individual and empty string business fields" do
      let(:user_compliance_info) { create(:user_compliance_info, user:, business_name: "", business_tax_id: "") }
      let(:bank_account) { create(:ach_account_stripe_succeed, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          country: "US",
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          business_type: "individual",
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "San Francisco",
              state: "California",
              postal_code: "94107",
              country: "US"
            },
            id_number: "000000000",
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          default_currency: "usd",
          bank_account: {
            country: "US",
            currency: "usd",
            routing_number: "110000000",
            account_number: "000123456789"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original
        subject.create_account(user, passphrase: "1234")
      end

      it "returns a merchant account" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
      end

      it "returns a merchant account with country set" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.country).to eq("US")
      end

      it "returns a merchant account with currency set" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.currency).to eq("usd")
      end

      it "saves the stripe connect account id on our bank account record" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
      end

      it "saves the stripe bank account id on our bank account record" do
        subject.create_account(user, passphrase: "1234")
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
      end

      it "saves the stripe bank account fingerprint on our bank account record" do
        subject.create_account(user, passphrase: "1234")
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a business" do
      let(:user_compliance_info) { create(:user_compliance_info_business, user:) }
      let(:bank_account) { create(:ach_account_stripe_succeed, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          country: "US",
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          business_type: "company",
          company: {
            name: "Buy More, LLC",
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Burbank",
              state: "California",
              postal_code: "91506",
              country: "US"
            },
            tax_id: "000000000",
            phone: "0000000000",
            directors_provided: true,
            executives_provided: true
          },
          default_currency: "usd",
          bank_account: {
            country: "US",
            currency: "usd",
            routing_number: "110000000",
            account_number: "000123456789"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      let(:expected_person_params) do
        {
          address: {
            line1: "address_full_match",
            line2: nil,
            city: "San Francisco",
            state: "California",
            postal_code: "94107",
            country: "US"
          },
          id_number: "000000000",
          dob: { day: 1, month: 1, year: 1901 },
          first_name: "Chuck",
          last_name: "Bartowski",
          phone: "0000000000",
          email: user.email,
          relationship: { representative: true, owner: true, title: "CEO", percent_ownership: 100 }
        }
      end

      it "creates an account at stripe with all the params" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original
        expect(Stripe::Account).to receive(:create_person).with(anything, expected_person_params).and_call_original
        subject.create_account(user, passphrase: "1234")
      end

      it "returns a merchant account" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
      end

      it "deletes the half-provisioned Stripe account when interrupted after it is created" do
        allow(Stripe::Account).to receive(:create_person).and_raise(StandardError.new("interrupted"))
        expect(Stripe::Account).to receive(:delete).with(/\Aacct_/).and_call_original

        expect do
          subject.create_account(user, passphrase: "1234")
        end.to raise_error(StandardError, "interrupted")

        merchant_account = user.merchant_accounts.stripe.last
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.alive?).to be(false)
      end

      it "normalizes Strongbox-decrypted ASCII-8BIT params to UTF-8 before they reach Stripe" do
        binary_strings = []
        collect_binary = lambda do |value|
          case value
          when Hash then value.each_value { |v| collect_binary.call(v) }
          when Array then value.each { |v| collect_binary.call(v) }
          when String then binary_strings << value if value.encoding == Encoding::ASCII_8BIT
          end
        end

        allow(Stripe::Account).to receive(:create).and_wrap_original do |original, params|
          collect_binary.call(params)
          original.call(params)
        end
        allow(Stripe::Account).to receive(:create_person).and_wrap_original do |original, account_id, params|
          collect_binary.call(params)
          original.call(account_id, params)
        end

        subject.create_account(user, passphrase: "1234")

        expect(binary_strings).to be_empty
      end
    end

    describe "US business with a foreign-resident representative (person_hash)" do
      # Regression coverage for gumroad-private#441: a US LLC with a Bangladesh-resident
      # representative could not save settings because we sent the rep's foreign national ID
      # as person.id_number on a US Stripe Connect account, which Stripe rejects with a
      # "must be 9 digits" SSN error and our controller surfaces verbatim to the seller.
      def build_us_llc_with_foreign_rep(individual_tax_id:)
        create(:user_compliance_info_business,
               user:,
               first_name: "Rashed",
               last_name: "Khan",
               street_address: "House 12, Road 3",
               city: "Rajshahi",
               state: nil,
               zip_code: "6203",
               country: "Bangladesh",
               individual_tax_id:)
      end

      context "with a non-US tax ID (e.g. Bangladesh national ID)" do
        let(:user_compliance_info) { build_us_llc_with_foreign_rep(individual_tax_id: "1234567890") }

        let(:person_hash) do
          described_class.send(:person_hash, user_compliance_info, GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        end

        it "omits id_number so Stripe can request document verification instead of rejecting" do
          expect(person_hash).not_to have_key(:id_number)
          expect(person_hash).not_to have_key(:ssn_last_4)
        end

        it "omits nationality because the Stripe account country (US) does not require it" do
          expect(person_hash).not_to have_key(:nationality)
        end

        it "still carries the rep's foreign address so Stripe knows where they live" do
          expect(person_hash[:address]).to include(country: "BD", city: "Rajshahi", postal_code: "6203")
        end
      end

      context "with a 9-digit US tax ID (e.g. an ITIN held by a foreign resident)" do
        let(:user_compliance_info) { build_us_llc_with_foreign_rep(individual_tax_id: "900123456") }

        it "submits the id_number to Stripe so the account can verify without document upload" do
          person_hash = described_class.send(:person_hash, user_compliance_info, GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
          expect(person_hash[:id_number]).to eq("900123456")
          expect(person_hash).not_to have_key(:ssn_last_4)
        end
      end
    end

    describe "Luxembourg postal codes written with the conventional 'L-' prefix" do
      # Regression coverage for gumroad-private#1014: LU residents habitually write postal
      # codes as "L-9767". Stripe only accepts the bare four digits and rejects the prefixed
      # form with `postal_code_invalid`, which (because account creation runs async) left the
      # seller silently unable to publish. Normalize at the Stripe boundary so both fresh
      # saves and retry-job re-attempts of already-saved records succeed.
      let(:user_compliance_info) do
        create(:user_compliance_info,
               user:,
               street_address: "2 Rue du Château",
               city: "Ettelbruck",
               state: nil,
               zip_code: "L-9767",
               country: "Luxembourg")
      end

      it "strips the 'L-' prefix from the individual address postal code" do
        person_hash = described_class.send(:person_hash, user_compliance_info, GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        expect(person_hash[:address]).to include(country: "LU", postal_code: "9767")
      end

      it "strips the prefix from the legal-entity address on business accounts" do
        business_info = create(:user_compliance_info_business,
                               user:,
                               business_street_address: "2 Rue du Château",
                               business_city: "Ettelbruck",
                               business_state: nil,
                               business_zip_code: "l 9767",
                               business_country: "Luxembourg")
        company_hash = described_class.send(:company_hash, business_info, GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        expect(company_hash[:company][:address]).to include(country: "LU", postal_code: "9767")
      end

      describe ".normalize_postal_code" do
        it "normalizes prefixed LU postal codes and leaves everything else untouched" do
          expect(described_class.send(:normalize_postal_code, "L-9767", "LU")).to eq("9767")
          expect(described_class.send(:normalize_postal_code, "l-9767", "LU")).to eq("9767")
          expect(described_class.send(:normalize_postal_code, "L 9767", "LU")).to eq("9767")
          expect(described_class.send(:normalize_postal_code, "L9767", "LU")).to eq("9767")
          expect(described_class.send(:normalize_postal_code, " L-9767 ", "LU")).to eq("9767")
          expect(described_class.send(:normalize_postal_code, "9767", "LU")).to eq("9767")
          # Not the L-prefix shape: pass through so Stripe can report its own validation error.
          expect(described_class.send(:normalize_postal_code, "L-97", "LU")).to eq("L-97")
          expect(described_class.send(:normalize_postal_code, "Lot 5", "LU")).to eq("Lot 5")
          # Other countries are untouched, even when the value looks prefixed.
          expect(described_class.send(:normalize_postal_code, "L-1234", "FR")).to eq("L-1234")
          expect(described_class.send(:normalize_postal_code, "94107", "US")).to eq("94107")
          expect(described_class.send(:normalize_postal_code, nil, "LU")).to be_nil
        end

        it "normalizes NL postal codes to the spaced uppercase 'NNNN LL' form Stripe requires" do
          # Regression coverage for gumroad-private#1247: an NL seller saved "2742NZ" (no
          # space) and Stripe rejected it with `postal_code_invalid` four times while the
          # settings page showed a successful save each time.
          expect(described_class.send(:normalize_postal_code, "2742NZ", "NL")).to eq("2742 NZ")
          expect(described_class.send(:normalize_postal_code, "2742nz", "NL")).to eq("2742 NZ")
          expect(described_class.send(:normalize_postal_code, "2742 nz", "NL")).to eq("2742 NZ")
          expect(described_class.send(:normalize_postal_code, " 2742 NZ ", "NL")).to eq("2742 NZ")
          # Already correct: unchanged.
          expect(described_class.send(:normalize_postal_code, "2742 NZ", "NL")).to eq("2742 NZ")
          # Not the NL shape: pass through so Stripe can report its own validation error.
          expect(described_class.send(:normalize_postal_code, "2742", "NL")).to eq("2742")
          expect(described_class.send(:normalize_postal_code, "2742NZX", "NL")).to eq("2742NZX")
          expect(described_class.send(:normalize_postal_code, "NZ2742", "NL")).to eq("NZ2742")
          expect(described_class.send(:normalize_postal_code, "2742  NZ", "NL")).to eq("2742  NZ")
          # Other countries are untouched, even when the value matches the NL shape.
          expect(described_class.send(:normalize_postal_code, "2742NZ", "BE")).to eq("2742NZ")
          expect(described_class.send(:normalize_postal_code, nil, "NL")).to be_nil
        end
      end
    end

    describe "Netherlands postal codes written without the space" do
      # Regression coverage for gumroad-private#1247: Dutch postcodes are "NNNN LL" but
      # sellers often type "2742NZ". Stripe rejects the unspaced form with
      # `postal_code_invalid`, which (because account creation runs async) left the seller
      # silently unable to publish. Normalize at the Stripe boundary so both fresh saves
      # and retry-job re-attempts of already-saved records succeed.
      let(:user_compliance_info) do
        create(:user_compliance_info,
               user:,
               street_address: "Mahoniehout 1",
               city: "Waddinxveen",
               state: nil,
               zip_code: "2742nz",
               country: "Netherlands")
      end

      it "inserts the space and upcases in the individual address postal code" do
        person_hash = described_class.send(:person_hash, user_compliance_info, GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        expect(person_hash[:address]).to include(country: "NL", postal_code: "2742 NZ")
      end

      it "normalizes the legal-entity address on business accounts" do
        business_info = create(:user_compliance_info_business,
                               user:,
                               business_street_address: "Mahoniehout 1",
                               business_city: "Waddinxveen",
                               business_state: nil,
                               business_zip_code: "2742NZ",
                               business_country: "Netherlands")
        company_hash = described_class.send(:company_hash, business_info, GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        expect(company_hash[:company][:address]).to include(country: "NL", postal_code: "2742 NZ")
      end
    end

    describe "Bangladesh business with a rep resident outside Bangladesh (person_hash)" do
      # Reverse direction of the foreign-rep fix: gating nationality on the account country instead
      # of the rep's residential country also means BGD/SGP/PAK/UAE *accounts* keep submitting
      # nationality regardless of where the rep lives (Stripe KYC asks for citizenship here, not
      # residence). Guards against regressing that direction.
      let(:user_compliance_info) do
        create(:user_compliance_info_business,
               user:,
               first_name: "Imran",
               last_name: "Choudhury",
               country: "United States",
               business_name: "Choudhury Trading Ltd",
               business_street_address: "Sheikh Mujib Road 14",
               business_city: "Dhaka",
               business_state: nil,
               business_zip_code: "1212",
               business_country: "Bangladesh",
               nationality: "BD",
               individual_tax_id: "12345678901")
      end

      it "still submits nationality because the Stripe account country (BD) requires it" do
        person_hash = described_class.send(:person_hash, user_compliance_info, GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        expect(person_hash[:nationality]).to eq("BD")
      end

      it "submits the rep's id_number unchanged since the account is non-US" do
        person_hash = described_class.send(:person_hash, user_compliance_info, GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        expect(person_hash[:id_number]).to eq("12345678901")
      end
    end

    describe "all info provided of an individual (non-US)" do
      let(:user_compliance_info) { create(:user_compliance_info, user:, zip_code: "M4C 1T2", city: "Toronto", state: nil, country: "Canada") }
      let(:bank_account) { create(:ach_account_stripe_succeed, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "CA",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          default_currency: "cad",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name,
            support_phone: nil,
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Toronto",
              state: nil,
              postal_code: "M4C 1T2",
              country: "CA"
            },
            id_number: "000000000",
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "US",
            currency: "usd",
            routing_number: "110000000",
            account_number: "000123456789"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original
        subject.create_account(user, passphrase: "1234")
      end

      it "returns a merchant account" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
      end

      it "returns a merchant account with country set" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.country).to eq("CA")
      end

      it "returns a merchant account with currency set" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.currency).to eq("cad")
      end

      it "saves the stripe connect account id on our bank account record" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
      end

      it "saves the stripe bank account id on our bank account record" do
        subject.create_account(user, passphrase: "1234")
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
      end

      it "saves the stripe bank account fingerprint on our bank account record" do
        subject.create_account(user, passphrase: "1234")
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a business (non-US)" do
      let(:user_compliance_info) do
        create(:user_compliance_info_business, user:, business_type: "private_corporation",
                                               city: "Toronto", state: nil, country: "Canada", zip_code: "M4C 1T2", business_zip_code: "M4C 1T2",
                                               business_city: "Toronto", business_state: nil, business_country: "Canada")
      end
      let(:bank_account) { create(:ach_account_stripe_succeed, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "CA",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          default_currency: "cad",
          business_type: "company",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name,
            support_phone: "0000000000",
          },
          company: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Toronto",
              state: nil,
              postal_code: "M4C 1T2",
              country: "CA"
            },
            name: "Buy More, LLC",
            tax_id: "000000000",
            phone: "0000000000",
            structure: "private_corporation",
            directors_provided: true,
            executives_provided: true
          },
          bank_account: {
            country: "US",
            currency: "usd",
            routing_number: "110000000",
            account_number: "000123456789"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      let(:expected_person_params) do
        {
          id_number: "000000000",
          dob: { day: 1, month: 1, year: 1901 },
          first_name: "Chuck",
          last_name: "Bartowski",
          relationship: { representative: true, owner: true, percent_ownership: 100, title: "CEO" },
          address:
          {
            line1: "address_full_match",
            line2: nil,
            city: "Toronto",
            state: nil,
            postal_code: "M4C 1T2",
            country: "CA"
          },
          phone: "0000000000",
          email: user.email,
        }
      end

      it "creates an account at stripe with all the params" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original
        expect(Stripe::Account).to receive(:create_person).with(anything, expected_person_params).and_call_original
        subject.create_account(user, passphrase: "1234")
      end

      it "returns a merchant account" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
      end
    end

    describe "all info provided of an individual (UK/EU)" do
      let(:user_compliance_info) { create(:user_compliance_info, user:, city: "London", street_address: "A4", state: nil, zip_code: "WC2N 5DU", country: "United Kingdom") }
      let(:bank_account) { create(:ach_account_stripe_succeed, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "GB",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          default_currency: "gbp",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "A4",
              line2: nil,
              city: "London",
              state: nil,
              postal_code: "WC2N 5DU",
              country: "GB"
            },
            id_number: "000000000",
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "US",
            currency: "usd",
            routing_number: "110000000",
            account_number: "000123456789"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original
        subject.create_account(user, passphrase: "1234")
      end

      it "returns a merchant account" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
      end

      it "returns a merchant account with country set" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.country).to eq("GB")
      end

      it "returns a merchant account with currency set" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.currency).to eq("gbp")
      end

      it "saves the stripe connect account id on our bank account record" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
      end

      it "saves the stripe bank account id on our bank account record" do
        subject.create_account(user, passphrase: "1234")
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
      end

      it "saves the stripe bank account fingerprint on our bank account record" do
        subject.create_account(user, passphrase: "1234")
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a business (UK/EU)" do
      let(:user_compliance_info) do
        create(:user_compliance_info_business, user:,
                                               city: "London", state: nil, country: "United Kingdom", zip_code: "WC2N 5DU", business_zip_code: "WC2N 5DU",
                                               business_city: "London", business_state: nil, business_country: "United Kingdom")
      end
      let(:bank_account) { create(:ach_account_stripe_succeed, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "GB",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          default_currency: "gbp",
          business_type: "company",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          company: {
            name: "Buy More, LLC",
            tax_id: "000000000",
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "London",
              state: nil,
              postal_code: "WC2N 5DU",
              country: "GB"
            },
            phone: "0000000000",
            directors_provided: true,
            executives_provided: true
          },
          bank_account: {
            country: "US",
            currency: "usd",
            routing_number: "110000000",
            account_number: "000123456789"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      let(:expected_person_params) do
        {
          id_number: "000000000",
          dob: { day: 1, month: 1, year: 1901 },
          first_name: "Chuck",
          last_name: "Bartowski",
          relationship: { representative: true, owner: true, percent_ownership: 100, title: "CEO" },
          address: {
            line1: "address_full_match",
            line2: nil,
            city: "London",
            state: nil,
            postal_code: "WC2N 5DU",
            country: "GB"
          },
          phone: "0000000000",
          email: user.email,
        }
      end

      it "creates an account at stripe with all the params" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original
        expect(Stripe::Account).to receive(:create_person).with(anything, expected_person_params).and_call_original
        subject.create_account(user, passphrase: "1234")
      end

      it "returns a merchant account" do
        merchant_account = subject.create_account(user, passphrase: "1234")
        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
      end
    end

    describe "all info provided of an FR individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Paris",
                                                                  street_address: "address_full_match", state: nil, zip_code: "75116",
                                                                  country: "France") end
      let(:bank_account) { create(:fr_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "FR",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          default_currency: "eur",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Paris",
              state: nil,
              postal_code: "75116",
              country: "FR"
            },
            id_number: "000000000",
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "FR",
            currency: "eur",
            account_number: "FR89370400440532013000",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("FR")
        expect(merchant_account.currency).to eq("eur")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an DE business" do
      let(:user_compliance_info) do create(:user_compliance_info_business, user:,
                                                                           city: "Berlin", state: nil, country: "Germany", zip_code: "10115",
                                                                           business_zip_code: "10115", business_city: "Berlin", business_state: nil,
                                                                           business_country: "Germany") end
      let(:bank_account) { create(:european_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "DE",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          default_currency: "eur",
          business_type: "company",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          company: {
            name: "Buy More, LLC",
            tax_id: "000000000",
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Berlin",
              state: nil,
              postal_code: "10115",
              country: "DE"
            },
            phone: "0000000000",
            directors_provided: true,
            executives_provided: true
          },
          bank_account: {
            country: "DE",
            currency: "eur",
            account_number: "DE89370400440532013000"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      let(:expected_person_params) do
        {
          id_number: "000000000",
          dob: { day: 1, month: 1, year: 1901 },
          first_name: "Chuck",
          last_name: "Bartowski",
          relationship: { representative: true, owner: true, percent_ownership: 100, title: "CEO" },
          address: {
            line1: "address_full_match",
            line2: nil,
            city: "Berlin",
            state: nil,
            postal_code: "10115",
            country: "DE"
          },
          phone: "0000000000",
          email: user.email,
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("DE")
        expect(merchant_account.currency).to eq("eur")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    # Regression: gh-private #683. Strongbox decrypts (IBAN, tax id) return ASCII-8BIT (binary)
    # strings. When the Stripe gem serializes the params alongside a UTF-8 compliance field that
    # carries non-ASCII bytes (an umlaut/accent in a business name or address), Ruby raised
    # Encoding::CompatibilityError and the Stripe::Account.create call never reached Stripe, silently
    # blocking the seller from getting a merchant account. force_utf8_encoding normalizes the params.
    describe ".force_utf8_encoding" do
      it "re-encodes ASCII-8BIT strings to UTF-8 recursively while leaving other values untouched" do
        binary_iban = "DE89370400440532013000".dup.force_encoding(Encoding::ASCII_8BIT)
        binary_tax_id = "DE123456789".dup.force_encoding(Encoding::ASCII_8BIT)
        params = {
          business_profile: { name: "Häuserhelden UG" },
          company: { name: "Häuserhelden UG", tax_id: binary_tax_id, address: { city: "Düsseldorf" } },
          bank_account: { account_number: binary_iban, currency: "eur" },
          metadata: { count: 3, flag: true, missing: nil }
        }

        result = described_class.force_utf8_encoding(params)

        expect(result[:bank_account][:account_number].encoding).to eq(Encoding::UTF_8)
        expect(result[:bank_account][:account_number]).to eq("DE89370400440532013000")
        expect(result[:company][:tax_id].encoding).to eq(Encoding::UTF_8)
        expect(result[:company][:tax_id]).to eq("DE123456789")
        # UTF-8 umlaut fields are preserved verbatim
        expect(result[:company][:name]).to eq("Häuserhelden UG")
        expect(result[:company][:address][:city]).to eq("Düsseldorf")
        # non-string values pass through unchanged
        expect(result[:metadata]).to eq(count: 3, flag: true, missing: nil)
      end

      it "produces params that serialize without an Encoding::CompatibilityError when binary and UTF-8 fields are mixed" do
        params = {
          company: {
            name: "Häuserhelden UG",
            tax_id: "DE123456789".dup.force_encoding(Encoding::ASCII_8BIT)
          },
          bank_account: { account_number: "DE89370400440532013000".dup.force_encoding(Encoding::ASCII_8BIT) }
        }

        # Before the fix this raised Encoding::CompatibilityError during string concatenation.
        normalized = described_class.force_utf8_encoding(params)
        serialized = "#{normalized[:company][:name]}#{normalized[:company][:tax_id]}#{normalized[:bank_account][:account_number]}"

        expect(serialized).to eq("Häuserhelden UGDE123456789DE89370400440532013000")
      end
    end

    describe "all info provided of an HK individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Hong Kong",
                                                                  street_address: "address_full_match", state: nil, zip_code: "999077",
                                                                  country: "Hong Kong") end
      let(:bank_account) { create(:hong_kong_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "HK",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          default_currency: "hkd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Hong Kong",
              state: nil,
              postal_code: "999077",
              country: "HK"
            },
            id_number: "000000000",
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "HK",
            currency: "hkd",
            account_number: "000123456",
            routing_number: "110-000"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("HK")
        expect(merchant_account.currency).to eq("hkd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an SG business" do
      let(:user_compliance_info) do create(:user_compliance_info_business, user:,
                                                                           city: "Singapore", state: nil, country: "Singapore", zip_code: "546080",
                                                                           business_zip_code: "546080", business_city: "Singapore", business_state: nil,
                                                                           business_country: "Singapore", nationality: "SG") end
      let(:bank_account) { create(:singaporean_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "SG",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          default_currency: "sgd",
          business_type: "company",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          company: {
            name: "Buy More, LLC",
            tax_id: "000000000",
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Singapore",
              state: nil,
              postal_code: "546080",
              country: "SG"
            },
            phone: "0000000000",
            directors_provided: true,
            executives_provided: true
          },
          bank_account: {
            country: "SG",
            currency: "sgd",
            routing_number: "1100-000",
            account_number: "000123456"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      let(:expected_person_params) do
        {
          id_number: "000000000",
          dob: { day: 1, month: 1, year: 1901 },
          first_name: "Chuck",
          last_name: "Bartowski",
          relationship: { representative: true, owner: true, percent_ownership: 100, title: "CEO" },
          address: {
            line1: "address_full_match",
            line2: nil,
            city: "Singapore",
            state: nil,
            postal_code: "546080",
            country: "SG"
          },
          phone: "0000000000",
          email: user.email,
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original
        expect(Stripe::Account).to receive(:update_person).with(anything, anything, hash_including(full_name_aliases: [""])).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("SG")
        expect(merchant_account.currency).to eq("sgd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Japanese individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "渋谷区", city_kana: "シブヤク", phone: "+81987654321",
                                                                  first_name_kanji: "日本語", last_name_kanji: "創造者",
                                                                  first_name_kana: "ニホンゴ", last_name_kana: "ソウゾウシャ",
                                                                  building_number: "1-1", building_number_kana: "1-1",
                                                                  street_address_kanji: "神宮前", street_address_kana: "ジングウマエ",
                                                                  street_address: "address_full_match", state: "東京都", zip_code: "100-0000",
                                                                  country: "Japan") end
      let(:bank_account) { create(:japan_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "JP",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          default_currency: "jpy",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address_kanji: {
              line1: "1-1",
              town: "神宮前",
              city: "渋谷区",
              state: "東京都",
              country: "JP",
              postal_code: "100-0000",
            },
            address_kana: {
              line1: "1-1",
              town: "ジングウマエ",
              city: "シブヤク",
              state: "トウキョウト",
              country: "JP",
              postal_code: "100-0000",
            },
            id_number: "000000000",
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            first_name_kanji: "日本語",
            last_name_kanji: "創造者",
            first_name_kana: "ニホンゴ",
            last_name_kana: "ソウゾウシャ",
            phone: "+81987654321",
            email: user.email,
          },
          bank_account: {
            account_holder_name: "Japanese Creator",
            country: "JP",
            currency: "jpy",
            routing_number: "1100000",
            account_number: "0001234",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("JP")
        expect(merchant_account.currency).to eq("jpy")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "a Japanese individual without the city fields (compliance info saved before the city inputs existed)" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: nil, phone: "+81987654321",
                                                                  first_name_kanji: "日本語", last_name_kanji: "創造者",
                                                                  first_name_kana: "ニホンゴ", last_name_kana: "ソウゾウシャ",
                                                                  building_number: "1-1", building_number_kana: "1-1",
                                                                  street_address_kanji: "神宮前", street_address_kana: "ジングウマエ",
                                                                  street_address: "address_full_match", state: "東京都", zip_code: "100-0000",
                                                                  country: "Japan") end

      it "omits the city keys from the kanji and kana address hashes instead of sending explicit nils" do
        person = described_class.send(:person_hash, user_compliance_info, "1234")

        expect(person[:address_kanji]).to eq(
          line1: "1-1",
          town: "神宮前",
          state: "東京都",
          country: "JP",
          postal_code: "100-0000"
        )
        expect(person[:address_kana]).to eq(
          line1: "1-1",
          town: "ジングウマエ",
          state: "トウキョウト",
          country: "JP",
          postal_code: "100-0000"
        )
      end
    end

    describe "all info provided of an NZ individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Wellington",
                                                                  street_address: "address_full_match", state: nil, zip_code: "6012",
                                                                  country: "New Zealand") end
      let(:bank_account) { create(:new_zealand_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "NZ",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          default_currency: "nzd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Wellington",
              state: nil,
              postal_code: "6012",
              country: "NZ"
            },
            id_number: "000000000",
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "NZ",
            currency: "nzd",
            account_number: "1100000000000010",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("NZ")
        expect(merchant_account.currency).to eq("nzd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an CH business" do
      let(:user_compliance_info) do create(:user_compliance_info_business, user:,
                                                                           city: "Switzerland", state: nil, country: "Switzerland", zip_code: "3436",
                                                                           business_zip_code: "3436", business_city: "Switzerland", business_state: nil,
                                                                           business_country: "Switzerland") end
      let(:bank_account) { create(:swiss_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "CH",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          default_currency: "chf",
          business_type: "company",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          company: {
            name: "Buy More, LLC",
            tax_id: "000000000",
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Switzerland",
              state: nil,
              postal_code: "3436",
              country: "CH"
            },
            phone: "0000000000",
            directors_provided: true,
            executives_provided: true
          },
          bank_account: {
            country: "CH",
            currency: "chf",
            account_number: "CH9300762011623852957"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      let(:expected_person_params) do
        {
          id_number: "000000000",
          dob: { day: 1, month: 1, year: 1901 },
          first_name: "Chuck",
          last_name: "Bartowski",
          relationship: { representative: true, owner: true, percent_ownership: 100, title: "CEO" },
          address: {
            line1: "address_full_match",
            line2: nil,
            city: "Switzerland",
            state: nil,
            postal_code: "3436",
            country: "CH"
          },
          phone: "0000000000",
          email: user.email,
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("CH")
        expect(merchant_account.currency).to eq("chf")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Kazakhstan individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Almaty",
                                                                  street_address: "address_full_match", state: nil, zip_code: "050000",
                                                                  country: "Kazakhstan", individual_tax_id: "000000000") end
      let(:bank_account) { create(:kazakhstan_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "KZ",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "kzt",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Almaty",
              state: nil,
              postal_code: "050000",
              country: "KZ"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
            id_number: "000000000"
          },
          bank_account: {
            country: "KZ",
            currency: "kzt",
            account_number: "KZ221251234567890123",
            routing_number: "AAAAKZKZXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("KZ")
        expect(merchant_account.currency).to eq("kzt")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an Ecuadorian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Quito",
                                                                  street_address: "address_full_match", state: nil, zip_code: "170102",
                                                                  country: "Ecuador", individual_tax_id: nil) end
      let(:bank_account) { create(:ecuador_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "EC",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "usd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Quito",
              state: nil,
              postal_code: "170102",
              country: "EC"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "EC",
            currency: "usd",
            account_number: "000123456789",
            routing_number: "AAAAECE1XXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("EC")
        expect(merchant_account.currency).to eq("usd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an TH individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Bangkok",
                                                                  street_address: "address_full_match", state: nil, zip_code: "10169",
                                                                  country: "Thailand", individual_tax_id: nil) end
      let(:bank_account) { create(:thailand_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "TH",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "thb",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Bangkok",
              state: nil,
              postal_code: "10169",
              country: "TH"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "TH",
            currency: "thb",
            account_number: "000123456789",
            routing_number: "999"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("TH")
        expect(merchant_account.currency).to eq("thb")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a KR individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Seoul",
                                                                  street_address: "address_full_match", state: nil, zip_code: "100-011",
                                                                  country: "Korea, Republic of", individual_tax_id: nil) end
      let(:bank_account) { create(:korea_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "KR",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "krw",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Seoul",
              state: nil,
              postal_code: "100-011",
              country: "KR"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "KR",
            currency: "krw",
            account_number: "000123456789",
            routing_number: "SGSEKRSLXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("KR")
        expect(merchant_account.currency).to eq("krw")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an Indian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Indore",
                                                                  street_address: "address_full_match", state: nil, zip_code: "452010",
                                                                  country: "India", individual_tax_id: nil) end
      let(:bank_account) { create(:indian_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "IN",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "inr",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Indore",
              state: nil,
              postal_code: "452010",
              country: "IN"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "IN",
            currency: "inr",
            account_number: "000123456789",
            routing_number: "HDFC0004051"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "raises a user not ready error because new India accounts are blocked" do
        expect(Stripe::Account).not_to receive(:create)

        expect do
          subject.create_account(user, passphrase: "1234")
        end.to raise_error(MerchantRegistrationUserNotReadyError, /not supported yet/)
        expect(user.merchant_accounts.alive.count).to eq(0)
      end

      context "when new India account creation is not blocked" do
        before { stub_const("StripeMerchantAccountManager::NEW_ACCOUNT_CREATION_BLOCKED_COUNTRIES", []) }

        it "creates an account at stripe with all the params and returns the corresponding merchant account" do
          expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

          merchant_account = subject.create_account(user, passphrase: "1234")

          expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
          expect(merchant_account.charge_processor_merchant_id).to be_present
          expect(merchant_account.country).to eq("IN")
          expect(merchant_account.currency).to eq("inr")
          expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
          expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
          expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
        end
      end
    end

    describe "all info provided of a Taiwanese individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Taiwan",
                                                                  street_address: "address_full_match", state: nil, zip_code: "8862",
                                                                  country: "Taiwan", individual_tax_id: nil) end
      let(:bank_account) { create(:taiwan_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "TW",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "twd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Taiwan",
              state: nil,
              postal_code: "8862",
              country: "TW"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "TW",
            currency: "twd",
            account_number: "0001234567",
            routing_number: "AAAATWTXXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("TW")
        expect(merchant_account.currency).to eq("twd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Vietnamese individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Vietnam",
                                                                  street_address: "address_full_match", state: nil, zip_code: "290000",
                                                                  country: "Vietnam", individual_tax_id: nil) end
      let(:bank_account) { create(:vietnam_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "VN",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "vnd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Vietnam",
              state: nil,
              postal_code: "290000",
              country: "VN"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            account_holder_name: "Gumbot Gumstein I",
            country: "VN",
            currency: "vnd",
            account_number: "000123456789",
            routing_number: "01101100"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("VN")
        expect(merchant_account.currency).to eq("vnd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a South African individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "South Africa",
                                                                  street_address: "address_full_match", state: nil, zip_code: "24425",
                                                                  country: "South Africa", individual_tax_id: nil) end
      let(:bank_account) { create(:south_africa_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "ZA",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "zar",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "South Africa",
              state: nil,
              postal_code: "24425",
              country: "ZA"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "ZA",
            currency: "zar",
            account_number: "000001234",
            routing_number: "FIRNZAJJ"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("ZA")
        expect(merchant_account.currency).to eq("zar")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Kenyan individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Kenya",
                                                                  street_address: "address_full_match", state: nil, zip_code: "24425",
                                                                  country: "Kenya", individual_tax_id: nil) end
      let(:bank_account) { create(:kenya_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "KE",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "kes",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Kenya",
              state: nil,
              postal_code: "24425",
              country: "KE"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "KE",
            currency: "kes",
            account_number: "000123456789",
            routing_number: "BARCKENXMDR"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("KE")
        expect(merchant_account.currency).to eq("kes")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Egyptian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Egypt",
                                                                  street_address: "address_full_match", state: nil, zip_code: "24425",
                                                                  country: "Egypt", individual_tax_id: nil) end
      let(:bank_account) { create(:egypt_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "EG",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "egp",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Egypt",
              state: nil,
              postal_code: "24425",
              country: "EG"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "EG",
            currency: "egp",
            account_number: "EG800002000156789012345180002",
            routing_number: "NBEGEGCX331"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("EG")
        expect(merchant_account.currency).to eq("egp")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Uruguayan individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Montevideo",
                                                                  street_address: "address_full_match", state: nil, zip_code: "11000",
                                                                  country: "Uruguay", individual_tax_id: nil) end
      let(:bank_account) { create(:uruguay_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "UY",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "uyu",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Montevideo",
              state: nil,
              postal_code: "11000",
              country: "UY"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "UY",
            currency: "uyu",
            account_number: "000123456789",
            routing_number: "999"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("UY")
        expect(merchant_account.currency).to eq("uyu")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Mauritian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Port Louis",
                                                                  street_address: "address_full_match", state: nil, zip_code: "11324",
                                                                  country: "Mauritius", individual_tax_id: nil) end
      let(:bank_account) { create(:mauritius_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "MU",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "mur",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Port Louis",
              state: nil,
              postal_code: "11324",
              country: "MU"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "MU",
            currency: "mur",
            account_number: "MU17BOMM0101101030300200000MUR",
            routing_number: "AAAAMUMUXYZ"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("MU")
        expect(merchant_account.currency).to eq("mur")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Jamaican individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Kingston",
                                                                  street_address: "address_full_match", state: nil, zip_code: "JMAAW01",
                                                                  country: "Jamaica", individual_tax_id: nil) end
      let(:bank_account) { create(:jamaica_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "JM",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "jmd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Kingston",
              state: nil,
              postal_code: "JMAAW01",
              country: "JM"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "JM",
            currency: "jmd",
            account_number: "000123456789",
            routing_number: "111-00000"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("JM")
        expect(merchant_account.currency).to eq("jmd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Colombian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Colombia",
                                                                  street_address: "address_full_match", state: nil, zip_code: "411088",
                                                                  country: "Colombia", individual_tax_id: "1.123.123.123") end
      let(:bank_account) { create(:colombia_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "CO",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "cop",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Colombia",
              state: nil,
              postal_code: "411088",
              country: "CO"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
            id_number: "1.123.123.123",
          },
          bank_account: {
            country: "CO",
            currency: "cop",
            account_number: "000123456789",
            routing_number: "060",
            account_type: "savings"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("CO")
        expect(merchant_account.currency).to eq("cop")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an Indonesian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Bali",
                                                                  street_address: "address_full_match", state: nil, zip_code: "8862",
                                                                  country: "Indonesia", individual_tax_id: nil) end
      let(:bank_account) { create(:indonesia_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "ID",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "idr",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Bali",
              state: nil,
              postal_code: "8862",
              country: "ID"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "ID",
            currency: "idr",
            account_holder_name: "Gumbot Gumstein I",
            account_number: "000123456789",
            routing_number: "000"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("ID")
        expect(merchant_account.currency).to eq("idr")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Costa Rican individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "San José",
                                                                  street_address: "address_full_match", state: nil, zip_code: "10101",
                                                                  country: "Costa Rica", individual_tax_id: nil) end
      let(:bank_account) { create(:costa_rica_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "CR",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "crc",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "San José",
              state: nil,
              postal_code: "10101",
              country: "CR"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "CR",
            currency: "crc",
            account_number: "CR04010212367856709123"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("CR")
        expect(merchant_account.currency).to eq("crc")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Moldova individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Chisinau",
                                                                  street_address: "address_full_match", state: nil, zip_code: "2001",
                                                                  country: "Moldova", individual_tax_id: "000000000") end
      let(:bank_account) { create(:moldova_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "MD",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "mdl",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Chisinau",
              state: nil,
              postal_code: "2001",
              country: "MD"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
            id_number: "000000000"
          },
          bank_account: {
            country: "MD",
            currency: "mdl",
            account_number: "MD07AG123456789012345678",
            routing_number: "AAAAMDMDXXX",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("MD")
        expect(merchant_account.currency).to eq("mdl")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Panama individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Panama City",
                                                                  street_address: "address_full_match", state: nil, zip_code: "0801",
                                                                  country: "Panama", individual_tax_id: "000000000") end
      let(:bank_account) { create(:panama_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "PA",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "usd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Panama City",
              state: nil,
              postal_code: "0801",
              country: "PA"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
            id_number: "000000000"
          },
          bank_account: {
            country: "PA",
            currency: "usd",
            account_number: "000123456789",
            routing_number: "AAAAPAPAXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("PA")
        expect(merchant_account.currency).to eq("usd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an El Salvador individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "San Salvador",
                                                                  street_address: "address_full_match", state: nil, zip_code: "1101",
                                                                  country: "El Salvador", individual_tax_id: "000000000") end
      let(:bank_account) { create(:el_salvador_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "SV",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "usd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "San Salvador",
              state: nil,
              postal_code: "1101",
              country: "SV"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
            id_number: "000000000"
          },
          bank_account: {
            country: "SV",
            currency: "usd",
            account_number: "SV44BCIE12345678901234567890",
            routing_number: "AAAASVS1XXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("SV")
        expect(merchant_account.currency).to eq("usd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end

      context "when the seller stored a plain account number instead of an IBAN" do
        let(:bank_account) { create(:el_salvador_bank_account, user:, bank_number: "CAGRSVSS", account_number: "3280602160", account_number_last_four: "2160") }

        it "constructs an IBAN from the SWIFT/BIC and account number before sending to Stripe" do
          captured_params = nil
          allow(Stripe::Account).to receive(:create) do |params|
            captured_params = params
            raise Stripe::APIError, "stop_here"
          end

          expect { subject.create_account(user, passphrase: "1234") }.to raise_error(Stripe::APIError, "stop_here")
          expect(captured_params[:bank_account][:account_number]).to eq("SV88CAGR00000000003280602160")
          expect(captured_params[:bank_account][:routing_number]).to eq("CAGRSVSS")
        end
      end
    end
    describe "all info provided of a Chile individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Santiago",
                                                                  street_address: "address_full_match", state: nil, zip_code: "8320126",
                                                                  country: "Chile", individual_tax_id: "000000000") end
      let(:bank_account) { create(:chile_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "CL",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "clp",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Santiago",
              state: nil,
              postal_code: "8320126",
              country: "CL"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
            id_number: "000000000"
          },
          bank_account: {
            country: "CL",
            currency: "clp",
            account_number: "000123456789",
            routing_number: "999",
            account_type: "checking"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("CL")
        expect(merchant_account.currency).to eq("clp")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Saudi Arabian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Riyadh",
                                                                  street_address: "address_full_match", state: nil, zip_code: "10110",
                                                                  country: "Saudi Arabia", individual_tax_id: nil) end
      let(:bank_account) { create(:saudi_arabia_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "SA",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "sar",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Riyadh",
              state: nil,
              postal_code: "10110",
              country: "SA"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "SA",
            currency: "sar",
            account_number: "SA4420000001234567891234",
            routing_number: "RIBLSARIXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("SA")
        expect(merchant_account.currency).to eq("sar")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Pakistani individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Lahore",
                                                                  street_address: "address_full_match", state: nil, zip_code: "10110",
                                                                  country: "Pakistan", individual_tax_id: nil, nationality: "PK") end
      let(:bank_account) { create(:pakistan_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "PK",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "pkr",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Lahore",
              state: nil,
              postal_code: "10110",
              country: "PK"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
            nationality: "PK",
          },
          bank_account: {
            country: "PK",
            currency: "pkr",
            account_number: "PK36SCBL0000001123456702",
            routing_number: "AAAAPKKAXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("PK")
        expect(merchant_account.currency).to eq("pkr")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Turkish individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Turkey",
                                                                  street_address: "address_full_match", state: nil, zip_code: "10110",
                                                                  country: "Turkey", individual_tax_id: nil) end
      let(:bank_account) { create(:turkey_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "TR",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "try",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Turkey",
              state: nil,
              postal_code: "10110",
              country: "TR"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "TR",
            currency: "try",
            account_number: "TR320010009999901234567890",
            routing_number: "ADABTRIS"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("TR")
        expect(merchant_account.currency).to eq("try")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Tunisian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Tunis",
                                                                  street_address: "address_full_match", state: nil, zip_code: "1001",
                                                                  country: "Tunisia", individual_tax_id: nil) end
      let(:bank_account) { create(:tunisia_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "TN",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "tnd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Tunis",
              state: nil,
              postal_code: "1001",
              country: "TN"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "TN",
            currency: "tnd",
            account_number: "TN5904018104004942712345",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("TN")
        expect(merchant_account.currency).to eq("tnd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a North Macedonian individual" do
      let(:user_compliance_info) do
        create(:user_compliance_info, user:, city: "Skopje",
                                      street_address: "address_full_match", state: nil, zip_code: "1000",
                                      country: "North Macedonia", individual_tax_id: nil)
      end
      let(:bank_account) { create(:north_macedonia_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "MK",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "mkd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Skopje",
              state: nil,
              postal_code: "1000",
              country: "MK"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "MK",
            currency: "mkd",
            account_number: "MK49250120000058907",
            routing_number: "AAAAMK2XXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("MK")
        expect(merchant_account.currency).to eq("mkd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Madagascar individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Antananarivo",
                                                                  street_address: "address_full_match", state: nil, zip_code: "101",
                                                                  country: "Madagascar", individual_tax_id: nil) end
      let(:bank_account) { create(:madagascar_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "MG",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "mga",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Antananarivo",
              state: nil,
              postal_code: "101",
              country: "MG"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "MG",
            currency: "mga",
            account_number: "MG4800005000011234567890123",
            routing_number: "AAAAMGMGXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("MG")
        expect(merchant_account.currency).to eq("mga")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Senegal individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Dakar",
                                                                  street_address: "address_full_match", state: nil, zip_code: "12500",
                                                                  country: "Senegal", individual_tax_id: nil) end
      let(:bank_account) { create(:senegal_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "SN",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "xof",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Dakar",
              state: nil,
              postal_code: "12500",
              country: "SN"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "SN",
            currency: "xof",
            account_number: "SN08SN0100152000048500003035"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("SN")
        expect(merchant_account.currency).to eq("xof")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a UAE business" do
      let(:user_compliance_info) { create(:user_compliance_info_uae_business, user:) }
      let(:bank_account) { create(:uae_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          country: "AE",
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name,
            support_phone: user_compliance_info.business_phone
          },
          business_type: "company",
          company: {
            name: "Buy More, LLC",
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Dubai",
              state: "Dubai",
              postal_code: "51133",
              country: "AE"
            },
            tax_id: "000000000",
            phone: "0000000000",
            directors_provided: true,
            executives_provided: true,
            structure: user_compliance_info.business_type,
            vat_id: user_compliance_info.business_vat_id_number
          },
          default_currency: "aed",
          bank_account: {
            country: "AE",
            currency: "aed",
            account_number: "AE070331234567890123456"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      let(:expected_person_params) do
        {
          address: {
            line1: "address_full_match",
            line2: nil,
            city: "Dubai",
            state: "Dubai",
            postal_code: "51133",
            country: "AE"
          },
          id_number: "000000000",
          dob: { day: 1, month: 1, year: 1901 },
          first_name: "Chuck",
          last_name: "Bartowski",
          phone: "0000000000",
          email: user.email,
          relationship: { representative: true, owner: true, title: "CEO", percent_ownership: 100 },
          nationality: user_compliance_info.nationality
        }
      end

      it "creates an account at stripe with all the params" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original
        expect(Stripe::Account).to receive(:create_person).with(anything, expected_person_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
      end
    end

    describe "all info provided of a Dominican Republic individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Santo Domingo",
                                                                  street_address: "address_full_match", state: nil, zip_code: "10101",
                                                                  country: "Dominican Republic", individual_tax_id: "123-1234567-1") end
      let(:bank_account) { create(:dominican_republic_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "DO",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "dop",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Santo Domingo",
              state: nil,
              postal_code: "10101",
              country: "DO"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
            id_number: "123-1234567-1",
          },
          bank_account: {
            country: "DO",
            currency: "dop",
            account_number: "000123456789",
            routing_number: "999",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("DO")
        expect(merchant_account.currency).to eq("dop")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Gabon individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Libreville",
                                                                  street_address: "address_full_match", state: nil, zip_code: "1000",
                                                                  country: "Gabon", individual_tax_id: nil) end
      let(:bank_account) { create(:gabon_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "GA",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "xaf",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Libreville",
              state: nil,
              postal_code: "1000",
              country: "GA"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "GA",
            currency: "xaf",
            account_number: "00001234567890123456789",
            routing_number: "AAAAGAGAXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("GA")
        expect(merchant_account.currency).to eq("xaf")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Monaco individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Monaco",
                                                                  street_address: "address_full_match", state: nil, zip_code: "98000",
                                                                  country: "Monaco", individual_tax_id: nil) end
      let(:bank_account) { create(:monaco_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "MC",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "eur",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Monaco",
              state: nil,
              postal_code: "98000",
              country: "MC"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "MC",
            currency: "eur",
            account_number: "MC5810096180790123456789085"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("MC")
        expect(merchant_account.currency).to eq("eur")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an Uzbekistan individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Tashkent",
                                                                  street_address: "address_full_match", state: nil, zip_code: "100000",
                                                                  country: "Uzbekistan", individual_tax_id: nil) end
      let(:bank_account) { create(:uzbekistan_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "UZ",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "uzs",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Tashkent",
              state: nil,
              postal_code: "100000",
              country: "UZ"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "UZ",
            currency: "uzs",
            account_number: "99934500012345670024",
            routing_number: "AAAAUZUZXXX-00000"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("UZ")
        expect(merchant_account.currency).to eq("uzs")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Ethiopia individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "eth",
                                                                  street_address: "address_full_match", state: nil, zip_code: "1000",
                                                                  country: "Ethiopia", individual_tax_id: nil) end
      let(:bank_account) { create(:ethiopia_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "ET",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "etb",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "eth",
              state: nil,
              postal_code: "1000",
              country: "ET"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "ET",
            currency: "etb",
            account_number: "0000000012345",
            routing_number: "AAAAETETXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("ET")
        expect(merchant_account.currency).to eq("etb")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Brunei individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "brun",
                                                                  street_address: "address_full_match", state: nil, zip_code: "1000",
                                                                  country: "Brunei", individual_tax_id: nil) end
      let(:bank_account) { create(:brunei_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "BN",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "bnd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "brun",
              state: nil,
              postal_code: "1000",
              country: "BN"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "BN",
            currency: "bnd",
            account_number: "0000123456789",
            routing_number: "AAAABNBBXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("BN")
        expect(merchant_account.currency).to eq("bnd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Guyana individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "guy",
                                                                  street_address: "address_full_match", state: nil, zip_code: "1000",
                                                                  country: "Guyana", individual_tax_id: nil) end
      let(:bank_account) { create(:guyana_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "GY",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "gyd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "guy",
              state: nil,
              postal_code: "1000",
              country: "GY"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "GY",
            currency: "gyd",
            account_number: "000123456789",
            routing_number: "AAAAGYGGXYZ-12345678"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("GY")
        expect(merchant_account.currency).to eq("gyd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Guatemala individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "guatemala",
                                                                  street_address: "address_full_match", state: nil, zip_code: "1000",
                                                                  country: "Guatemala", individual_tax_id: nil) end
      let(:bank_account) { create(:guatemala_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "GT",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "gtq",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "guatemala",
              state: nil,
              postal_code: "1000",
              country: "GT"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "GT",
            currency: "gtq",
            account_number: "GT20AGRO00000000001234567890",
            routing_number: "AAAAGTGCXYZ"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("GT")
        expect(merchant_account.currency).to eq("gtq")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Bolivian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "La Paz",
                                                                  street_address: "address_full_match", state: nil, zip_code: "00000",
                                                                  country: "Bolivia", individual_tax_id: nil) end
      let(:bank_account) { create(:bolivia_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "BO",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "bob",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "La Paz",
              state: nil,
              postal_code: "00000",
              country: "BO"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "BO",
            currency: "bob",
            account_number: "000123456789",
            routing_number: "040"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("BO")
        expect(merchant_account.currency).to eq("bob")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end
    describe "all info provided of a IL individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Jerusalem",
                                                                  street_address: "address_full_match", state: nil, zip_code: "9103401",
                                                                  country: "Israel", individual_tax_id: nil) end
      let(:bank_account) { create(:israel_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "IL",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "ils",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Jerusalem",
              state: nil,
              postal_code: "9103401",
              country: "IL"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "IL",
            currency: "ils",
            account_number: "IL620108000000099999999"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("IL")
        expect(merchant_account.currency).to eq("ils")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a TT individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Port of Spain",
                                                                  street_address: "address_full_match", state: nil, zip_code: "150123",
                                                                  country: "Trinidad and Tobago", individual_tax_id: nil) end
      let(:bank_account) { create(:trinidad_and_tobago_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "TT",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "ttd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Port of Spain",
              state: nil,
              postal_code: "150123",
              country: "TT"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "TT",
            currency: "ttd",
            routing_number: "99900001",
            account_number: "00567890123456789",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("TT")
        expect(merchant_account.currency).to eq("ttd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a PH individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Manila",
                                                                  street_address: "address_full_match", state: nil, zip_code: "1002",
                                                                  country: "Philippines", individual_tax_id: nil) end
      let(:bank_account) { create(:philippines_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "PH",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "php",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Manila",
              state: nil,
              postal_code: "1002",
              country: "PH"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "PH",
            currency: "php",
            routing_number: "BCDEPHM1123",
            account_number: "01567890123456789",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("PH")
        expect(merchant_account.currency).to eq("php")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Ghanaian individual" do
      let(:user_compliance_info) do
        create(:user_compliance_info, user:, city: "Accra",
                                      street_address: "address_full_match", state: nil, zip_code: "00233",
                                      country: "Ghana", individual_tax_id: nil) end
      let(:bank_account) { create(:ghana_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "GH",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "ghs",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Accra",
              state: nil,
              postal_code: "00233",
              country: "GH"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "GH",
            currency: "ghs",
            account_number: "000123456789",
            routing_number: "022112"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("GH")
        expect(merchant_account.currency).to eq("ghs")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an RO individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "bucharest",
                                                                  street_address: "address_full_match", state: nil, zip_code: "010051",
                                                                  country: "Romania") end
      let(:bank_account) { create(:romania_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "RO",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          default_currency: "ron",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "bucharest",
              state: nil,
              postal_code: "010051",
              country: "RO"
            },
            id_number: "000000000",
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "RO",
            currency: "ron",
            account_number: "RO49AAAA1B31007593840000",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("RO")
        expect(merchant_account.currency).to eq("ron")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a GI individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Gibraltar",
                                                                  street_address: "address_full_match", state: nil, zip_code: "GX11 1AA",
                                                                  country: "Gibraltar") end
      let(:bank_account) { create(:gibraltar_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "GI",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          default_currency: "gbp",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Gibraltar",
              state: nil,
              postal_code: "GX11 1AA",
              country: "GI"
            },
            id_number: "000000000",
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "GI",
            currency: "gbp",
            account_number: "00012345",
            routing_number: "108800",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("GI")
        expect(merchant_account.currency).to eq("gbp")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a SE individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "stockholm",
                                                                  street_address: "address_full_match", state: nil, zip_code: "10465",
                                                                  country: "Sweden") end
      let(:bank_account) { create(:sweden_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "SE",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          default_currency: "sek",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "stockholm",
              state: nil,
              postal_code: "10465",
              country: "SE"
            },
            id_number: "000000000",
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "SE",
            currency: "sek",
            account_number: "SE3550000000054910000003",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("SE")
        expect(merchant_account.currency).to eq("sek")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a MEX business" do
      let(:user_compliance_info) { create(:user_compliance_info_mex_business, user:) }
      let(:bank_account) { create(:mexico_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          country: "MX",
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          business_type: "company",
          company: {
            name: "Buy More, LLC",
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Mexico City",
              state: "Estado de México",
              postal_code: "01000",
              country: "MX"
            },
            tax_id: "000000000000",
            phone: "0000000000",
            directors_provided: true,
            executives_provided: true
          },
          default_currency: "mxn",
          bank_account: {
            country: "MX",
            currency: "mxn",
            account_number: "000000001234567897"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      let(:expected_person_params) do
        {
          address: {
            line1: "address_full_match",
            line2: nil,
            city: "Mexico City",
            state: "Estado de México",
            postal_code: "01000",
            country: "MX"
          },
          id_number: "000000000",
          dob: { day: 1, month: 1, year: 1901 },
          first_name: "Chuck",
          last_name: "Bartowski",
          phone: "0000000000",
          email: user.email,
          relationship: { representative: true, owner: true, title: "CEO", percent_ownership: 100 }
        }
      end

      it "creates an account at stripe with all the params" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original
        expect(Stripe::Account).to receive(:create_person).with(anything, expected_person_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
      end
    end

    describe "all info provided of an AR individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Buenos Aires",
                                                                  street_address: "address_full_match", state: nil, zip_code: "1001",
                                                                  country: "Argentina", individual_tax_id: "00-00000000-0") end
      let(:bank_account) { create(:argentina_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "AR",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "ars",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Buenos Aires",
              state: nil,
              postal_code: "1001",
              country: "AR"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
            id_number: "00-00000000-0",
          },
          bank_account: {
            country: "AR",
            currency: "ars",
            account_number: "0110000600000000000000",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("AR")
        expect(merchant_account.currency).to eq("ars")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Bosnia and Herzegovina individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Sarajevo",
                                                                  street_address: "address_full_match", state: nil, zip_code: "71000",
                                                                  country: "Bosnia and Herzegovina", individual_tax_id: nil) end
      let(:bank_account) { create(:bosnia_and_herzegovina_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "BA",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "bam",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Sarajevo",
              state: nil,
              postal_code: "71000",
              country: "BA"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "BA",
            currency: "bam",
            account_number: "BA095520001234567812",
            routing_number: "AAAABABAXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("BA")
        expect(merchant_account.currency).to eq("bam")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end


    describe "all info provided of an PE individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Lima",
                                                                  street_address: "address_full_match", state: nil, zip_code: "15074",
                                                                  country: "Peru", individual_tax_id: "00000000-0") end
      let(:bank_account) { create(:peru_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "PE",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "pen",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Lima",
              state: nil,
              postal_code: "15074",
              country: "PE"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
            id_number: "00000000-0",
          },
          bank_account: {
            country: "PE",
            currency: "pen",
            account_number: "99934500012345670024",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("PE")
        expect(merchant_account.currency).to eq("pen")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an Rwanda individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Kigali", zip_code: "43200",
                                                                  street_address: "address_full_match", state: nil,
                                                                  country: "Rwanda", individual_tax_id: nil) end
      let(:bank_account) { create(:rwanda_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "RW",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "rwf",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Kigali",
              postal_code: "43200",
              state: nil,
              country: "RW"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "RW",
            currency: "rwf",
            account_number: "000123456789",
            routing_number: "AAAARWRWXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("RW")
        expect(merchant_account.currency).to eq("rwf")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an Norwegian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Oslo",
                                                                  street_address: "address_full_match", state: nil, zip_code: "0139",
                                                                  country: "Norway", individual_tax_id: nil) end
      let(:bank_account) { create(:norway_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "NO",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          default_currency: "nok",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Oslo",
              state: nil,
              postal_code: "0139",
              country: "NO"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "NO",
            currency: "nok",
            account_number: "NO9386011117947",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("NO")
        expect(merchant_account.currency).to eq("nok")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Botswana individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Gaborone", zip_code: nil,
                                                                  street_address: "address_full_match", state: nil,
                                                                  country: "Botswana", individual_tax_id: nil) end
      let(:bank_account) { create(:botswana_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "BW",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "bwp",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Gaborone",
              state: nil,
              postal_code: nil,
              country: "BW"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "BW",
            currency: "bwp",
            account_number: "000123456789",
            routing_number: "AAAABWBWXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("BW")
        expect(merchant_account.currency).to eq("bwp")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Gambia individual" do
      # Gambia has no postal codes in its official addressing format, so the seller never provides
      # one and the address Stripe receives carries a nil postal_code.
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Banjul", zip_code: nil,
                                                                  street_address: "address_full_match", state: nil,
                                                                  country: "Gambia", individual_tax_id: nil) end
      let(:bank_account) { create(:gambia_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "GM",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "gmd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Banjul",
              state: nil,
              postal_code: nil,
              country: "GM"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "GM",
            currency: "gmd",
            account_number: "000123000456000789",
            routing_number: "AAAAGMGMXYZ"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("GM")
        expect(merchant_account.currency).to eq("gmd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an Liechtenstein individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Vaduz",
                                                                  street_address: "address_full_match", state: nil, zip_code: "0139",
                                                                  country: "Liechtenstein", individual_tax_id: nil) end
      let(:bank_account) { create(:liechtenstein_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "LI",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          default_currency: "chf",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Vaduz",
              state: nil,
              postal_code: "0139",
              country: "LI"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "LI",
            currency: "chf",
            account_number: "LI0508800636123378777",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: true
            }
          },
          requested_capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("LI")
        expect(merchant_account.currency).to eq("chf")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Antigua and Barbuda individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "AnB City",
                                                                  street_address: "address_full_match", state: nil, zip_code: "43200",
                                                                  country: "Antigua and Barbuda", individual_tax_id: nil) end
      let(:bank_account) { create(:antigua_and_barbuda_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "AG",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "xcd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "AnB City",
              state: nil,
              postal_code: "43200",
              country: "AG"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "AG",
            currency: "xcd",
            account_number: "000123456789",
            routing_number: "AAAAAGAGXYZ"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("AG")
        expect(merchant_account.currency).to eq("xcd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Tanzanian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Tanzania City",
                                                                  street_address: "address_full_match", state: nil, zip_code: "43200",
                                                                  country: "Tanzania", individual_tax_id: nil) end
      let(:bank_account) { create(:tanzania_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "TZ",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "tzs",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Tanzania City",
              state: nil,
              postal_code: "43200",
              country: "TZ"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "TZ",
            currency: "tzs",
            account_number: "0000123456789",
            routing_number: "AAAATZTXXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("TZ")
        expect(merchant_account.currency).to eq("tzs")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Namibian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Namibia City",
                                                                  street_address: "address_full_match", state: nil, zip_code: "43200",
                                                                  country: "Namibia", individual_tax_id: nil) end
      let(:bank_account) { create(:namibia_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "NA",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "nad",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Namibia City",
              state: nil,
              postal_code: "43200",
              country: "NA"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "NA",
            currency: "nad",
            account_number: "000123456789",
            routing_number: "AAAANANXXYZ"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("NA")
        expect(merchant_account.currency).to eq("nad")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Moroccan individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Rabat",
                                                                  street_address: "address_full_match", state: nil, zip_code: "10020",
                                                                  country: "Morocco", individual_tax_id: nil) end
      let(:bank_account) { create(:morocco_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "MA",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "mad",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Rabat",
              state: nil,
              postal_code: "10020",
              country: "MA"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "MA",
            currency: "mad",
            account_number: "MA64011519000001205000534921",
            routing_number: "AAAAMAMAXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("MA")
        expect(merchant_account.currency).to eq("mad")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Serbian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Belgrade",
                                                                  street_address: "address_full_match", state: nil, zip_code: "11000",
                                                                  country: "Serbia", individual_tax_id: nil) end
      let(:bank_account) { create(:serbia_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "RS",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "rsd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Belgrade",
              state: nil,
              postal_code: "11000",
              country: "RS"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "RS",
            currency: "rsd",
            account_number: "RS35105008123123123173",
            routing_number: "TESTSERBXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("RS")
        expect(merchant_account.currency).to eq("rsd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Malaysian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Kuala Lumpur",
                                                                  street_address: "address_full_match", state: nil, zip_code: "43200",
                                                                  country: "Malaysia", individual_tax_id: nil) end
      let(:bank_account) { create(:malaysia_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "MY",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "myr",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Kuala Lumpur",
              state: nil,
              postal_code: "43200",
              country: "MY"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "MY",
            currency: "myr",
            account_number: "000123456000",
            routing_number: "HBMBMYKL"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("MY")
        expect(merchant_account.currency).to eq("myr")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an Albanian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Albania",
                                                                  street_address: "address_full_match", state: nil, zip_code: "43200",
                                                                  country: "Albania", individual_tax_id: nil) end
      let(:bank_account) { create(:albania_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "AL",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "all",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Albania",
              state: nil,
              postal_code: "43200",
              country: "AL"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "AL",
            currency: "all",
            account_number: "AL35202111090000000001234567",
            routing_number: "AAAAALTXXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("AL")
        expect(merchant_account.currency).to eq("all")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Angola individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "angola",
                                                                  street_address: "address_full_match", state: nil, zip_code: "43200",
                                                                  country: "Angola", individual_tax_id: nil) end
      let(:bank_account) { create(:angola_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "AO",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "aoa",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "angola",
              state: nil,
              postal_code: "43200",
              country: "AO"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "AO",
            currency: "aoa",
            account_number: "AO06004400006729503010102",
            routing_number: "AAAAAOAOXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("AO")
        expect(merchant_account.currency).to eq("aoa")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Niger individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "niger",
                                                                  street_address: "address_full_match", state: nil, zip_code: "1001",
                                                                  country: "Niger", individual_tax_id: nil) end
      let(:bank_account) { create(:niger_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "NE",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "xof",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "niger",
              state: nil,
              postal_code: "1001",
              country: "NE"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "NE",
            currency: "xof",
            account_number: "NE58NE0380100100130305000268",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("NE")
        expect(merchant_account.currency).to eq("xof")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a San Marino individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "sm",
                                                                  street_address: "address_full_match", state: nil, zip_code: "43200",
                                                                  country: "San Marino", individual_tax_id: nil) end
      let(:bank_account) { create(:san_marino_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "SM",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "eur",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "sm",
              state: nil,
              postal_code: "43200",
              country: "SM"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "SM",
            currency: "eur",
            account_number: "SM86U0322509800000000270100",
            routing_number: "AAAASMSMXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("SM")
        expect(merchant_account.currency).to eq("eur")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Bahraini individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Bahrain",
                                                                  street_address: "address_full_match", state: nil, zip_code: "43200",
                                                                  country: "Bahrain", individual_tax_id: nil) end
      let(:bank_account) { create(:bahrain_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "BH",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "bhd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Bahrain",
              state: nil,
              postal_code: "43200",
              country: "BH"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "BH",
            currency: "bhd",
            account_number: "BH29BMAG1299123456BH00",
            routing_number: "AAAABHBMXYZ"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("BH")
        expect(merchant_account.currency).to eq("bhd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Bangladeshi individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "dhaka", nationality: "BD",
                                                                  street_address: "address_full_match", state: nil, zip_code: "1100",
                                                                  country: "Bangladesh", individual_tax_id: "000000000") end
      let(:bank_account) { create(:bangladesh_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "BD",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "bdt",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "dhaka",
              state: nil,
              postal_code: "1100",
              country: "BD"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
            id_number: "000000000",
            nationality: "BD",
          },
          bank_account: {
            country: "BD",
            currency: "bdt",
            account_number: "0000123456789",
            routing_number: "110000000"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("BD")
        expect(merchant_account.currency).to eq("bdt")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Bhutan individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "bhutan",
                                                                  street_address: "address_full_match", state: nil, zip_code: "43200",
                                                                  country: "Bhutan", individual_tax_id: nil) end
      let(:bank_account) { create(:bhutan_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "BT",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "btn",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "bhutan",
              state: nil,
              postal_code: "43200",
              country: "BT"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "BT",
            currency: "btn",
            account_number: "0000123456789",
            routing_number: "AAAABTBTXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("BT")
        expect(merchant_account.currency).to eq("btn")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Laos individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "laos",
                                                                  street_address: "address_full_match", state: nil, zip_code: "43200",
                                                                  country: "Laos", individual_tax_id: nil) end
      let(:bank_account) { create(:laos_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "LA",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "lak",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "laos",
              state: nil,
              postal_code: "43200",
              country: "LA"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "LA",
            currency: "lak",
            account_number: "000123456789",
            routing_number: "AAAALALAXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("LA")
        expect(merchant_account.currency).to eq("lak")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Mozambique individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "mz",
                                                                  street_address: "address_full_match", state: nil, zip_code: "43200",
                                                                  country: "Mozambique", individual_tax_id: "000000000") end
      let(:bank_account) { create(:mozambique_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "MZ",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "mzn",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "mz",
              state: nil,
              postal_code: "43200",
              country: "MZ"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
            id_number: "000000000",
          },
          bank_account: {
            country: "MZ",
            currency: "mzn",
            account_number: "001234567890123456789",
            routing_number: "AAAAMZMXXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("MZ")
        expect(merchant_account.currency).to eq("mzn")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Nigerian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Nigeria",
                                                                  street_address: "address_full_match", state: nil, zip_code: "43200",
                                                                  country: "Nigeria", individual_tax_id: nil) end
      let(:bank_account) { create(:nigeria_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "NG",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "ngn",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Nigeria",
              state: nil,
              postal_code: "43200",
              country: "NG"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "NG",
            currency: "ngn",
            account_number: "1111111112",
            routing_number: "AAAANGLAXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("NG")
        expect(merchant_account.currency).to eq("ngn")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Jordanian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Jordan",
                                                                  street_address: "address_full_match", state: nil, zip_code: "43200",
                                                                  country: "Jordan", individual_tax_id: nil) end
      let(:bank_account) { create(:jordan_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "JO",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "jod",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Jordan",
              state: nil,
              postal_code: "43200",
              country: "JO"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "JO",
            currency: "jod",
            account_number: "JO32ABCJ0010123456789012345678",
            routing_number: "AAAAJOJOXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("JO")
        expect(merchant_account.currency).to eq("jod")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Azerbaijani individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Azerbaijan",
                                                                  street_address: "address_full_match", state: nil, zip_code: "43200",
                                                                  country: "Azerbaijan", individual_tax_id: nil) end
      let(:bank_account) { create(:azerbaijan_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "AZ",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "azn",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Azerbaijan",
              state: nil,
              postal_code: "43200",
              country: "AZ"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "AZ",
            currency: "azn",
            account_number: "AZ77ADJE12345678901234567890",
            routing_number: "123456-123456"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("AZ")
        expect(merchant_account.currency).to eq("azn")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Paraguayan individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Asunción",
                                                                  zip_code: "001001", state: nil, country: "Paraguay",
                                                                  individual_tax_id: nil) end
      let(:bank_account) { create(:paraguay_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "PY",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "pyg",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Asunción",
              state: nil,
              postal_code: "001001",
              country: "PY"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "PY",
            currency: "pyg",
            account_number: "0567890123456789",
            routing_number: "0"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("PY")
        expect(merchant_account.currency).to eq("pyg")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an Omani individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Muscat",
                                                                  street_address: "address_full_match", state: nil, zip_code: "100",
                                                                  country: "Oman", individual_tax_id: nil) end
      let(:bank_account) { create(:oman_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "OM",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "omr",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Muscat",
              state: nil,
              postal_code: "100",
              country: "OM"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "OM",
            currency: "omr",
            account_number: "000123456789",
            routing_number: "AAAAOMOMXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("OM")
        expect(merchant_account.currency).to eq("omr")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an Armenian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Yerevan",
                                                                  street_address: "address_full_match", state: nil, zip_code: "0010",
                                                                  country: "Armenia", individual_tax_id: nil) end
      let(:bank_account) { create(:armenia_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "AM",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "amd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Yerevan",
              state: nil,
              postal_code: "0010",
              country: "AM"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "AM",
            currency: "amd",
            account_number: "00001234567",
            routing_number: "AAAAAMNNXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("AM")
        expect(merchant_account.currency).to eq("amd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Sri Lankan individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Colombo",
                                                                  street_address: "address_full_match", state: nil, zip_code: "00100",
                                                                  country: "Sri Lanka", individual_tax_id: nil) end
      let(:bank_account) { create(:sri_lanka_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "LK",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "lkr",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Colombo",
              state: nil,
              postal_code: "00100",
              country: "LK"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "LK",
            currency: "lkr",
            account_number: "0000012345",
            routing_number: "AAAALKLXXXX-7010999",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("LK")
        expect(merchant_account.currency).to eq("lkr")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Kuwaiti individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Kuwait city",
                                                                  street_address: "address_full_match", state: nil, zip_code: "12345",
                                                                  country: "Kuwait", individual_tax_id: nil) end
      let(:bank_account) { create(:kuwait_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "KW",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "kwd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Kuwait city",
              state: nil,
              postal_code: "12345",
              country: "KW"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "KW",
            currency: "kwd",
            account_number: "KW81CBKU0000000000001234560101",
            routing_number: "AAAAKWKWXYZ"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("KW")
        expect(merchant_account.currency).to eq("kwd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Qatari individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Doha",
                                                                  street_address: "address_full_match", state: nil, zip_code: "12345",
                                                                  country: "Qatar", individual_tax_id: nil) end
      let(:bank_account) { create(:qatar_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "QA",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "qar",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Doha",
              state: nil,
              postal_code: "12345",
              country: "QA"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "QA",
            currency: "qar",
            account_number: "QA87CITI123456789012345678901",
            routing_number: "AAAAQAQAXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("QA")
        expect(merchant_account.currency).to eq("qar")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Bahamas individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Nassau",
                                                                  street_address: "address_full_match", state: nil, zip_code: "12345",
                                                                  country: "Bahamas", individual_tax_id: nil) end
      let(:bank_account) { create(:bahamas_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "BS",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "bsd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Nassau",
              state: nil,
              postal_code: "12345",
              country: "BS"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "BS",
            currency: "bsd",
            account_number: "0001234",
            routing_number: "AAAABSNSXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("BS")
        expect(merchant_account.currency).to eq("bsd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an Icelandic individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Reykjavik",
                                                                  street_address: "address_full_match", state: nil, zip_code: "43200",
                                                                  country: "Iceland", individual_tax_id: nil) end
      let(:bank_account) { create(:iceland_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "IS",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "eur",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Reykjavik",
              state: nil,
              postal_code: "43200",
              country: "IS"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "IS",
            currency: "eur",
            account_number: "IS140159260076545510730339",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("IS")
        expect(merchant_account.currency).to eq("eur")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Saint Lucian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Castries",
                                                                  street_address: "address_full_match", state: nil, zip_code: "LC01 101",
                                                                  country: "Saint Lucia", individual_tax_id: nil) end
      let(:bank_account) { create(:saint_lucia_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "LC",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "xcd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Castries",
              state: nil,
              postal_code: "LC01 101",
              country: "LC"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "LC",
            currency: "xcd",
            account_number: "000123456789",
            routing_number: "AAAALCLCXYZ"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("LC")
        expect(merchant_account.currency).to eq("xcd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Cambodian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Phnom Penh",
                                                                  street_address: "address_full_match", state: nil, zip_code: "12000",
                                                                  country: "Cambodia", individual_tax_id: nil) end
      let(:bank_account) { create(:cambodia_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "KH",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "khr",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Phnom Penh",
              state: nil,
              postal_code: "12000",
              country: "KH"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "KH",
            currency: "khr",
            account_number: "000123456789",
            routing_number: "AAAAKHKHXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("KH")
        expect(merchant_account.currency).to eq("khr")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Mongolian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Ulaanbaatar",
                                                                  street_address: "address_full_match", state: nil, zip_code: "14200",
                                                                  country: "Mongolia", individual_tax_id: nil) end
      let(:bank_account) { create(:mongolia_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "MN",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "mnt",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Ulaanbaatar",
              state: nil,
              postal_code: "14200",
              country: "MN"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "MN",
            currency: "mnt",
            account_number: "0002222001",
            routing_number: "AAAAMNUBXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("MN")
        expect(merchant_account.currency).to eq("mnt")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of an Algerian individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Algiers",
                                                                  street_address: "address_full_match", state: nil, zip_code: "16000",
                                                                  country: "Algeria", individual_tax_id: nil) end
      let(:bank_account) { create(:algeria_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "DZ",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "dzd",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Algiers",
              state: nil,
              postal_code: "16000",
              country: "DZ"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "DZ",
            currency: "dzd",
            account_number: "00001234567890123456",
            routing_number: "AAAADZDZXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("DZ")
        expect(merchant_account.currency).to eq("dzd")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Macao individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Macao",
                                                                  street_address: "address_full_match", state: nil, zip_code: "999078",
                                                                  country: "Macao", individual_tax_id: nil) end
      let(:bank_account) { create(:macao_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "MO",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "mop",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Macao",
              state: nil,
              postal_code: "999078",
              country: "MO"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "MO",
            currency: "mop",
            account_number: "0000000001234567897",
            routing_number: "AAAAMOMXXXX"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("MO")
        expect(merchant_account.currency).to eq("mop")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Benin individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Cotonou",
                                                                  street_address: "address_full_match", state: nil, zip_code: "00229",
                                                                  country: "Benin", individual_tax_id: nil) end
      let(:bank_account) { create(:benin_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "BJ",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "xof",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Cotonou",
              state: nil,
              postal_code: "00229",
              country: "BJ"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "BJ",
            currency: "xof",
            account_number: "BJ66BJ0610100100144390000769"
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("BJ")
        expect(merchant_account.currency).to eq("xof")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "all info provided of a Cote d'Ivoire individual" do
      let(:user_compliance_info) do create(:user_compliance_info, user:, city: "Abidjan",
                                                                  street_address: "address_full_match", state: nil, zip_code: "00225",
                                                                  country: "Cote d'Ivoire", individual_tax_id: nil) end
      let(:bank_account) { create(:cote_d_ivoire_bank_account, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
      end

      let(:expected_account_params) do
        {
          type: "custom",
          country: "CI",
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info.external_id,
            bank_account_id: bank_account.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          default_currency: "xof",
          business_type: "individual",
          business_profile: {
            name: user_compliance_info.legal_entity_name,
            url: user.business_profile_url,
            product_description: user_compliance_info.legal_entity_name
          },
          individual: {
            address: {
              line1: "address_full_match",
              line2: nil,
              city: "Abidjan",
              state: nil,
              postal_code: "00225",
              country: "CI"
            },
            dob: { day: 1, month: 1, year: 1901 },
            first_name: "Chuck",
            last_name: "Bartowski",
            phone: "0000000000",
            email: user.email,
          },
          bank_account: {
            country: "CI",
            currency: "xof",
            account_number: "CI93CI0080111301134291200589",
          },
          settings: {
            payouts: {
              schedule: {
                interval: "manual"
              },
              debit_negative_balances: false
            }
          },
          requested_capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES
        }
      end

      it "creates an account at stripe with all the params and returns the corresponding merchant account" do
        expect(Stripe::Account).to receive(:create).with(expected_account_params).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
        expect(merchant_account.charge_processor_merchant_id).to be_present
        expect(merchant_account.country).to eq("CI")
        expect(merchant_account.currency).to eq("xof")
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end
    end

    describe "user doesn't have a country specified" do
      let(:user_compliance_info) { create(:user_compliance_info, user:, country: nil) }

      before do
        user_compliance_info
      end

      it "raises a user not ready error" do
        expect { subject.create_account(user, passphrase: "1234") }.to raise_error(MerchantRegistrationUserNotReadyError)
      end
    end

    describe "user's country doesn't have a default currency" do
      let(:user_compliance_info) { create(:user_compliance_info, user:, country: "CZ") }

      before do
        user_compliance_info
      end

      it "raises a user not ready error" do
        expect { subject.create_account(user, passphrase: "1234") }.to raise_error(MerchantRegistrationUserNotReadyError)
      end
    end

    describe "user has an invalid bank account" do
      let(:user_compliance_info) { create(:user_compliance_info, user:, city: "London", zip_code: "WC2N 5DU", state: nil, country: "United Kingdom") }
      let(:bank_account) { create(:ach_account_stripe_succeed, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        tos_agreement

        allow(Stripe::Account).to receive(:create).and_raise(Stripe::InvalidRequestError.new("Invalid account number", "invalid_account_number"))
      end

      it "throws an error" do
        expect do
          subject.create_account(user, passphrase: "1234")
        end.to raise_error(Stripe::InvalidRequestError)
        expect(user.merchant_accounts.alive.count).to eq(0)
      end
    end

    describe "Stripe account cleanup when create_person fails" do
      let(:user_compliance_info) { create(:user_compliance_info_business, user:) }
      let(:bank_account) { create(:ach_account_stripe_succeed, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }
      let(:fake_stripe_account) { Stripe::Account.construct_from(id: "acct_fake_123", object: "account") }

      before do
        user_compliance_info
        bank_account
        tos_agreement

        allow(Stripe::Account).to receive(:create).and_return(fake_stripe_account)
        allow(Stripe::Account).to receive(:create_person).and_raise(Stripe::InvalidRequestError.new("person creation failed", "person"))
        allow(ErrorNotifier).to receive(:notify)
      end

      it "deletes the Stripe account and marks the merchant account as deleted" do
        expect(Stripe::Account).to receive(:delete).with("acct_fake_123")

        expect do
          subject.create_account(user, passphrase: "1234")
        end.to raise_error(Stripe::InvalidRequestError)
        expect(user.merchant_accounts.alive.count).to eq(0)
      end

      it "still marks the merchant account as deleted when Stripe account deletion fails" do
        allow(Stripe::Account).to receive(:delete).and_raise(Stripe::APIError.new("cleanup failed"))

        expect do
          subject.create_account(user, passphrase: "1234")
        end.to raise_error(Stripe::InvalidRequestError)
        expect(user.merchant_accounts.alive.count).to eq(0)
        expect(ErrorNotifier).to have_received(:notify).at_least(:twice)
      end
    end

    describe "user doesn't have compliance info" do
      it "raises a user not ready error" do
        expect { subject.create_account(user, passphrase: "1234") }.to raise_error(MerchantRegistrationUserNotReadyError)
      end
    end

    describe "user doesn't have all required compliance info" do
      before do
        create(:user_compliance_info_empty, user:)
      end

      it "raises a user not ready error" do
        expect { subject.create_account(user, passphrase: "1234") }.to raise_error(MerchantRegistrationUserNotReadyError)
      end
    end

    describe "user has not agreed to TOS" do
      before do
        create(:user_compliance_info, user:)
      end

      it "raises a user not ready error" do
        expect { subject.create_account(user, passphrase: "1234") }.to raise_error(MerchantRegistrationUserNotReadyError)
      end
    end

    describe "user already has a stripe merchant account" do
      let(:user_compliance_info) { create(:user_compliance_info, user:) }
      let(:bank_account) { create(:ach_account_stripe_succeed, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        tos_agreement
        subject.create_account(user, passphrase: "1234")
      end

      describe "create account is called a second time" do
        it "raises error" do
          expect { subject.create_account(user, passphrase: "1234") }.to raise_error(MerchantRegistrationUserAlreadyHasAccountError)
        end

        it "raises error even if charge_processor_alive_at is nil for the existing merchant account" do
          existing_merchant_account = user.merchant_accounts.alive.last
          existing_merchant_account.update!(charge_processor_alive_at: nil)
          expect { subject.create_account(user, passphrase: "1234") }.to raise_error(MerchantRegistrationUserAlreadyHasAccountError)
        end

        it "allows admin to create another account if the existing account does not have charge_processor_alive_at timestamp set" do
          existing_merchant_account = user.merchant_accounts.alive.last
          existing_merchant_account.update!(charge_processor_alive_at: nil)
          expect { subject.create_account(user, passphrase: "1234", from_admin: true) }.not_to raise_error
          expect(user.merchant_accounts.alive.count).to be(2)
          expect(user.merchant_accounts.alive.last.charge_processor_alive_at).not_to be(nil)
        end
      end
    end

    describe "user has a stale leftover merchant account with no Stripe id" do
      let(:user) { create(:user) }
      let(:user_compliance_info) { create(:user_compliance_info, user:) }
      let(:bank_account) { create(:ach_account_stripe_succeed, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        user_compliance_info
        bank_account
        tos_agreement
        create(:merchant_account, user:, charge_processor_merchant_id: nil, charge_processor_alive_at: nil, created_at: 1.year.ago)
      end

      it "discards the leftover row and creates a real account" do
        expect { subject.create_account(user, passphrase: "1234") }.not_to raise_error
        expect(user.reload.stripe_account).to be_present
        expect(user.merchant_accounts.alive.stripe.count).to eq(1)
        expect(user.stripe_account.charge_processor_merchant_id).to be_present
      end
    end
  end

  describe "#update_account" do
    describe "all info provided" do
      let(:user_compliance_info_1) { create(:user_compliance_info, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }
      let(:merchant_account) { subject.create_account(user, passphrase: "1234") }
      let(:user_compliance_info_2) { create(:user_compliance_info, user:, city: "Palo Alto") }

      before do
        user_compliance_info_1
        create(:ach_account_stripe_succeed, user:)
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
        merchant_account
        user_compliance_info_2

        original_stripe_account_retrieve = Stripe::Account.method(:retrieve)
        expect(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id) do |*args|
          stripe_account = original_stripe_account_retrieve.call(*args)
          stripe_account["metadata"]["user_compliance_info_id"] = user_compliance_info_1.external_id
          stripe_account
        end
      end

      let(:expected_account_params) do
        {
          business_profile: {
            name: user_compliance_info_2.legal_entity_name,
            product_description: user_compliance_info_2.legal_entity_name,
            url: user.business_profile_url
          },
          individual: {
            address: {
              city: "Palo Alto"
            },
            email: "chuck@gum.com",
            phone: "0000000000"
          },
          metadata: {
            user_compliance_info_id: user_compliance_info_2.external_id,
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
          capabilities: StripeMerchantAccountManager::REQUESTED_CAPABILITIES.map(&:to_sym).index_with { |capability| { requested: true } }
        }
      end

      it "updates an account at stripe with just the params that have changed" do
        expect(Stripe::Account).to receive(:update).with(user.stripe_account.charge_processor_merchant_id, expected_account_params).and_call_original
        subject.update_account(user, passphrase: "1234")
      end

      context "when user compliance info contains whitespaces" do
        let(:user_compliance_info_2) do
          create(:user_compliance_info,
                 user:,
                 first_name: "  Chuck  ",
                 last_name: "  Bartowski  ",
                 street_address: " address_full_match",
                 zip_code: " 94107 ",
                 city: " Palo Alto ")
        end

        it "strips out params whitespaces" do
          expect(Stripe::Account).to receive(:update).with(user.stripe_account.charge_processor_merchant_id, expected_account_params).and_call_original
          subject.update_account(user, passphrase: "1234")
        end
      end
    end

    describe "all info provided for a creator in a cross-border payout country" do
      let(:user_compliance_info_1) { create(:user_compliance_info, user:, country: "Korea, Republic of") }
      let(:tos_agreement) { create(:tos_agreement, user:) }
      let(:merchant_account) { subject.create_account(user, passphrase: "1234") }
      let(:user_compliance_info_2) { create(:user_compliance_info, user:, country: "Korea, Republic of", city: "Seoul") }

      before do
        user_compliance_info_1
        create(:korea_bank_account, user:)
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
        merchant_account
        user_compliance_info_2
      end

      let(:expected_account_params) do
        {
          business_profile: {
            name: user_compliance_info_2.legal_entity_name,
            product_description: user_compliance_info_2.legal_entity_name,
            url: user.business_profile_url
          },
          individual: {
            address: {
              city: "Seoul"
            },
            email: "chuck@gum.com",
            phone: "0000000000"
          },
          metadata: {
            user_compliance_info_id: user_compliance_info_2.external_id,
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13", service_agreement: "recipient" },
          capabilities: StripeMerchantAccountManager::CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES.map(&:to_sym).index_with { |capability| { requested: true } }
        }
      end

      it "updates an account at stripe with just the params that have changed and cross border payouts only capabilities" do
        original_stripe_account_retrieve = Stripe::Account.method(:retrieve)
        expect(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id) do |*args|
          stripe_account = original_stripe_account_retrieve.call(*args)
          stripe_account["metadata"]["user_compliance_info_id"] = user_compliance_info_1.external_id
          stripe_account
        end

        expect(Stripe::Account).to receive(:update).with(user.stripe_account.charge_processor_merchant_id, expected_account_params).and_call_original
        subject.update_account(user, passphrase: "1234")
      end
    end

    describe "when Stripe rejects the service agreement we derived from the legal-entity country" do
      let(:user_compliance_info_1) { create(:user_compliance_info, user:, country: "Korea, Republic of") }
      let(:tos_agreement) { create(:tos_agreement, user:) }
      let(:merchant_account) { subject.create_account(user, passphrase: "1234") }
      let(:user_compliance_info_2) { create(:user_compliance_info, user:, country: "Korea, Republic of", city: "Seoul") }
      let(:rejection) do
        Stripe::InvalidRequestError.new(
          "The recipient ToS agreement is not supported for platforms in US creating accounts in US.",
          nil
        )
      end

      before do
        user_compliance_info_1
        create(:korea_bank_account, user:)
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
        merchant_account
        user_compliance_info_2

        original_stripe_account_retrieve = Stripe::Account.method(:retrieve)
        allow(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id) do |*args|
          stripe_account = original_stripe_account_retrieve.call(*args)
          stripe_account["metadata"]["user_compliance_info_id"] = user_compliance_info_1.external_id
          stripe_account
        end
      end

      it "retries without the agreement so the fields Gumroad already holds still land" do
        merchant_id = user.stripe_account.charge_processor_merchant_id

        expect(Stripe::Account).to receive(:update)
          .with(merchant_id, hash_including(:tos_acceptance))
          .and_raise(rejection)
        expect(Stripe::Account).to receive(:update)
          .with(merchant_id, hash_excluding(:tos_acceptance)) do |_id, attributes|
            expect(attributes[:business_profile]).to be_present
            expect(attributes[:individual][:address][:city]).to eq("Seoul")
          end

        expect { subject.update_account(user, passphrase: "1234") }.not_to raise_error
      end

      it "leaves one private payout-note breadcrumb naming the rejection" do
        allow(Stripe::Account).to receive(:update).with(anything, hash_including(:tos_acceptance)).and_raise(rejection)
        allow(Stripe::Account).to receive(:update).with(anything, hash_excluding(:tos_acceptance))

        expect do
          2.times { subject.update_account(user, passphrase: "1234") }
        end.to change {
          user.comments.with_type_payout_note.alive
              .where("content LIKE ?", "#{StripeMerchantAccountManager::SERVICE_AGREEMENT_REJECTION_NOTE_PREFIX}%")
              .count
        }.by(1)

        note = user.comments.with_type_payout_note.alive.last
        expect(note.content).to include("recipient ToS agreement is not supported")
      end

      # Two resyncs for the same seller can both see no note before either writes one, so the
      # look-then-write has to run under the user row lock for the once-per-account rule to hold.
      it "takes the user row lock around the breadcrumb check and write" do
        allow(Stripe::Account).to receive(:update).with(anything, hash_including(:tos_acceptance)).and_raise(rejection)
        allow(Stripe::Account).to receive(:update).with(anything, hash_excluding(:tos_acceptance))

        locked = false
        allow(user).to receive(:with_lock).and_wrap_original do |original, *args, &block|
          original.call(*args) do
            locked = true
            block.call
          end
        end
        allow(user).to receive(:add_payout_note).and_wrap_original do |original, **kwargs|
          expect(locked).to be(true)
          original.call(**kwargs)
        end

        subject.update_account(user, passphrase: "1234")

        expect(user).to have_received(:add_payout_note)
      end

      it "still raises for any other invalid-request rejection" do
        other = Stripe::InvalidRequestError.new("Invalid Tax ID.", nil)
        allow(Stripe::Account).to receive(:update).and_raise(other)

        expect { subject.update_account(user, passphrase: "1234") }.to raise_error(Stripe::InvalidRequestError)
      end

      # The guard is the whole safety argument: a rejection of some OTHER part of tos_acceptance
      # must not make us drop the seller's acceptance and report success.
      it "does not retry when a different tos_acceptance field is rejected" do
        other = Stripe::InvalidRequestError.new("Invalid timestamp.", "tos_acceptance[date]")
        allow(Stripe::Account).to receive(:update).with(anything, hash_including(:tos_acceptance)).and_raise(other)
        allow(Stripe::Account).to receive(:update).with(anything, hash_excluding(:tos_acceptance))

        expect { subject.update_account(user, passphrase: "1234") }.to raise_error(other)
        expect(Stripe::Account).not_to have_received(:update).with(anything, hash_excluding(:tos_acceptance))
      end

      it "lets a rejection of the retry itself surface" do
        postal = Stripe::InvalidRequestError.new("Invalid postal code.", "individual[address][postal_code]")
        allow(Stripe::Account).to receive(:update).with(anything, hash_including(:tos_acceptance)).and_raise(rejection)
        allow(Stripe::Account).to receive(:update).with(anything, hash_excluding(:tos_acceptance)).and_raise(postal)

        expect { subject.update_account(user, passphrase: "1234") }.to raise_error(postal)
      end

      # Stripe's live rejection carries no `code` and names the field in `param`, so the param is
      # what the predicate has to key off. Probed against the test API.
      it "recognises the rejection from the param alone" do
        by_param = Stripe::InvalidRequestError.new("Some other wording", "tos_acceptance[service_agreement]")
        allow(Stripe::Account).to receive(:update).with(anything, hash_including(:tos_acceptance)).and_raise(by_param)
        allow(Stripe::Account).to receive(:update).with(anything, hash_excluding(:tos_acceptance))

        expect { subject.update_account(user, passphrase: "1234") }.not_to raise_error
        expect(Stripe::Account).to have_received(:update).with(anything, hash_excluding(:tos_acceptance))
      end

      # The agreement id is Stripe's marker that the acceptance is on file. Stripe rejected the
      # acceptance, so the retry must not move it — measured against the test API: it otherwise
      # lands on an account whose tos_acceptance is empty.
      it "does not move the ToS agreement marker on the retry" do
        allow(Stripe::Account).to receive(:update).with(anything, hash_including(:tos_acceptance)).and_raise(rejection)
        allow(Stripe::Account).to receive(:update).with(anything, hash_excluding(:tos_acceptance))

        subject.update_account(user, passphrase: "1234")

        expect(Stripe::Account).to have_received(:update).with(anything, hash_excluding(:tos_acceptance)) do |_id, attributes|
          expect(attributes[:metadata]).not_to have_key(:tos_agreement_id)
          expect(attributes[:metadata][:user_compliance_info_id]).to eq(user_compliance_info_2.external_id)
        end
      end
    end

    # Measured on a real mismatched account: peeling `tos_acceptance` off after the rejection only
    # exposes the legal-entity address as the next one (`account_country_invalid_address` on
    # `company[address][country]`), so nothing ever landed. Both are excluded up front instead.
    describe "when the Stripe account's country disagrees with the legal-entity country" do
      let(:user_compliance_info_1) { create(:user_compliance_info, user:, country: "Korea, Republic of") }
      let(:tos_agreement) { create(:tos_agreement, user:) }
      let(:merchant_account) { subject.create_account(user, passphrase: "1234") }
      let(:user_compliance_info_2) { create(:user_compliance_info, user:, country: "Korea, Republic of", city: "Seoul") }
      # The account was created in the platform's own country, which is the whole cohort.
      let(:stripe_account_country) { "US" }

      before do
        user_compliance_info_1
        create(:korea_bank_account, user:)
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
        merchant_account
        user_compliance_info_2

        original_stripe_account_retrieve = Stripe::Account.method(:retrieve)
        allow(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id) do |*args|
          stripe_account = original_stripe_account_retrieve.call(*args)
          stripe_account["metadata"]["user_compliance_info_id"] = (@last_user_compliance_info_override || user_compliance_info_1).external_id
          stripe_account["country"] = @stripe_account_country_override || stripe_account_country
          stripe_account
        end
      end

      it "sends the fields Gumroad already holds without the agreement or the legal-entity address" do
        allow(Stripe::Account).to receive(:update)

        subject.update_account(user, passphrase: "1234")

        expect(Stripe::Account).to have_received(:update).once do |_id, attributes|
          expect(attributes).not_to have_key(:tos_acceptance)
          # Asserted positively as well as negatively: dropping the whole entity hash would
          # discard email and phone, which is the regression a bare "no address" check misses.
          expect(attributes[:individual]).to be_present
          expect(attributes[:individual]).to include(:email)
          expect(attributes.fetch(:individual, {})).not_to have_key(:address)
          expect(attributes.fetch(:company, {})).not_to have_key(:address)
          expect(attributes[:business_profile]).to be_present
        end
      end

      it "does not claim a ToS agreement Stripe never accepted" do
        allow(Stripe::Account).to receive(:update)

        subject.update_account(user, passphrase: "1234")

        expect(Stripe::Account).to have_received(:update) do |_id, attributes|
          expect(attributes[:metadata]).not_to have_key(:tos_agreement_id)
          expect(attributes[:metadata][:user_compliance_info_id]).to eq(user_compliance_info_2.external_id)
        end
      end

      it "leaves one private payout-note breadcrumb naming the mismatch" do
        allow(Stripe::Account).to receive(:update)

        expect do
          2.times { subject.update_account(user, passphrase: "1234") }
        end.to change {
          user.comments.with_type_payout_note.alive
              .where("content LIKE ?", "#{StripeMerchantAccountManager::SERVICE_AGREEMENT_REJECTION_NOTE_PREFIX}%")
              .count
        }.by(1)

        note = user.comments.with_type_payout_note.alive.last
        expect(note.content).to include("does not match")
        expect(note.json_data[PayoutNoteVisibility::SELLER_VISIBLE_FLAG]).to be(false)
      end

      # The phone on these accounts is often not E.164, and that is a real problem the seller has
      # to fix. Holding back the country-validated fields must not start swallowing it.
      it "still raises for a rejection of any other field" do
        phone = Stripe::InvalidRequestError.new(%("0094776448826" is not a valid phone number), "company[phone]")
        allow(Stripe::Account).to receive(:update).and_raise(phone)

        expect { subject.update_account(user, passphrase: "1234") }.to raise_error(phone)
      end

      # The rescue retries from what was SENT, not the original diff. Keying it off the diff would
      # put the held-back address back on the wire, guaranteeing a second rejection.
      it "never restores the held-back fields on the agreement retry" do
        rejection = Stripe::InvalidRequestError.new("Some wording", "tos_acceptance[service_agreement]")
        allow(Stripe::Account).to receive(:update).and_raise(rejection)

        expect { subject.update_account(user, passphrase: "1234") }.to raise_error(rejection)

        expect(Stripe::Account).to have_received(:update).once do |_id, attributes|
          expect(attributes).not_to have_key(:tos_acceptance)
          expect(attributes.fetch(:individual, {})).not_to have_key(:address)
        end
      end

      # The guard has to be load-bearing: when the countries agree there is nothing structural to
      # hold back, and the address must still be sent.
      context "when the countries agree" do
        let(:stripe_account_country) { "KR" }

        it "sends the legal-entity address" do
          allow(Stripe::Account).to receive(:update)

          subject.update_account(user, passphrase: "1234")

          expect(Stripe::Account).to have_received(:update) do |_id, attributes|
            expect(attributes[:individual][:address][:city]).to eq("Seoul")
          end
        end
      end

      # The payload and the country it is judged against have to come from the same compliance
      # record. If a newer record goes alive mid-call, re-reading it here would compare the new
      # country against a payload built from the old one and send the address after all.
      it "judges the payload against the compliance record it was built from" do
        allow(Stripe::Account).to receive(:update)
        newly_alive = build(:user_compliance_info, user:, country: "United States")
        allow(user).to receive(:alive_user_compliance_info).and_return(user_compliance_info_2, newly_alive)

        subject.update_account(user, passphrase: "1234")

        expect(Stripe::Account).to have_received(:update).once do |_id, attributes|
          expect(attributes).not_to have_key(:tos_acceptance)
          expect(attributes.fetch(:individual, {})).not_to have_key(:address)
        end
      end

      describe "the phone Stripe validates against the account country" do
        let(:user_compliance_info_2) do
          create(:user_compliance_info, user:, country: "Korea, Republic of", city: "Seoul",
                                        phone: "+821012345678")
        end

        it "keeps the phone off the payload so the rest of the fields still land" do
          calls = []
          allow(Stripe::Account).to receive(:update) { |_id, attributes| calls << attributes }

          subject.update_account(user, passphrase: "1234")

          expect(calls).to be_present
          calls.each do |attributes|
            expect(attributes.fetch(:individual, {})).not_to have_key(:phone)
            expect(attributes.fetch(:company, {})).not_to have_key(:phone)
          end
          expect(calls.first[:individual]).to include(:email)
        end

        # The whole point of withholding it: a foreign number on a mismatched account is refused
        # with wording about the number, and the all-or-nothing API takes the payload down with it.
        it "does not raise when Stripe would reject a foreign number on the mismatched account" do
          allow(Stripe::Account).to receive(:update) do |_id, attributes|
            if attributes.dig(:individual, :phone).present? || attributes.dig(:company, :phone).present?
              raise Stripe::InvalidRequestError.new('"+821012345678" is not a valid phone number', "individual[phone]")
            end
          end

          expect { subject.update_account(user, passphrase: "1234") }.not_to raise_error
        end
      end

      # gumroad-private#1575. The address is withheld because Stripe will never accept it; an
      # identifier is different — it may be the exact thing Stripe is waiting on to lift a
      # verification requirement, so withholding it silently parks the seller. It is sent on its
      # own instead, so a rejection costs only the identifier.
      describe "identity fields Stripe validates against the account country" do
        # A changed national ID is what puts the identifier into the diff at all; without a change
        # it is diffed out and the cohort resyncs cleanly, which is why this never showed up before.
        let(:user_compliance_info_2) do
          create(:user_compliance_info, user:, country: "Korea, Republic of", city: "Seoul",
                                        individual_tax_id: "1234567890")
        end

        it "keeps the identifier off the main payload and sends it in its own call" do
          calls = []
          allow(Stripe::Account).to receive(:update) { |_id, attributes| calls << attributes }

          subject.update_account(user, passphrase: "1234")

          expect(calls.size).to eq(2)
          main, identity = calls
          # The main payload keeps everything that can land, minus the identifier.
          expect(main[:individual]).to include(:email)
          expect(main.fetch(:individual, {})).not_to have_key(:id_number)
          expect(main.fetch(:individual, {})).not_to have_key(:ssn_last_4)
          # The identifier goes alone — nothing else may ride along, or a rejection takes it down too.
          expect(identity.keys).to eq([:individual])
          expect(identity[:individual].keys).to contain_exactly(:id_number)
          expect(identity[:individual][:id_number]).to eq("1234567890")
        end

        it "still lands the rest of the payload when Stripe rejects the identifier" do
          rejection = Stripe::InvalidRequestError.new("Invalid ID number", "individual[id_number]")
          allow(Stripe::Account).to receive(:update) do |_id, attributes|
            raise rejection if attributes.dig(:individual, :id_number).present?
          end

          expect { subject.update_account(user, passphrase: "1234") }.not_to raise_error

          expect(Stripe::Account).to have_received(:update).twice
        end

        it "records the rejection as a private payout note rather than losing it" do
          rejection = Stripe::InvalidRequestError.new("Invalid ID number", "individual[id_number]")
          allow(Stripe::Account).to receive(:update) do |_id, attributes|
            raise rejection if attributes.dig(:individual, :id_number).present?
          end

          subject.update_account(user, passphrase: "1234")

          note = user.comments.with_type_payout_note.alive
                     .where("content LIKE ?", "#{StripeMerchantAccountManager::IDENTITY_REJECTION_NOTE_PREFIX}%")
                     .last
          expect(note).to be_present
          expect(note.content).to include("Invalid ID number")
          expect(note.content).to include("US")
          expect(note.json_data[PayoutNoteVisibility::SELLER_VISIBLE_FLAG]).to be(false)
        end

        # The note is the retry marker force_identity_into_diff! consults, so it must be recorded
        # even when the caller suppressed notifications — a rejection first seen on the silent
        # weekly sweep would otherwise leave no state behind and never be re-sent.
        it "records the rejection even when the caller suppressed notifications" do
          rejection = Stripe::InvalidRequestError.new("Invalid ID number", "individual[id_number]")
          allow(Stripe::Account).to receive(:update) do |_id, attributes|
            raise rejection if attributes.dig(:individual, :id_number).present?
          end

          subject.update_account(user, passphrase: "1234", notify: false)

          expect(user.comments.with_type_payout_note.alive
                     .where("content LIKE ?", "#{StripeMerchantAccountManager::IDENTITY_REJECTION_NOTE_PREFIX}%")
                     .count).to eq(1)
        end

        # The seller retries this save repeatedly; a note per attempt buries the payout notes.
        it "does not accumulate a note per retry for the same rejection" do
          rejection = Stripe::InvalidRequestError.new("Invalid ID number", "individual[id_number]")
          allow(Stripe::Account).to receive(:update) do |_id, attributes|
            raise rejection if attributes.dig(:individual, :id_number).present?
          end

          expect do
            3.times { subject.update_account(user, passphrase: "1234") }
          end.to change {
            user.comments.with_type_payout_note.alive
                .where("content LIKE ?", "#{StripeMerchantAccountManager::IDENTITY_REJECTION_NOTE_PREFIX}%")
                .count
          }.by(1)
        end

        # A stale note keeps support chasing a verification that is no longer blocked.
        it "clears the note once the identifier is accepted" do
          rejection = Stripe::InvalidRequestError.new("Invalid ID number", "individual[id_number]")
          allow(Stripe::Account).to receive(:update) do |_id, attributes|
            raise rejection if attributes.dig(:individual, :id_number).present?
          end
          subject.update_account(user, passphrase: "1234")
          expect(user.comments.with_type_payout_note.alive
                     .where("content LIKE ?", "#{StripeMerchantAccountManager::IDENTITY_REJECTION_NOTE_PREFIX}%")
                     .count).to eq(1)

          allow(Stripe::Account).to receive(:update)
          create(:user_compliance_info, user:, country: "Korea, Republic of", city: "Busan",
                                        individual_tax_id: "1234567890")

          subject.update_account(user, passphrase: "1234")

          expect(user.comments.with_type_payout_note.alive
                     .where("content LIKE ?", "#{StripeMerchantAccountManager::IDENTITY_REJECTION_NOTE_PREFIX}%")
                     .count).to eq(0)
        end

        # The two identifiers are separate Stripe requirements. Sharing one note namespace let a
        # representative success delete a company rejection that was still blocking verification.
        it "leaves the representative's rejection note alone when the seller's identifier is accepted" do
          representative_note = "#{StripeMerchantAccountManager::IDENTITY_REJECTION_NOTE_PREFIX} (representative) — still outstanding"
          user.add_payout_note(content: representative_note, seller_visible: false)
          allow(Stripe::Account).to receive(:update)

          subject.update_account(user, passphrase: "1234")

          expect(user.comments.with_type_payout_note.alive.where(content: representative_note)).to exist
        end

        # update_person is the only path that retires a representative note, and it is skipped once
        # the seller is no longer a business. Without an explicit retirement the note outlives the
        # entity it describes: support reads it as a live verification block, and it keeps
        # force_identity_into_diff! re-sending an identifier for a person Stripe is no longer asked
        # about.
        it "retires the representative's rejection note when the seller switches to an individual" do
          # last_user_compliance_info is read from the account metadata, not from the record
          # history, so the previous entity has to be staged there for the switch to be visible.
          @last_user_compliance_info_override = create(:user_compliance_info, user:, country: "Korea, Republic of", city: "Seoul",
                                                                              is_business: true, business_name: "Acme",
                                                                              business_type: UserComplianceInfo::BusinessTypes::LLC,
                                                                              business_tax_id: "9876543210")
          representative_note = user.add_payout_note(
            content: "#{StripeMerchantAccountManager::IDENTITY_REJECTION_NOTE_PREFIX} (representative) — still outstanding",
            seller_visible: false
          )
          create(:user_compliance_info, user:, country: "Korea, Republic of", city: "Seoul",
                                        individual_tax_id: "1234567890")
          allow(Stripe::Account).to receive(:update)

          subject.update_account(user, passphrase: "1234")

          expect(representative_note.reload.deleted_at).to be_present
        end

        # Two resyncs for the same seller overlap. The clear must not delete a rejection recorded
        # while its own Stripe call was in flight — that diagnostic is the only thing on the account
        # saying why the seller is still blocked.
        it "keeps a rejection recorded while the accepted call was in flight" do
          seller_prefix = "#{StripeMerchantAccountManager::IDENTITY_REJECTION_NOTE_PREFIX} (individual)"
          stale_note = user.add_payout_note(content: "#{seller_prefix} — from the previous attempt", seller_visible: false)
          concurrent_note = nil

          allow(Stripe::Account).to receive(:update) do |_id, attributes|
            if attributes.dig(:individual, :id_number).present?
              concurrent_note = user.add_payout_note(content: "#{seller_prefix} — recorded by the overlapping resync", seller_visible: false)
            end
          end

          subject.update_account(user, passphrase: "1234")

          expect(concurrent_note).to be_present
          expect(concurrent_note.reload.deleted_at).to be_nil
          expect(stale_note.reload.deleted_at).to be_present
        end

        # One combined identity call is still all-or-nothing: Stripe rejecting the individual's ID
        # would take a perfectly valid company tax ID down with it, which is the exact failure the
        # split exists to prevent.
        it "sends each entity's identifier in its own call" do
          calls = []
          allow(Stripe::Account).to receive(:update) { |_id, attributes| calls << attributes }
          allow(described_class).to receive(:only_identity_fields).and_return(
            individual: { id_number: "1234567890" }, company: { tax_id: "9876543210" }
          )

          subject.update_account(user, passphrase: "1234")

          identity_calls = calls.select { |attributes| attributes.keys.all? { |key| %i[individual company].include?(key) } && attributes.values.all? { |entity| entity.keys.all? { |key| %i[id_number ssn_last_4 tax_id].include?(key) } } }
          expect(identity_calls).to contain_exactly(
            { individual: { id_number: "1234567890" } },
            { company: { tax_id: "9876543210" } }
          )
        end

        it "still sends the accepted entity's identifier when the other is rejected" do
          sent = []
          allow(described_class).to receive(:only_identity_fields).and_return(
            individual: { id_number: "1234567890" }, company: { tax_id: "9876543210" }
          )
          allow(Stripe::Account).to receive(:update) do |_id, attributes|
            raise Stripe::InvalidRequestError.new("Invalid ID number", "individual[id_number]") if attributes.dig(:individual, :id_number).present?

            sent << attributes
          end

          subject.update_account(user, passphrase: "1234")

          expect(sent).to include(company: { tax_id: "9876543210" })
          expect(user.comments.with_type_payout_note.alive
                     .where("content LIKE ?", "#{StripeMerchantAccountManager::IDENTITY_REJECTION_NOTE_PREFIX} (individual)%")
                     .count).to eq(1)
          expect(user.comments.with_type_payout_note.alive
                     .where("content LIKE ?", "#{StripeMerchantAccountManager::IDENTITY_REJECTION_NOTE_PREFIX} (company)%")
                     .count).to eq(0)
        end

        # The isolated call swallows its rejection, so the main payload lands and the compliance
        # marker advances. Without forcing the identifier back in, the seller's next unchanged save
        # diffs the compliance record against itself and the rejected ID is never retried.
        #
        # Both specs advance the marker the way the real update does — the shared `before` pins it
        # to the first record, which would leave the identifier in the diff on its own and make
        # either assertion vacuous.
        def advance_compliance_marker!
          # Call through the group's own retrieve stub once and keep the object, rather than
          # re-wrapping it — capturing `Stripe::Account.method(:retrieve)` here would capture that
          # stub and recurse into itself.
          stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
          stripe_account["metadata"]["user_compliance_info_id"] = user_compliance_info_2.external_id
          allow(Stripe::Account).to receive(:retrieve)
            .with(merchant_account.charge_processor_merchant_id).and_return(stripe_account)
        end

        it "re-sends a rejected identifier on the next unchanged save" do
          rejection = Stripe::InvalidRequestError.new("Invalid ID number", "individual[id_number]")
          allow(Stripe::Account).to receive(:update) do |_id, attributes|
            raise rejection if attributes.dig(:individual, :id_number).present?
          end
          subject.update_account(user, passphrase: "1234")
          advance_compliance_marker!

          calls = []
          allow(Stripe::Account).to receive(:update) do |_id, attributes|
            calls << attributes
            raise rejection if attributes.dig(:individual, :id_number).present?
          end

          subject.update_account(user, passphrase: "1234")

          expect(calls.any? { |attributes| attributes.dig(:individual, :id_number) == "1234567890" }).to be(true)
        end

        # And it has to stop once Stripe accepts, or every later save pays for a pointless
        # second round-trip forever.
        it "stops re-sending once the identifier is accepted" do
          allow(Stripe::Account).to receive(:update)
          subject.update_account(user, passphrase: "1234")
          advance_compliance_marker!

          calls = []
          allow(Stripe::Account).to receive(:update) { |_id, attributes| calls << attributes }

          subject.update_account(user, passphrase: "1234")

          expect(calls.any? { |attributes| attributes.dig(:individual, :id_number).present? }).to be(false)
        end

        # The split is scoped to the mismatch. On a matched account the identifier belongs on the
        # main payload, and a second call would be a pointless extra round-trip on every save.
        context "when the countries agree" do
          let(:stripe_account_country) { "KR" }

          it "sends the identifier on the main payload in a single call" do
            allow(Stripe::Account).to receive(:update)

            subject.update_account(user, passphrase: "1234")

            expect(Stripe::Account).to have_received(:update).once do |_id, attributes|
              expect(attributes[:individual][:id_number]).to eq("1234567890")
            end
          end
        end

        # The main payload has already advanced the compliance marker by the time the isolated call
        # runs, so a call that dies without leaving a note behind is never retried at all. A
        # transport failure is exactly that case, and it is not a verdict — the caller still sees it.
        it "leaves a retry marker and re-raises when the isolated call fails without a verdict" do
          transport = Stripe::APIConnectionError.new("Connection to Stripe timed out")
          allow(Stripe::Account).to receive(:update) do |_id, attributes|
            raise transport if attributes.dig(:individual, :id_number).present?
          end

          expect { subject.update_account(user, passphrase: "1234") }.to raise_error(Stripe::APIConnectionError)

          note = user.comments.with_type_payout_note.alive
                     .where("content LIKE ?", "#{StripeMerchantAccountManager::IDENTITY_REJECTION_NOTE_PREFIX}%")
                     .last
          expect(note).to be_present
          # Support must not chase a rejection Stripe never made.
          expect(note.content).to include("before Stripe judged the ID")
          expect(note.content).not_to include("validates the ID against itself")
        end

        # The swallow is only safe on the strength of the marker existing: a verdict suppressed
        # while the note write failed leaves nothing to drive the retry, which is the permanent
        # silent drop the marker exists to prevent.
        it "re-raises the rejection when the retry marker cannot be recorded" do
          rejection = Stripe::InvalidRequestError.new("Invalid ID number", "individual[id_number]")
          allow(Stripe::Account).to receive(:update) do |_id, attributes|
            raise rejection if attributes.dig(:individual, :id_number).present?
          end
          allow(user).to receive(:add_payout_note).and_wrap_original do |original, **kwargs|
            # RecordInvalid, not a connection-flavored error: Makara reads "server has gone away"
            # as a dead primary and blacklists the pool for the rest of the process.
            raise ActiveRecord::RecordInvalid.new(Comment.new) if kwargs[:content].start_with?(StripeMerchantAccountManager::IDENTITY_REJECTION_NOTE_PREFIX)

            original.call(**kwargs)
          end

          expect { subject.update_account(user, passphrase: "1234") }.to raise_error(rejection)
        end

        # ...and that marker has to actually drive the re-send, or recording it bought nothing.
        it "re-sends an identifier whose call never returned a verdict" do
          transport = Stripe::APIConnectionError.new("Connection to Stripe timed out")
          allow(Stripe::Account).to receive(:update) do |_id, attributes|
            raise transport if attributes.dig(:individual, :id_number).present?
          end
          expect { subject.update_account(user, passphrase: "1234") }.to raise_error(Stripe::APIConnectionError)
          advance_compliance_marker!

          calls = []
          allow(Stripe::Account).to receive(:update) { |_id, attributes| calls << attributes }

          subject.update_account(user, passphrase: "1234")

          expect(calls.any? { |attributes| attributes.dig(:individual, :id_number) == "1234567890" }).to be(true)
        end

        # The isolated call only runs while the countries disagree, so once the seller corrects
        # their legal-entity country the identifier rides the main payload and this is the only
        # place left that can retire the note.
        it "clears the note when the identifier lands on the main payload after the countries agree" do
          rejection = Stripe::InvalidRequestError.new("Invalid ID number", "individual[id_number]")
          allow(Stripe::Account).to receive(:update) do |_id, attributes|
            raise rejection if attributes.dig(:individual, :id_number).present?
          end
          subject.update_account(user, passphrase: "1234")
          outstanding = -> {
            user.comments.with_type_payout_note.alive
                .where("content LIKE ?", "#{StripeMerchantAccountManager::IDENTITY_REJECTION_NOTE_PREFIX}%")
                .count
          }
          expect(outstanding.call).to eq(1)

          # The seller corrects their legal-entity country, so the account and the entity now agree.
          # Flipped through the group's own retrieve stub rather than a second `retrieve` call,
          # which would be an HTTP request the cassette does not carry.
          @stripe_account_country_override = "KR"
          allow(Stripe::Account).to receive(:update)
          advance_compliance_marker!

          subject.update_account(user, passphrase: "1234")

          expect(outstanding.call).to eq(0)
        end
      end
    end

    describe "updating business type" do
      let(:user_compliance_info_1) { create(:user_compliance_info, user:) }
      let(:tos_agreement) { create(:tos_agreement, user:) }
      let(:merchant_account) { subject.create_account(user, passphrase: "1234") }
      let(:user_compliance_info_2) { create(:user_compliance_info, user:) }

      before do
        user_compliance_info_1
        create(:ach_account_stripe_succeed, user:)
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
        merchant_account
        user_compliance_info_2
      end

      context "when updating from individual to company" do
        let(:user_compliance_info_1) { create(:user_compliance_info, user:) }
        let(:user_compliance_info_2) { create(:user_compliance_info_business, user:) }

        it "does not include individual details in the params" do
          original_stripe_account_retrieve = Stripe::Account.method(:retrieve)
          expect(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id) do |*args|
            stripe_account = original_stripe_account_retrieve.call(*args)
            stripe_account["metadata"]["user_compliance_info_id"] = user_compliance_info_1.external_id
            stripe_account
          end

          expect(Stripe::Account).to receive(:update).with(user.stripe_account.charge_processor_merchant_id, hash_not_including(:individual))
          subject.update_account(user, passphrase: "1234")
        end
      end

      context "when updating from company to individual" do
        let(:user_compliance_info_1) { create(:user_compliance_info_business, user:) }
        let(:user_compliance_info_2) { create(:user_compliance_info, user:) }

        # We need to set the company name to first and last name to make sure this is what is used for payouts
        # Ref: https://github.com/gumroad/web/issues/19882
        it "does not include company details in params and sets the company name to first and last name" do
          original_stripe_account_retrieve = Stripe::Account.method(:retrieve)
          expect(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id) do |*args|
            stripe_account = original_stripe_account_retrieve.call(*args)
            stripe_account["metadata"]["user_compliance_info_id"] = user_compliance_info_1.external_id
            stripe_account
          end

          expect(Stripe::Account).to receive(:update).with(user.stripe_account.charge_processor_merchant_id, hash_including(company: { name: user_compliance_info_2.first_and_last_name }))
          subject.update_account(user, passphrase: "1234")
        end

        context "when the previous business type was sole proprietorship" do
          let(:user_compliance_info_1) { create(:user_compliance_info_business, user:, business_type: UserComplianceInfo::BusinessTypes::SOLE_PROPRIETORSHIP) }

          it "clears the company structure in a separate call before updating business type" do
            original_stripe_account_retrieve = Stripe::Account.method(:retrieve)
            expect(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id) do |*args|
              stripe_account = original_stripe_account_retrieve.call(*args)
              stripe_account["metadata"]["user_compliance_info_id"] = user_compliance_info_1.external_id
              stripe_account
            end

            expect(Stripe::Account).to receive(:update).with(
              user.stripe_account.charge_processor_merchant_id,
              { company: { structure: "" } }
            ).ordered
            expect(Stripe::Account).to receive(:update).with(
              user.stripe_account.charge_processor_merchant_id,
              hash_including(company: { name: user_compliance_info_2.first_and_last_name })
            ).ordered

            subject.update_account(user, passphrase: "1234")
          end
        end

        context "when updating to sole proprietorship" do
          let(:user_compliance_info_1) { create(:user_compliance_info_business, user:) }
          let(:user_compliance_info_2) { create(:user_compliance_info_business, user:, business_type: UserComplianceInfo::BusinessTypes::SOLE_PROPRIETORSHIP) }

          it "includes the sole proprietorship structure in company params" do
            original_stripe_account_retrieve = Stripe::Account.method(:retrieve)
            expect(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id) do |*args|
              stripe_account = original_stripe_account_retrieve.call(*args)
              stripe_account["metadata"]["user_compliance_info_id"] = user_compliance_info_1.external_id
              stripe_account
            end

            # Mock list_persons call with a proper Stripe person object
            stripe_person = Stripe::Person.construct_from({
                                                            id: "person_123",
                                                            object: "person",
                                                            account: merchant_account.charge_processor_merchant_id
                                                          })
            expect(Stripe::Account).to receive(:list_persons).and_return({ "data" => [stripe_person] })
            expect(Stripe::Account).to receive(:update_person).and_return(true)

            expect(Stripe::Account).to receive(:update).with(
              user.stripe_account.charge_processor_merchant_id,
              hash_including(
                company: hash_including(
                  structure: UserComplianceInfo::BusinessTypes::SOLE_PROPRIETORSHIP
                )
              )
            )
            subject.update_account(user, passphrase: "1234")
          end
        end

        context "when updating from sole proprietorship to a different business type" do
          let(:user_compliance_info_1) { create(:user_compliance_info_business, user:, business_type: UserComplianceInfo::BusinessTypes::SOLE_PROPRIETORSHIP) }
          let(:user_compliance_info_2) { create(:user_compliance_info_business, user:, business_type: UserComplianceInfo::BusinessTypes::CORPORATION) }

          it "sets the structure to nil in company params" do
            original_stripe_account_retrieve = Stripe::Account.method(:retrieve)
            expect(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id) do |*args|
              stripe_account = original_stripe_account_retrieve.call(*args)
              stripe_account["metadata"]["user_compliance_info_id"] = user_compliance_info_1.external_id
              stripe_account
            end

            # Mock list_persons call with a proper Stripe person object
            stripe_person = Stripe::Person.construct_from({
                                                            id: "person_123",
                                                            object: "person",
                                                            account: merchant_account.charge_processor_merchant_id
                                                          })
            expect(Stripe::Account).to receive(:list_persons).and_return({ "data" => [stripe_person] })
            expect(Stripe::Account).to receive(:update_person).and_return(true)

            expect(Stripe::Account).to receive(:update).with(
              user.stripe_account.charge_processor_merchant_id,
              hash_including(
                company: hash_including(
                  directors_provided: true,
                  executives_provided: true
                )
              )
            )
            subject.update_account(user, passphrase: "1234")
          end
        end
      end
    end

    describe "updating part of dob" do
      let(:tos_agreement) { create(:tos_agreement, user:) }
      let(:merchant_account) { subject.create_account(user, passphrase: "1234") }
      let(:user_compliance_info_1) { create(:user_compliance_info, user:, birthday: Date.new(2000, 1, 1)) }
      let(:user_compliance_info_2) { create(:user_compliance_info, user:, birthday: Date.new(2000, 1, 2)) }

      before do
        tos_agreement
        user_compliance_info_1
        create(:ach_account_stripe_succeed, user:)
        merchant_account
        user_compliance_info_2
      end

      let(:expected_account_params) do
        {
          individual: hash_including({
                                       dob: {
                                         year: 2000,
                                         month: 1,
                                         day: 2
                                       }
                                     })
        }
      end

      it "updates an account at Stripe with the full DOB, not just the parts that have changed" do
        expect(Stripe::Account).to receive(:update).with(user.stripe_account.charge_processor_merchant_id, hash_including(expected_account_params)).and_call_original
        subject.update_account(user, passphrase: "1234")
      end
    end

    describe "mismatch of last 4 digits of SSN" do
      let(:merchant_account) { subject.create_account(user, passphrase: "1234") }
      let(:user_compliance_info_1) { create(:user_compliance_info, user:, individual_tax_id: "0000") }
      let(:user_compliance_info_2) { create(:user_compliance_info, user:, individual_tax_id: "111111111") }
      let(:tos_agreement) { create(:tos_agreement, user:) }

      before do
        tos_agreement
        user_compliance_info_1
        create(:ach_account_stripe_succeed, user:)
        merchant_account
        user_compliance_info_2
      end

      let(:without_ssn_last_4) do
        {
          individual: hash_excluding(:ssn_last_4)
        }
      end

      let(:with_full_ssn) do
        {
          individual: hash_including(id_number: "111111111")
        }
      end

      it "does not send the last 4 digits of an old SSN to Stripe" do
        expect(Stripe::Account).to receive(:update).with(user.stripe_account.charge_processor_merchant_id, hash_including(without_ssn_last_4)).and_call_original
        subject.update_account(user, passphrase: "1234")
      end

      it "sends the new full SSN to Stripe" do
        expect(Stripe::Account).to receive(:update).with(user.stripe_account.charge_processor_merchant_id, hash_including(with_full_ssn)).and_call_original
        subject.update_account(user, passphrase: "1234")
      end
    end

    describe "person info changed" do
      let(:user_compliance_info_1) { create(:user_compliance_info_business, user:, individual_tax_id: "0000") }
      let(:tos_agreement) { create(:tos_agreement, user:) }
      let(:user_compliance_info_2) { create(:user_compliance_info_business, user:, individual_tax_id: "000000000") }
      let(:merchant_account) { subject.create_account(user, passphrase: "1234") }

      let(:expected_account_params) do
        {
          metadata: {
            user_id: user.external_id,
            tos_agreement_id: tos_agreement.external_id,
            user_compliance_info_id: user_compliance_info_2.external_id
          },
          tos_acceptance: { date: 1427846400, ip: "54.234.242.13" },
        }
      end

      let(:expected_person_params) do
        {
          id_number: "000000000"
        }
      end

      before do
        user_compliance_info_1
        create(:ach_account_stripe_succeed, user:)
        travel_to(Time.find_zone("UTC").local(2015, 4, 1)) do
          tos_agreement
        end
        merchant_account
        RSpec::Matchers.define_negated_matcher :excluding, :include
      end

      it "updates person with correct diff attributes based on previous compliance info" do
        original_stripe_account_retrieve = Stripe::Account.method(:retrieve)
        expect(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id) do |*args|
          stripe_account = original_stripe_account_retrieve.call(*args)
          stripe_account["metadata"]["user_compliance_info_id"] = user_compliance_info_1.external_id
          stripe_account
        end
        expect(Stripe::Account).to receive(:update).with(user.stripe_account.charge_processor_merchant_id, hash_including(expected_account_params)).and_call_original
        expect(StripeMerchantAccountManager).to receive(:update_person).with(user, kind_of(Stripe::Account), user_compliance_info_1.external_id, "1234", force_address_resync: false, seed_representative_ownership: false, unclaimed_percent_ownership: nil).and_call_original
        expect(Stripe::Account).to receive(:update_person).with(kind_of(String), kind_of(String), a_hash_including(expected_person_params).and(excluding(:first_name))).and_call_original
        subject.update_account(user, passphrase: "1234")
      end
    end

    describe "updating capabilities" do
      before do
        create(:user_compliance_info, user:)
        create(:ach_account_stripe_succeed, user:)
        create(:tos_agreement, user:)
        @merchant_account = subject.create_account(user, passphrase: "1234")
        create(:user_compliance_info, user:)
      end

      context "when account is missing required capabilities" do
        let!(:stripe_account) { Stripe::Account.retrieve(@merchant_account.charge_processor_merchant_id) }

        before do
          Stripe::Account.update(stripe_account.id, capabilities: { card_payments: { requested: false } })
        end

        it "requests the missing capabilities during an update" do
          expect(stripe_account.refresh.capabilities.keys.map(&:to_s)).to eq(%w(transfers))
          expect(Stripe::Account)
            .to receive(:update)
            .with(user.stripe_account.charge_processor_merchant_id, hash_including(capabilities: { card_payments: { requested: true }, transfers: { requested: true } }))
            .and_call_original
          subject.update_account(user, passphrase: "1234")
          expect(stripe_account.refresh.capabilities.keys.map(&:to_s)).to eq(%w(card_payments transfers))
        end
      end

      context "when account has extra capabilities" do
        before do
          Stripe::Account.update_capability(@merchant_account.charge_processor_merchant_id, "tax_reporting_us_1099_k", { requested: true })
        end

        it "updates an account successfully" do
          expect(Stripe::Account)
            .to receive(:update)
            .with(user.stripe_account.charge_processor_merchant_id, hash_including(capabilities: { card_payments: { requested: true }, transfers: { requested: true }, tax_reporting_us_1099_k: { requested: true } }))
            .and_call_original
          subject.update_account(user, passphrase: "1234")
        end
      end

      context "when account has some missing, some outdated, and some extra capabilities" do
        before do
          stripe_account = Stripe::Account.retrieve(@merchant_account.charge_processor_merchant_id)
          Stripe::Account.update(stripe_account.id, requested_capabilities: [])
          Stripe::Account.update_capability(@merchant_account.charge_processor_merchant_id, "legacy_payments", { requested: true })
          Stripe::Account.update_capability(@merchant_account.charge_processor_merchant_id, "tax_reporting_us_1099_k", { requested: true })
        end

        it "updates an account successfully" do
          expect(Stripe::Account)
            .to receive(:update)
            .with(user.stripe_account.charge_processor_merchant_id, hash_including(capabilities: { card_payments: { requested: true }, transfers: { requested: true }, tax_reporting_us_1099_k: { requested: true }, legacy_payments: { requested: true } }))
            .and_call_original
          subject.update_account(user, passphrase: "1234")
        end
      end
    end
  end

  describe "#update_bank_account" do
    let(:user_compliance_info) { create(:user_compliance_info, user:) }
    let(:tos_agreement) { create(:tos_agreement, user:) }
    let(:bank_account_1) { create(:ach_account_stripe_succeed, user:) }
    let(:merchant_account) { subject.create_account(user, passphrase: "1234") }

    before do
      user_compliance_info
      tos_agreement
      bank_account_1
      merchant_account
    end

    describe "all info provided, bank account changed" do
      let(:bank_account_2) { create(:ach_account_stripe_succeed, user:) }

      before do
        bank_account_1.update!(deleted_at: Time.current)
        bank_account_2
      end

      let(:bank_account_1_stripe_id) { bank_account_1.stripe_bank_account_id }
      let(:bank_account_1_stripe_fingerprint) { bank_account_1.stripe_fingerprint }

      it "updates an account at stripe with all the params" do
        expect(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id).twice.and_call_original
        allow(user).to receive(:external_id).and_return("5871412304037")
        allow(user_compliance_info).to receive(:external_id).and_return("ZNAihetfsujAVlG3Ia7KPw==")
        allow(tos_agreement).to receive(:external_id).and_return("c-XP9hGy5rHZLPM1tA5xnw==")
        allow(bank_account_2).to receive(:external_id).and_return("-PURysMRznHezLyPac567A==")
        expect(Stripe::Account).to receive(:update).with(user.stripe_account.charge_processor_merchant_id, hash_including(
          bank_account: {
            country: "US",
            currency: "usd",
            routing_number: "110000000",
            account_number: "000123456789"
          })).and_call_original
        subject.update_bank_account(user, passphrase: "1234")
        stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
        expect(stripe_account["metadata"]["user_id"]).to eq(user.external_id)
        expect(stripe_account["metadata"]["user_compliance_info_id"]).to eq(user_compliance_info.external_id)
        expect(stripe_account["metadata"]["tos_agreement_id"]).to eq(tos_agreement.external_id)
        expect(stripe_account["metadata"]["bank_account_id"]).to eq(bank_account_2.external_id)
      end

      it "saves the stripe bank account id on our bank account record" do
        subject.update_bank_account(user, passphrase: "1234")
        bank_account_1.reload
        bank_account_2.reload
        expect(bank_account_1.stripe_bank_account_id).to eq(bank_account_1_stripe_id)
        expect(bank_account_2.stripe_bank_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account_2.stripe_bank_account_id).not_to eq(bank_account_1.stripe_bank_account_id)
      end

      it "saves the stripe bank account fingerprint on our bank account record" do
        subject.update_bank_account(user, passphrase: "1234")
        bank_account_1.reload
        bank_account_2.reload
        expect(bank_account_1.stripe_fingerprint).to eq(bank_account_1_stripe_fingerprint)
        expect(bank_account_2.stripe_fingerprint).to match(/[a-zA-Z0-9]+/)
      end

      it "soft-deletes stale Stripe bank sync failure payout notes on successful sync" do
        stale_failure_note = user.add_payout_note(content: "Stripe bank sync failed: routing_number_invalid — We couldn't find the bank for that")
        stale_retry_note = user.add_payout_note(content: "Stripe bank sync failed and exhausted Sidekiq retries for bank_account_id=#{bank_account_1.id}. See Sentry for the underlying Stripe error.")
        unrelated_note = user.add_payout_note(content: "Scheduled payouts paused on May 1, 2026")

        expect(subject.update_bank_account(user, passphrase: "1234")).to eq(:synced)

        expect(stale_failure_note.reload).not_to be_alive
        expect(stale_retry_note.reload).not_to be_alive
        expect(unrelated_note.reload).to be_alive
      end

      it "does not soft-delete failure notes when sync fails" do
        stale_failure_note = user.add_payout_note(content: "Stripe bank sync failed: routing_number_invalid — We couldn't find the bank for that")
        expect(Stripe::Account).to receive(:update).and_raise(Stripe::InvalidRequestError.new("Invalid account number", "invalid_account_number"))

        result = subject.update_bank_account(user, passphrase: "1234")

        expect(result).to eq(:invalid_bank_account)
        expect(stale_failure_note.reload).to be_alive
      end

      describe "invalid account number provided" do
        before do
          expect(Stripe::Account).to receive(:update).and_raise(Stripe::InvalidRequestError.new("Invalid account number", "invalid_account_number"))
        end

        it "emails the creator, flagging it as a format rejection the seller has to correct" do
          expect do
            subject.update_bank_account(user, passphrase: "1234")
          end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)
            .with(user.id, StripeMerchantAccountManager::BANK_REJECTION_KIND_FORMAT, "Invalid account number", user.active_bank_account.id)
        end
      end

      describe "account number provided has history of payment failures" do
        before do
          error_message = "You cannot use this bank account because previous attempts to deliver payouts to this account have failed."
          expect(Stripe::Account).to receive(:update).and_raise(Stripe::InvalidRequestError.new(error_message, "invalid_account_number"))
        end

        it "asks for a different account rather than a corrected code" do
          expect do
            subject.update_bank_account(user, passphrase: "1234")
          end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)
            .with(user.id, StripeMerchantAccountManager::BANK_REJECTION_KIND_TERMINAL, "You cannot use this bank account because previous attempts to deliver payouts to this account have failed.", user.active_bank_account.id)
        end
      end

      describe "account flagged as unusable by Stripe" do
        let(:error_message) { "This bank account can't be used. Contact support at https://support.stripe.com/contact if you think this is an error." }

        before do
          expect(Stripe::Account).to receive(:update).and_raise(Stripe::InvalidRequestError.new(error_message, "external_account", code: "bank_account_unusable"))
        end

        it "emails the creator and returns invalid_bank_account" do
          result = nil
          expect do
            result = subject.update_bank_account(user, passphrase: "1234")
          end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)
            .with(user.id, StripeMerchantAccountManager::BANK_REJECTION_KIND_TERMINAL, error_message, user.active_bank_account.id)
          expect(result).to eq(:invalid_bank_account)
        end
      end

      describe "account rejected because previous payouts failed" do
        let(:error_message) { "This bank account can't be used because previous payments or payouts failed. Contact support at https://support.stripe.com/contact if you think this is an error." }

        before do
          expect(Stripe::Account).to receive(:update).and_raise(Stripe::InvalidRequestError.new(error_message, "external_account"))
        end

        it "emails the creator and returns invalid_bank_account" do
          result = nil
          expect do
            result = subject.update_bank_account(user, passphrase: "1234")
          end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)
            .with(user.id, StripeMerchantAccountManager::BANK_REJECTION_KIND_TERMINAL, error_message, user.active_bank_account.id)
          expect(result).to eq(:invalid_bank_account)
        end
      end

      describe "account refused because it is on Stripe's block list" do
        # Stripe returns this with neither code nor param, so the classification hangs entirely on
        # the message match. Asserted at this level and not only through the retry job: the job
        # specs stay green if the wrong rejection_kind reaches the mailer, which is the difference
        # between telling the seller to use a different account and telling them to retype details
        # that can never work (gumroad-private#1476).
        let(:error_message) { "The bank account provided cannot be used because it is on your block list." }

        before do
          expect(Stripe::Account).to receive(:update).and_raise(Stripe::InvalidRequestError.new(error_message, nil))
        end

        it "emails the creator with the blocked rejection kind and returns invalid_bank_account" do
          result = nil
          expect do
            result = subject.update_bank_account(user, passphrase: "1234")
          end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account).with(user.id, described_class::BANK_REJECTION_KIND_BLOCKED, error_message, user.active_bank_account.id)
          expect(result).to eq(:invalid_bank_account)
        end

        it "records a bank-sync payout note naming the block list" do
          subject.update_bank_account(user, passphrase: "1234")

          note = user.comments.with_type_payout_note.last
          expect(note.content).to include("Stripe bank sync failed")
          expect(note.content).to include("block list")
        end
      end

      describe "account holder name rejected by Stripe" do
        before do
          expect(Stripe::Account).to receive(:update).and_raise(Stripe::InvalidRequestError.new("Account holder name is invalid", "account_holder_name", code: "incorrect_account_holder_name"))
        end

        it "emails the creator about the rejected name" do
          expect do
            subject.update_bank_account(user, passphrase: "1234")
          end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_account_holder_name).with(user.id)
        end
      end

      describe "Stripe rejects the external account with a CardError" do
        before do
          expect(Stripe::Account).to receive(:update).and_raise(Stripe::CardError.new("Your card does not support this type of purchase.", "external_account", code: "card_decline_rate_limit_exceeded"))
        end

        it "emails the creator, records a payout note, and returns :card_not_supported" do
          result = nil
          expect do
            result = subject.update_bank_account(user, passphrase: "1234")
          end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account).with(user.id)
          expect(result).to eq(:card_not_supported)
          expect(user.comments.with_type_payout_note.last.content).to include("Stripe bank sync failed")
        end
      end
    end

    describe "all info provided previously, bank account not changed" do
      it "does not update an account at stripe with all the params" do
        expect(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id) do
          stripe_account = {
            "metadata" => {
              "bank_account_id" => bank_account_1.external_id
            }
          }
          expect(Stripe::Account).not_to receive(:update)
          stripe_account
        end
        subject.update_bank_account(user, passphrase: "1234")
      end

      it "syncs to Stripe when the account holder name has changed for JP accounts" do
        user_compliance_info.update_columns(country: "Japan")
        bank_account_1.update!(account_holder_full_name: "Updated Name")

        stripe_account = {
          "metadata" => { "bank_account_id" => bank_account_1.external_id },
          "external_accounts" => [{ "account_holder_name" => "Previous Name" }]
        }
        stripe_account.define_singleton_method(:id) { "acct_123" }

        expect(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id).and_return(stripe_account)
        expect(Stripe::Account).to receive(:update).with("acct_123", hash_including(bank_account: hash_including(account_holder_name: "Updated Name"))).and_raise(StandardError, "stop here")

        expect { subject.update_bank_account(user, passphrase: "1234") }.to raise_error(StandardError, "stop here")
      end
    end

    describe "bank accounts without routing numbers" do
      let!(:user_compliance_info) { create(:user_compliance_info, user:, zip_code: "60-900", city: "Warsaw", state: nil, country: "Poland") }
      let!(:pol_bank_account) { create(:poland_bank_account, user:) }
      let!(:tos_agreement) { create(:tos_agreement, user:) }

      it "does not throw error and updates correctly" do
        bank_account_1.mark_deleted!
        expect(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id).and_call_original
        expect(Stripe::Account).to receive(:update).with(user.stripe_account.charge_processor_merchant_id, hash_including(
          bank_account: {
            country: "PL",
            currency: "pln",
            account_number: "PL61109010140000071219812874"
          }
        )).and_call_original

        expect(ErrorNotifier).not_to receive(:notify)
        expect { subject.update_bank_account(user, passphrase: "1234") }.not_to raise_error
      end
    end

    describe "user no longer has an ACH account" do
      before do
        bank_account_1.update!(deleted_at: Time.current)
      end

      it "raises a user not ready error" do
        expect { subject.update_bank_account(user, passphrase: "1234") }.to raise_error(MerchantRegistrationUserNotReadyError)
      end
    end
  end

  describe "cross-border SEPA IBAN payouts" do
    let(:user) { create(:named_user) }
    let(:tos_agreement) { travel_to(Time.find_zone("UTC").local(2015, 4, 1)) { create(:tos_agreement, user:) } }

    before { tos_agreement }

    context "when a Bulgaria-based creator submits a Lithuanian IBAN (the issue case)" do
      let(:user_compliance_info) do
        create(:user_compliance_info, user:, city: "Sofia", street_address: "address_full_match",
                                      state: nil, zip_code: "1000", country: "Bulgaria")
      end
      let(:bank_account) { create(:bulgaria_bank_account, user:, account_number: "LT121000011101001000") }

      before do
        user_compliance_info
        bank_account
      end

      it "creates a Stripe account in BG and registers the LT IBAN as an EUR external account" do
        expect(Stripe::Account).to receive(:create).with(
          hash_including(
            country: "BG",
            default_currency: "eur",
            bank_account: hash_including(country: "LT", currency: "eur", account_number: "LT121000011101001000")
          )
        ).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.country).to eq("BG")
        expect(merchant_account.currency).to eq("eur")
        expect(merchant_account.charge_processor_merchant_id).to match(/acct_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(bank_account.reload.stripe_external_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_fingerprint).to be_present
      end
    end

    context "when a Bulgaria-based creator with an existing BG IBAN switches to a Lithuanian IBAN" do
      let(:user_compliance_info) do
        create(:user_compliance_info, user:, city: "Sofia", street_address: "address_full_match",
                                      state: nil, zip_code: "1000", country: "Bulgaria")
      end
      let(:original_bank_account) { create(:bulgaria_bank_account, user:, account_number: "BG80BNBG96611020345678") }
      let(:cross_border_bank_account) { create(:bulgaria_bank_account, user:, account_number: "LT121000011101001000") }
      let(:merchant_account) { subject.create_account(user, passphrase: "1234") }

      before do
        user_compliance_info
        original_bank_account
        merchant_account
        original_bank_account.update!(deleted_at: Time.current)
        cross_border_bank_account
      end

      it "syncs the LT IBAN with EUR currency to the existing BG Stripe account" do
        expect(Stripe::Account).to receive(:update).with(
          merchant_account.charge_processor_merchant_id,
          hash_including(bank_account: hash_including(country: "LT", currency: "eur", account_number: "LT121000011101001000"))
        ).and_call_original

        result = subject.update_bank_account(user, passphrase: "1234")

        expect(result).to eq(:synced)
        expect(cross_border_bank_account.reload.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
        expect(cross_border_bank_account.reload.stripe_external_account_id).to match(/ba_[a-zA-Z0-9]+/)
        expect(cross_border_bank_account.reload.stripe_fingerprint).to be_present
      end
    end

    context "when a Denmark-based creator submits a Lithuanian IBAN (Stripe's stated cross-border SEPA example)" do
      let(:user_compliance_info) do
        create(:user_compliance_info, user:, city: "Copenhagen", street_address: "address_full_match",
                                      state: nil, zip_code: "1050", country: "Denmark")
      end
      let(:bank_account) { create(:denmark_bank_account, user:, account_number: "LT121000011101001000") }

      before do
        user_compliance_info
        bank_account
      end

      it "creates a Stripe account in DK with DKK default currency but registers the LT IBAN as an EUR external account" do
        expect(Stripe::Account).to receive(:create).with(
          hash_including(
            country: "DK",
            default_currency: "dkk",
            bank_account: hash_including(country: "LT", currency: "eur", account_number: "LT121000011101001000")
          )
        ).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.country).to eq("DK")
        expect(merchant_account.currency).to eq("dkk")
        expect(merchant_account.charge_processor_merchant_id).to match(/acct_[a-zA-Z0-9]+/)
        expect(bank_account.reload.stripe_external_account_id).to match(/ba_[a-zA-Z0-9]+/)
      end
    end

    context "when a Bulgaria-based creator submits a Bulgarian IBAN (regression: same-country still works)" do
      let(:user_compliance_info) do
        create(:user_compliance_info, user:, city: "Sofia", street_address: "address_full_match",
                                      state: nil, zip_code: "1000", country: "Bulgaria")
      end
      let(:bank_account) { create(:bulgaria_bank_account, user:, account_number: "BG80BNBG96611020345678") }

      before do
        user_compliance_info
        bank_account
      end

      it "creates a Stripe account in BG and registers the BG IBAN as an EUR external account" do
        expect(Stripe::Account).to receive(:create).with(
          hash_including(
            country: "BG",
            default_currency: "eur",
            bank_account: hash_including(country: "BG", currency: "eur", account_number: "BG80BNBG96611020345678")
          )
        ).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.country).to eq("BG")
        expect(merchant_account.currency).to eq("eur")
        expect(bank_account.reload.stripe_external_account_id).to match(/ba_[a-zA-Z0-9]+/)
      end
    end

    context "when a Denmark-based creator submits a Danish IBAN (regression: same-country still works)" do
      let(:user_compliance_info) do
        create(:user_compliance_info, user:, city: "Copenhagen", street_address: "address_full_match",
                                      state: nil, zip_code: "1050", country: "Denmark")
      end
      let(:bank_account) { create(:denmark_bank_account, user:, account_number: "DK5000400440116243") }

      before do
        user_compliance_info
        bank_account
      end

      it "creates a Stripe account in DK and registers the DK IBAN as a DKK external account" do
        expect(Stripe::Account).to receive(:create).with(
          hash_including(
            country: "DK",
            default_currency: "dkk",
            bank_account: hash_including(country: "DK", currency: "dkk", account_number: "DK5000400440116243")
          )
        ).and_call_original

        merchant_account = subject.create_account(user, passphrase: "1234")

        expect(merchant_account.country).to eq("DK")
        expect(merchant_account.currency).to eq("dkk")
        expect(bank_account.reload.stripe_external_account_id).to match(/ba_[a-zA-Z0-9]+/)
      end
    end

    context "when a Bulgaria-based creator submits a Saudi IBAN (non-SEPA)" do
      it "is rejected at the model layer before any Stripe call" do
        allow(Rails.env).to receive(:production?).and_return(true)
        bank_account = build(:bulgaria_bank_account, user:, account_number: "SA0380000000608010167519")

        expect(Stripe::Account).not_to receive(:create)
        expect(bank_account).not_to be_valid
        expect(bank_account.errors.full_messages.to_sentence).to eq("The account number is invalid.")
      end
    end
  end

  describe ".save_stripe_bank_account_info" do
    let(:user) { create(:named_user) }
    let(:bank_account) { create(:japan_bank_account, user:) }
    let(:stripe_external_account) { double(id: "ba_123", fingerprint: "fingerprint_123") }
    let(:stripe_account) { double(id: "acct_123", external_accounts: [stripe_external_account]) }

    before do
      bank_account.update_columns(account_holder_full_name: "Haruna マサシ")
    end

    it "persists Stripe metadata without revalidating a legacy invalid holder name" do
      expect(bank_account).not_to be_valid

      expect do
        described_class.send(:save_stripe_bank_account_info, bank_account, stripe_account)
      end.to change { CheckPaymentAddressWorker.jobs.size }.by(1)

      expect(bank_account.reload.stripe_connect_account_id).to eq("acct_123")
      expect(bank_account.stripe_external_account_id).to eq("ba_123")
      expect(bank_account.stripe_fingerprint).to eq("fingerprint_123")
    end
  end

  describe ".handle_stripe_info_requirements" do
    let(:active_bank_account) { instance_double(CardBankAccount, id: 123, stripe_connect_account_id: nil) }
    let(:requested_scope) { double(find_each: nil, where: double(present?: false), last: nil) }
    let(:user_compliance_info_requests) { double(requested: requested_scope) }
    let(:user) do
      instance_double(
        User,
        account_active?: true,
        user_compliance_info_requests:
      )
    end
    let(:merchant_account) do
      instance_double(
        MerchantAccount,
        alive?: true,
        charge_processor_alive?: true,
        user:,
        stripe_disabled_reason: nil,
        stripe_rejected?: false
      )
    end
    let(:merchant_account_relation) { double(last: merchant_account) }
    let(:stripe_account) do
      {
        "id" => "acct_123",
        "business_type" => "individual",
        "individual" => {},
        "requirements" => {
          "currently_due" => [],
          "eventually_due" => [],
          "past_due" => []
        },
        "charges_enabled" => true
      }
    end

    before do
      allow(MerchantAccount).to receive(:where).and_return(merchant_account_relation)
      allow(described_class).to receive(:update_bank_account).with(user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")).and_return(:stripe_unknown_error)
      allow(active_bank_account).to receive(:is_a?) { |klass| klass == CardBankAccount }
      allow(user).to receive(:active_bank_account).and_return(active_bank_account, active_bank_account, active_bank_account, nil, nil)
      allow(user).to receive(:with_lock).and_yield
      allow(merchant_account).to receive(:reload).and_return(merchant_account)
    end

    it "captures the active bank once before enqueueing the retry worker" do
      expect do
        described_class.send(:handle_stripe_info_requirements, "evt_123", stripe_account, {})
      end.to change { HandleNewBankAccountWorker.jobs.size }.by(1)

      expect(HandleNewBankAccountWorker.jobs.last["args"]).to eq([active_bank_account.id])
    end

    it "captures the active bank once before reading card sync state" do
      allow(described_class).to receive(:update_bank_account).with(user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")).and_return(:synced)
      allow(user).to receive(:active_bank_account).and_return(active_bank_account, nil, nil)

      expect do
        described_class.send(:handle_stripe_info_requirements, "evt_123", stripe_account, {})
      end.not_to raise_error
    end
  end

  describe ".handle_stripe_event" do
    before do
      create(:user_compliance_info, user:)
    end

    describe "event: account.updated" do
      describe "for an account not in our system" do
        let(:stripe_event) do
          {
            "api_version" => API_VERSION,
            "type" => "account.updated",
            "id" => "stripe-event-id",
            "data" => {
              "object" => {
                "object" => "account",
                "id" => "stripe-account-id",
                "type" => "custom"
              }
            }
          }
        end

        it "raise an error" do
          expect { described_class.handle_stripe_event(stripe_event) }.to raise_error("No Merchant Account for Stripe Account ID stripe-account-id")
        end
      end


      describe "for a standard stripe connect account" do
        let(:stripe_event) do
          {
            "id": "evt_1MjHmpBrVHEtWpGZqqcrEt1W",
            "object": "event",
            "account": "acct_1MjHlTBrVHEtWpGZ",
            "api_version": API_VERSION,
            "created": 1678261907,
            "data": {
              "object": {
                "id": "acct_1MjHlTBrVHEtWpGZ",
                "object": "account",
                "business_profile": {
                  "mcc": "5192",
                  "name": "Josimar Carlos Diogo Mateus",
                  "support_address": {
                    "city": "Porto",
                    "country": "PT",
                    "line1": "Rua de Chãs, n.º 95, Bloco A2 ,9.º Frente",
                    "line2": nil,
                    "postal_code": "4400-414",
                    "state": nil
                  },
                  "support_email": nil,
                  "support_phone": "+14706429141",
                  "support_url": nil,
                  "url": "https://uiuex.com/"
                },
                "capabilities": {
                  "bancontact_payments": "active",
                  "blik_payments": "active",
                  "card_payments": "active",
                  "cartes_bancaires_payments": "pending",
                  "eps_payments": "active",
                  "giropay_payments": "active",
                  "ideal_payments": "active",
                  "link_payments": "active",
                  "p24_payments": "active",
                  "sepa_debit_payments": "active",
                  "sofort_payments": "active",
                  "transfers": "active"
                },
                "charges_enabled": true,
                "controller": {
                  "type": "application",
                  "is_controller": true
                },
                "country": "PT",
                "default_currency": "usd",
                "details_submitted": true,
                "email": "jc@uiuex.com",
                "payouts_enabled": true,
                "settings": {
                  "bacs_debit_payments": {},
                  "branding": {
                    "icon": nil,
                    "logo": nil,
                    "primary_color": nil,
                    "secondary_color": nil
                  },
                  "card_issuing": {
                    "tos_acceptance": {
                      "date": nil,
                      "ip": nil
                    }
                  },
                  "card_payments": {
                    "statement_descriptor_prefix": "JOSIMAR UI",
                    "statement_descriptor_prefix_kanji": nil,
                    "statement_descriptor_prefix_kana": nil,
                    "decline_on": {
                      "avs_failure": false,
                      "cvc_failure": false
                    }
                  },
                  "dashboard": {
                    "display_name": "Uiuex",
                    "timezone": "Etc/UTC"
                  },
                  "payments": {
                    "statement_descriptor": "JOSIMAR CARLOS UI/UX",
                    "statement_descriptor_kana": nil,
                    "statement_descriptor_kanji": nil
                  },
                  "sepa_debit_payments": {},
                  "payouts": {
                    "debit_negative_balances": true,
                    "schedule": {
                      "delay_days": 7,
                      "interval": "daily"
                    },
                    "statement_descriptor": nil
                  }
                },
                "type": "standard",
                "created": 1678261837,
                "external_accounts": {
                  "object": "list",
                  "data": [
                    {
                      "id": "ba_1MjHlVBrVHEtWpGZh8zLG3PE",
                      "object": "bank_account",
                      "account": "acct_1MjHlTBrVHEtWpGZ",
                      "account_holder_name": "Josimar Mateus",
                      "account_holder_type": nil,
                      "account_type": nil,
                      "available_payout_methods": [
                        "standard"
                      ],
                      "bank_name": "COMMUNITY FEDERAL SAVINGS BANK",
                      "country": "US",
                      "currency": "usd",
                      "default_for_currency": true,
                      "fingerprint": "TxGzkvJ2kzD8SsTr",
                      "last4": "9908",
                      "metadata": {},
                      "routing_number": "026073008",
                      "status": "new"
                    }
                  ],
                  "has_more": false,
                  "total_count": 1,
                  "url": "/v1/accounts/acct_1MjHlTBrVHEtWpGZ/external_accounts"
                },
                "future_requirements": {
                  "alternatives": [],
                  "current_deadline": nil,
                  "currently_due": [],
                  "disabled_reason": nil,
                  "errors": [],
                  "eventually_due": [],
                  "past_due": [],
                  "pending_verification": []
                },
                "metadata": {},
                "requirements": {
                  "alternatives": [],
                  "current_deadline": nil,
                  "currently_due": [],
                  "disabled_reason": nil,
                  "errors": [],
                  "eventually_due": [],
                  "past_due": [],
                  "pending_verification": []
                },
                "tos_acceptance": {
                  "date": 1678261828
                }
              },
              "previous_attributes": {
                "capabilities": {
                  "p24_payments": "pending"
                }
              }
            },
            "livemode": true,
            "pending_webhooks": 1,
            "request": {
              "id": nil,
              "idempotency_key": nil
            },
            "type": "account.updated"
          }.as_json
        end

        it "does not raise an error if merchant account is not present" do
          expect { described_class.handle_stripe_event(stripe_event) }.not_to raise_error
        end

        it "does nothing and returns" do
          create(:merchant_account_stripe_connect, charge_processor_merchant_id: "acct_1MjHlTBrVHEtWpGZ")

          expect(StripeMerchantAccountManager).to receive(:handle_stripe_event_account_updated).and_call_original
          expect_any_instance_of(MerchantAccount).not_to receive(:user)
          expect(Stripe::Account).not_to receive(:list_persons)
          expect { described_class.handle_stripe_event(stripe_event) }.not_to raise_error
        end
      end

      describe ".clear_settlement_currency_mismatch_on_currency_change" do
        let(:merchant_account) { create(:merchant_account, charge_processor_merchant_id: "acct_settlement_mismatch_test") }

        before { merchant_account.record_settlement_currency_mismatch!("cad") }

        it "clears a recorded settlement-currency mismatch when the account's default currency changed" do
          described_class.clear_settlement_currency_mismatch_on_currency_change(merchant_account, { "default_currency" => "cad" })

          expect(merchant_account.reload.settlement_currency_mismatch_active?("cad")).to be(false)
        end

        it "clears a recorded settlement-currency mismatch when the account's external accounts changed" do
          # Adding or removing a bank account changes which currencies the account can
          # settle in, so the learned marker must be re-probed.
          described_class.clear_settlement_currency_mismatch_on_currency_change(merchant_account, { "external_accounts" => { "data" => [] } })

          expect(merchant_account.reload.settlement_currency_mismatch_active?("cad")).to be(false)
        end

        it "clears the marker when previous_attributes arrives as a Stripe::StripeObject, the shape the webhook handler actually passes" do
          # In production the account.updated handler hands this method the event's
          # previous_attributes as a Stripe::StripeObject (symbol-keyed via to_hash), not a
          # plain Hash — the original `.key?` call raised NoMethodError on every event and
          # markers were never cleared (gumroad-private#933, 2026-07-20).
          previous_attributes = Stripe::StripeObject.construct_from({ default_currency: "usd" })

          expect do
            described_class.clear_settlement_currency_mismatch_on_currency_change(merchant_account, previous_attributes)
          end.not_to raise_error

          expect(merchant_account.reload.settlement_currency_mismatch_active?("cad")).to be(false)
        end

        it "keeps the marker when a Stripe::StripeObject update touched unrelated attributes" do
          previous_attributes = Stripe::StripeObject.construct_from({ capabilities: { p24_payments: "pending" } })

          described_class.clear_settlement_currency_mismatch_on_currency_change(merchant_account, previous_attributes)

          expect(merchant_account.reload.settlement_currency_mismatch_active?("cad")).to be(true)
        end

        it "keeps the marker when the update touched unrelated attributes" do
          described_class.clear_settlement_currency_mismatch_on_currency_change(merchant_account, { "capabilities" => { "p24_payments" => "pending" } })

          expect(merchant_account.reload.settlement_currency_mismatch_active?("cad")).to be(true)
        end

        it "does nothing when no merchant account matched the event" do
          expect do
            described_class.clear_settlement_currency_mismatch_on_currency_change(nil, { "default_currency" => "cad" })
          end.not_to raise_error
        end

        it "does not let a persistence failure escape into the rest of the webhook handling" do
          allow(merchant_account).to receive(:clear_settlement_currency_mismatch!).and_raise("db hiccup")

          expect do
            described_class.clear_settlement_currency_mismatch_on_currency_change(merchant_account, { "default_currency" => "cad" })
          end.not_to raise_error
        end
      end

      describe "for a merchant account that was not fully set up in Stripe" do
        let(:merchant_account) { create(:merchant_account, charge_processor_alive_at: nil) }
        let(:stripe_event) do
          {
            "api_version" => API_VERSION,
            "type" => "account.updated",
            "id" => "stripe-event-id",
            "account" => merchant_account.charge_processor_merchant_id,
            "user_id" => merchant_account.charge_processor_merchant_id,
            "data" => {
              "object" => {
                "object" => "account",
                "id" => merchant_account.charge_processor_merchant_id,
                "requirements" => {
                  "currently_due" => [
                    "individual.dob.day",
                    "individual.dob.month",
                    "individual.dob.year"
                  ],
                  "eventually_due" => [
                    "company.tax_id"
                  ],
                  "past_due" => [
                    "individual.ssn_last_4",
                    "individual.id_number"
                  ]
                }
              }
            }
          }
        end

        it "ignores the event" do
          expect do
            described_class.handle_stripe_event(stripe_event)
          end.not_to change(UserComplianceInfoRequest, :count)
        end
      end

      describe "for a USA creator" do
        before do
          create(:user_compliance_info, user:, country: Compliance::Countries::USA.common_name)
        end

        describe "SSN requested" do
          describe "only the last 4 SSN is requested" do
            let(:merchant_account) { create(:merchant_account, user:) }

            let(:stripe_event) do
              {
                "api_version" => API_VERSION,
                "type" => "account.updated",
                "id" => "stripe-event-id",
                "account" => merchant_account.charge_processor_merchant_id,
                "user_id" => merchant_account.charge_processor_merchant_id,
                "data" => {
                  "object" => {
                    "object" => "account",
                    "id" => merchant_account.charge_processor_merchant_id,
                    "business_type" => "individual",
                    "charges_enabled" => true,
                    "payouts_enabled" => true,
                    "requirements" => {
                      "current_deadline" => 1_406_748_559, # "2014-07-30T19:29:19+00:00"
                      "currently_due" => [],
                      "eventually_due" => [],
                      "past_due" => [
                        "individual.ssn_last_4"
                      ]
                    }
                  }
                }
              }
            end

            it "it should create a user compliance info request record" do
              described_class.handle_stripe_event(stripe_event)
              user_compliance_info_requests = UserComplianceInfoRequest.all
              expect(user_compliance_info_requests[0].user).to eq(user)
              expect(user_compliance_info_requests[0].field_needed).to eq(UserComplianceInfoFields::Individual::TAX_ID)
              expect(user_compliance_info_requests[0].only_needs_field_to_be_partially_provided).to eq(true)
              expect(user_compliance_info_requests[0].due_at).to eq(Time.zone.at(1_406_748_559))
              expect(user_compliance_info_requests[0].stripe_event_id).to eq("stripe-event-id")
            end

            it "emails the creator" do
              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w[individual_tax_id])
            end

            it "does not email the creator if their account is deleted" do
              user.mark_deleted!

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w[individual_tax_id])
            end

            it "does not email the creator if their account is suspended" do
              admin = create(:admin_user)
              user.flag_for_fraud!(author_id: admin.id)
              user.suspend_for_fraud!(author_id: admin.id)

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w[individual_tax_id])
            end

            it "records the email being sent on the requests for user compliance info" do
              frozen_time = Time.current.change(usec: 0)

              expect_any_instance_of(UserComplianceInfoRequest).to receive(:record_email_sent!).with(frozen_time).once.and_call_original

              travel_to(frozen_time) do
                described_class.handle_stripe_event(stripe_event)
              end
            end

            it "results in the requests having a last contact at time of when the contact was made" do
              frozen_time = Time.current.change(usec: 0)

              expect_any_instance_of(UserComplianceInfoRequest).to receive(:record_email_sent!).with(frozen_time).once.and_call_original

              travel_to(frozen_time) do
                described_class.handle_stripe_event(stripe_event)
              end

              user_compliance_info_requests = UserComplianceInfoRequest.all
              expect(user_compliance_info_requests[0].last_email_sent_at).to eq(frozen_time)
            end
          end

          describe "only the full SSN is requested" do
            let(:merchant_account) { create(:merchant_account, user:) }

            let(:stripe_event) do
              {
                "api_version" => API_VERSION,
                "type" => "account.updated",
                "id" => "stripe-event-id",
                "account" => merchant_account.charge_processor_merchant_id,
                "user_id" => merchant_account.charge_processor_merchant_id,
                "data" => {
                  "object" => {
                    "object" => "account",
                    "id" => merchant_account.charge_processor_merchant_id,
                    "business_type" => "individual",
                    "charges_enabled" => true,
                    "payouts_enabled" => true,
                    "requirements" => {
                      "current_deadline" => 1_406_748_559, # "2014-07-30T19:29:19+00:00"
                      "currently_due" => [],
                      "eventually_due" => [],
                      "past_due" => [
                        "individual.id_number"
                      ]
                    }
                  }
                }
              }
            end

            it "it should create a user compliance info request record" do
              described_class.handle_stripe_event(stripe_event)
              user_compliance_info_requests = UserComplianceInfoRequest.all
              expect(user_compliance_info_requests[0].user).to eq(user)
              expect(user_compliance_info_requests[0].field_needed).to eq(UserComplianceInfoFields::Individual::TAX_ID)
              expect(user_compliance_info_requests[0].only_needs_field_to_be_partially_provided).to eq(false)
              expect(user_compliance_info_requests[0].due_at).to eq(Time.zone.at(1_406_748_559))
              expect(user_compliance_info_requests[0].stripe_event_id).to eq("stripe-event-id")
            end

            it "emails the creator" do
              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w[individual_tax_id])
            end

            it "records the email being sent on the requests for user compliance info" do
              frozen_time = Time.current.change(usec: 0)

              travel_to(frozen_time) do
                described_class.handle_stripe_event(stripe_event)
              end

              user_compliance_info_requests = UserComplianceInfoRequest.all
              expect(user_compliance_info_requests[0].emails_sent_at).to eq([frozen_time])
            end

            it "results in the requests having a last contact at time of when the contact was made" do
              frozen_time = Time.current.change(usec: 0)

              expect_any_instance_of(UserComplianceInfoRequest).to receive(:record_email_sent!).with(frozen_time).once.and_call_original

              travel_to(frozen_time) do
                described_class.handle_stripe_event(stripe_event)
              end

              user_compliance_info_requests = UserComplianceInfoRequest.all
              expect(user_compliance_info_requests[0].last_email_sent_at).to eq(frozen_time)
            end
          end
        end

        describe "charges_enabled status" do
          describe "in the request charges are newly disabled" do
            let(:merchant_account) { create(:merchant_account, user:) }

            let(:stripe_event) do
              {
                "api_version" => API_VERSION,
                "type" => "account.updated",
                "id" => "stripe-event-id",
                "account" => merchant_account.charge_processor_merchant_id,
                "user_id" => merchant_account.charge_processor_merchant_id,
                "data" => {
                  "object" => {
                    "object" => "account",
                    "id" => merchant_account.charge_processor_merchant_id,
                    "business_type" => "individual",
                    "charges_enabled" => false,
                    "payouts_enabled" => true,
                    "requirements" => {
                      "current_deadline" => 1_406_748_559, # "2014-07-30T19:29:19+00:00"
                      "currently_due" => [],
                      "eventually_due" => [],
                      "past_due" => [
                        "individual.ssn_last_4"
                      ]
                    }
                  },
                  "previous_attributes" => {
                    "charges_enabled" => true
                  }
                }
              }
            end

            it "emails the creator if charges are disabled due to pending info requirement" do
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "requirements.past_due"
              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to have_enqueued_mail(MerchantRegistrationMailer, :stripe_charges_disabled).with(user.id)

              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "action_required.requested_capabilities"
              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to have_enqueued_mail(MerchantRegistrationMailer, :stripe_charges_disabled).with(user.id)
            end

            it "does not email the creator if charges are disabled due to a reason other than pending info requirement" do
              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to have_enqueued_mail(MerchantRegistrationMailer, :stripe_charges_disabled)

              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "platform_paused"

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to have_enqueued_mail(MerchantRegistrationMailer, :stripe_charges_disabled)
            end

            it "does not email the creator if there is no pending info requirement" do
              stripe_event["data"]["object"]["requirements"]["past_due"] = []
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "action_required.requested_capabilities"

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to have_enqueued_mail(MerchantRegistrationMailer, :stripe_charges_disabled)
            end

            it "does not email the creator if charges_enabled was previously not set" do
              stripe_event["data"]["previous_attributes"]["charges_enabled"] = false
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "requirements.past_due"

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to have_enqueued_mail(MerchantRegistrationMailer, :stripe_charges_disabled)
            end

            it "does not email the creator if they are suspended" do
              user.flag_for_fraud!(author_name: "ContentModeration")
              user.suspend_for_fraud!(author_name: "ContentModeration")

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to have_enqueued_mail(MerchantRegistrationMailer, :stripe_charges_disabled)
            end

            it "does not email the creator if the merchant account is deleted" do
              merchant_account.mark_deleted!

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to have_enqueued_mail(MerchantRegistrationMailer, :stripe_charges_disabled)
            end
          end

          describe "in the request charges were disabled" do
            let(:merchant_account) { create(:merchant_account, user:) }

            let(:stripe_event) do
              {
                "api_version" => API_VERSION,
                "type" => "account.updated",
                "id" => "stripe-event-id",
                "account" => merchant_account.charge_processor_merchant_id,
                "user_id" => merchant_account.charge_processor_merchant_id,
                "data" => {
                  "object" => {
                    "object" => "account",
                    "id" => merchant_account.charge_processor_merchant_id,
                    "business_type" => "individual",
                    "charges_enabled" => false,
                    "payouts_enabled" => true,
                    "requirements" => {
                      "current_deadline" => 1_406_748_559, # "2014-07-30T19:29:19+00:00"
                      "currently_due" => [],
                      "eventually_due" => [],
                      "past_due" => [
                        "individual.ssn_last_4"
                      ],
                      "disabled_reason" => "requirements.past_due"
                    }
                  },
                  "previous_attributes" => {
                    "charges_enabled" => false
                  }
                }
              }
            end

            it "does not email the creator" do
              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to have_enqueued_mail(MerchantRegistrationMailer, :stripe_charges_disabled)
            end

            it "persists the Stripe disabled_reason on the merchant account" do
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "rejected.listed"

              described_class.handle_stripe_event(stripe_event)

              expect(merchant_account.reload.stripe_disabled_reason).to eq("rejected.listed")
            end

            it "clears the disabled_reason when Stripe stops reporting one" do
              merchant_account.update!(stripe_disabled_reason: "rejected.listed")
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = nil

              described_class.handle_stripe_event(stripe_event)

              expect(merchant_account.reload.stripe_disabled_reason).to be_nil
            end

            describe "when Stripe permanently rejects the account" do
              before do
                stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "rejected.listed"
                # Terminal rejection: Stripe is asking for nothing more.
                stripe_event["data"]["object"]["requirements"]["past_due"] = []
              end

              it "closes open verification requests so remediation reminders stop" do
                request = create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::TAX_ID)

                described_class.handle_stripe_event(stripe_event)

                expect(request.reload.state).to eq("provided")
              end

              it "sends the one-time rejection email and records the marker" do
                expect do
                  described_class.handle_stripe_event(stripe_event)
                end.to have_enqueued_mail(MerchantRegistrationMailer, :stripe_account_rejected).with(user.id)

                expect(merchant_account.reload.stripe_rejection_email_sent).to eq(true)
              end

              it "does not send the rejection email again on subsequent webhooks" do
                merchant_account.update!(stripe_rejection_email_sent: true)

                expect do
                  described_class.handle_stripe_event(stripe_event)
                end.not_to have_enqueued_mail(MerchantRegistrationMailer, :stripe_account_rejected)
              end

              it "syncs the payouts pause before enqueueing the rejection email when the same webhook disables payouts" do
                # The rejection email's copy depends on whether Stripe froze
                # payouts, so the pause written by this same webhook must be
                # committed by the time the email is enqueued.
                stripe_event["data"]["object"]["payouts_enabled"] = false

                payouts_paused_when_email_enqueued = nil
                allow(MerchantRegistrationMailer).to receive(:stripe_account_rejected).with(user.id) do
                  payouts_paused_when_email_enqueued = user.reload.payouts_paused_internally?
                  double(deliver_later: true)
                end

                described_class.handle_stripe_event(stripe_event)

                expect(payouts_paused_when_email_enqueued).to eq(true)
              end
            end

            describe "when Stripe permanently rejects the account but leaves a non-actionable interv_* entry open (the gumroad-private#965 signature)" do
              before do
                stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "rejected.listed"
                stripe_event["data"]["object"]["requirements"]["past_due"] = []
                # Stripe leaves this permanent supportability intervention in
                # currently_due on rejected accounts and never clears it. There
                # is no form the seller can fill in for it, so the rejection is
                # terminal despite currently_due being non-empty.
                stripe_event["data"]["object"]["requirements"]["currently_due"] =
                  ["interv_1RWtzeAQqMpdRp2IhPb6x4q7.other_supportability_inquiry.support"]
              end

              it "treats the rejection as terminal: closes open verification requests" do
                request = create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::TAX_ID)

                described_class.handle_stripe_event(stripe_event)

                expect(request.reload.state).to eq("provided")
              end

              it "sends the one-time rejection email" do
                expect do
                  described_class.handle_stripe_event(stripe_event)
                end.to have_enqueued_mail(MerchantRegistrationMailer, :stripe_account_rejected).with(user.id)
              end

              it "does not open a verification request or send a remediation email for the interv_* entry" do
                expect do
                  expect do
                    described_class.handle_stripe_event(stripe_event)
                  end.not_to have_enqueued_mail(ContactingCreatorMailer, :stripe_remediation)
                end.not_to change { user.user_compliance_info_requests.requested.count }
              end
            end

            describe "when Stripe rejects the account with an appeal intervention open (active appeal window)" do
              before do
                stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "rejected.other"
                stripe_event["data"]["object"]["requirements"]["past_due"] = []
                # An appeal-category intervention means the seller is inside an
                # active appeal window: the risk loop suspends them pending the
                # appeal, so the rejection must not be handled as terminal.
                stripe_event["data"]["object"]["requirements"]["currently_due"] =
                  ["interv_1RWtzeAQqMpdRp2IhPb6x4q7.rejection_appeal.support"]
              end

              it "suspends the seller pending the appeal" do
                expect do
                  described_class.handle_stripe_event(stripe_event)
                end.to have_enqueued_mail(ContactingCreatorMailer, :suspended_due_to_stripe_risk).with(user.id)

                expect(user.reload.suspended_for_tos_violation?).to be true
              end

              it "does not send the terminal rejection email" do
                expect do
                  described_class.handle_stripe_event(stripe_event)
                end.not_to have_enqueued_mail(MerchantRegistrationMailer, :stripe_account_rejected)

                expect(merchant_account.reload.stripe_rejection_email_sent).to be_falsey
              end

              it "leaves open verification requests untouched" do
                # A request for the intervention field itself survives the
                # regular request sync (Stripe still lists it), so the only
                # thing that could close it is the terminal-rejection handling
                # — which must not run while the appeal is open.
                request = create(:user_compliance_info_request, user:, field_needed: "interv_1RWtzeAQqMpdRp2IhPb6x4q7.rejection_appeal.support")

                described_class.handle_stripe_event(stripe_event)

                expect(request.reload.state).to eq("requested")
              end
            end

            describe "when Stripe rejects the account but still has open requirements (appealable fork)" do
              before do
                stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "rejected.listed"
                # e.g. Japan `rejected.listed` collision: rejected, but Stripe
                # still wants an identity document — the seller can appeal.
                stripe_event["data"]["object"]["requirements"]["past_due"] = ["individual.verification.document"]
              end

              it "does not close open verification requests" do
                request = create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID)

                described_class.handle_stripe_event(stripe_event)

                expect(request.reload.state).to eq("requested")
              end

              it "re-creates a verification request when none is open locally (failed-document re-request path)" do
                # After a failed upload Stripe re-adds the requirement while the
                # local request was already closed by verify_stripe_remediation —
                # the webhook must recreate it or the appeal path is lost.
                stripe_event["data"]["object"]["requirements"]["past_due"] = ["individual.id_number"]

                expect do
                  described_class.handle_stripe_event(stripe_event)
                end.to change { user.user_compliance_info_requests.requested.count }.by(1)
              end

              it "does not send the terminal rejection email" do
                expect do
                  described_class.handle_stripe_event(stripe_event)
                end.not_to have_enqueued_mail(MerchantRegistrationMailer, :stripe_account_rejected)

                expect(merchant_account.reload.stripe_rejection_email_sent).to be_falsey
              end

              it "still opens a verification request for the document Stripe is asking for" do
                described_class.handle_stripe_event(stripe_event)

                request = user.user_compliance_info_requests.requested.last
                expect(request).to be_present
                expect(request.field_needed).to eq(UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID)
              end

              it "still emails the seller about the outstanding verification" do
                expect do
                  described_class.handle_stripe_event(stripe_event)
                end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, [UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID])
              end
            end
          end

          describe "charges are not explicitly enabled or disabled" do
            let(:merchant_account) { create(:merchant_account, user:) }

            let(:stripe_event) do
              {
                "api_version" => API_VERSION,
                "type" => "account.updated",
                "id" => "stripe-event-id",
                "account" => merchant_account.charge_processor_merchant_id,
                "user_id" => merchant_account.charge_processor_merchant_id,
                "data" => {
                  "object" => {
                    "object" => "account",
                    "id" => merchant_account.charge_processor_merchant_id,
                    "business_type" => "individual",
                    "payouts_enabled" => true,
                    "requirements" => {
                      "current_deadline" => 1_406_748_559, # "2014-07-30T19:29:19+00:00"
                      "currently_due" => [],
                      "eventually_due" => [],
                      "past_due" => [
                        "individual.ssn_last_4"
                      ]
                    }
                  }
                }
              }
            end

            it "does not email the creator about their payments status" do
              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to have_enqueued_mail(MerchantRegistrationMailer, :stripe_charges_disabled)
            end
          end
        end

        describe "payouts_enabled status" do
          describe "in the request payouts are disabled" do
            let(:merchant_account) { create(:merchant_account, user:) }

            let(:stripe_event) do
              {
                "api_version" => API_VERSION,
                "type" => "account.updated",
                "id" => "stripe-event-id",
                "account" => merchant_account.charge_processor_merchant_id,
                "user_id" => merchant_account.charge_processor_merchant_id,
                "data" => {
                  "object" => {
                    "object" => "account",
                    "id" => merchant_account.charge_processor_merchant_id,
                    "business_type" => "individual",
                    "charges_enabled" => true,
                    "payouts_enabled" => false,
                    "requirements" => {
                      "current_deadline" => 1_406_748_559, # "2014-07-30T19:29:19+00:00"
                      "currently_due" => [],
                      "eventually_due" => [],
                      "past_due" => [
                        "individual.ssn_last_4"
                      ]
                    }
                  },
                  "previous_attributes" => {
                    "payouts_enabled" => true
                  }
                }
              }
            end

            # Time is frozen because the assertion below checks the exact timestamp the
            # debounced email job is scheduled for. The matcher truncates both the job's
            # scheduled time and its own expected time to whole seconds, so if the clock
            # crosses a second boundary between the code enqueueing the job and the matcher
            # recomputing the expected time, the two differ by one and the test fails at
            # random. Freezing time makes both sides read the same clock.
            it "pauses payouts, records the Stripe reason as a comment, and notifies the creator by email if payouts are disabled due to info requirement", :freeze_time do
              expect(user.reload.payouts_paused_internally?).to be false
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "requirements.past_due"

              described_class.handle_stripe_event(stripe_event)

              # The email is debounced: the pause applies instantly, but the mailer
              # only goes out via a delayed job that re-checks the pause first.
              expect(StripePayoutsPausedEmailJob).to have_enqueued_sidekiq_job(
                user.id, merchant_account.id, "action_required", kind_of(String)
              ).in(described_class::PAYOUTS_PAUSE_EMAIL_DEBOUNCE_DELAY)

              expect do
                StripePayoutsPausedEmailJob.drain
              end.to have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_disabled).with(user.id)

              expect(user.reload.payouts_paused_internally?).to be true
              comment = user.comments.with_type_payouts_paused.last
              expect(comment).to be_present
              expect(comment.content).to include("requirements.past_due")
              expect(user.payouts_paused_for_reason).to eq(comment.content)
            end

            # The assertions above take the expected delay from the constant itself, so they
            # would still pass if the debounce window shrank to nothing. This pins the actual
            # value, because the window's length is the whole point: it has to be long enough
            # to outlast a routine Stripe re-verification that resolves on its own.
            it "waits half an hour before emailing, so a verification blip that resolves itself never emails the seller" do
              expect(described_class::PAYOUTS_PAUSE_EMAIL_DEBOUNCE_DELAY).to eq(30.minutes)
            end

            it "applies the pause under a user lock and refreshes the merchant account so concurrent webhooks are serialized" do
              expect_any_instance_of(User).to receive(:with_lock).and_call_original
              expect_any_instance_of(MerchantAccount).to receive(:reload).and_call_original

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to change { user.reload.payouts_paused_internally? }.from(false).to(true)
            end

            it "rolls back the pause when the reason comment cannot be written, so a retry can recover" do
              allow_any_instance_of(MerchantAccount).to receive(:stripe_payouts_paused_comment).and_return("")

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to raise_error(ActiveRecord::RecordInvalid)

              expect(user.reload.payouts_paused_internally?).to be false
              expect(user.comments.with_type_payouts_paused).to be_empty
            end

            it "does not overwrite the payout pause source if payouts are already paused internally" do
              user.update!(payouts_paused_internally: true, payouts_paused_by: User.last.id)
              expect(user.reload.payouts_paused_internally?).to be true
              expect(user.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)

              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "requirements.past_due"
              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to change { StripePayoutsPausedEmailJob.jobs.size }

              expect(user.reload.payouts_paused_internally?).to be true
              expect(user.payouts_paused_by).to eq(User.last.id)
              expect(user.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
            end

            it "does not email the creator if payouts are already paused" do
              user.update!(payouts_paused_internally: true)
              expect(user.reload.payouts_paused_internally?).to be true

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to change { StripePayoutsPausedEmailJob.jobs.size }

              expect(user.reload.payouts_paused_internally?).to be true
            end

            it "refreshes the pause reason comment when Stripe's disabled reason changes while already paused by Stripe" do
              user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
              user.comments.create!(
                author_name: "Stripe payouts sync",
                comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED,
                content: "Payouts automatically paused by Stripe (disabled reason: requirements.past_due)."
              )
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "rejected.listed"

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to change { user.comments.with_type_payouts_paused.count }.by(1)

              expect(user.reload.payouts_paused_for_reason).to include("rejected.listed")
            end

            it "does not duplicate the pause reason comment when the Stripe reason is unchanged while already paused by Stripe" do
              user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "requirements.past_due"
              described_class.handle_stripe_event(stripe_event)
              expect(user.comments.with_type_payouts_paused.count).to eq(1)

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to change { user.comments.with_type_payouts_paused.count }
            end

            it "schedules the action-required email once when Stripe escalates an account already paused for review" do
              user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "requirements.pending_verification"
              stripe_event["data"]["object"]["requirements"]["currently_due"] = []
              stripe_event["data"]["object"]["requirements"]["past_due"] = []

              # First notice claims the under-review email.
              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to change { StripePayoutsPausedEmailJob.jobs.size }.by(1)

              stripe_event["data"]["object"]["requirements"]["currently_due"] = ["individual.id_number"]

              # Escalation to action-required claims a second (different) email...
              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to change { StripePayoutsPausedEmailJob.jobs.size }.by(1)

              # ...but a repeat webhook does not claim another.
              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to change { StripePayoutsPausedEmailJob.jobs.size }

              # The escalation rotated the claim token, so the pending under-review
              # job is stale and only the action-required email actually sends.
              expect do
                StripePayoutsPausedEmailJob.drain
              end.to have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_disabled).with(user.id)
                .and(not_have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_under_review))
            end

            it "suppresses the under-review email for a seller with nothing at stake, then sends it once they have a balance" do
              # The shared `user` is built with a 10c balance, so clear it to reach the
              # zero-stakes cohort this suppression exists for (gumroad-private#1721).
              Balance.where(user_id: user.id).delete_all
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "requirements.pending_verification"
              stripe_event["data"]["object"]["requirements"]["currently_due"] = []
              stripe_event["data"]["object"]["requirements"]["past_due"] = []

              described_class.handle_stripe_event(stripe_event)
              expect do
                StripePayoutsPausedEmailJob.drain
              end.to not_have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_under_review)

              # The claim is released, not marked sent, so the same sustained pause can re-claim.
              expect(merchant_account.reload.stripe_payouts_pause_email_claim_token).to be_nil
              expect(user.reload.payouts_paused_internally?).to be true

              create(:balance, user:, amount_cents: 500)

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to change { StripePayoutsPausedEmailJob.jobs.size }.by(1)
              expect do
                StripePayoutsPausedEmailJob.drain
              end.to have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_under_review).with(user.id)
            end

            it "sends the under-review email instead when requirements are satisfied but payouts stay paused before the action-required email sends" do
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "requirements.past_due"

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to change { StripePayoutsPausedEmailJob.jobs.size }.by(1)

              # Within the debounce window the seller satisfies the past-due
              # requirement, but payouts remain disabled pending Stripe's review.
              review_event = stripe_event.deep_dup
              review_event["data"]["object"]["requirements"]["disabled_reason"] = "requirements.pending_verification"
              review_event["data"]["object"]["requirements"]["past_due"] = []
              expect do
                described_class.handle_stripe_event(review_event)
              end.to change { StripePayoutsPausedEmailJob.jobs.size }.by(1)

              # The de-escalation rotated the claim token, so the pending
              # action-required job is stale: the seller is not told to act
              # when nothing is due — only the under-review email sends.
              expect do
                StripePayoutsPausedEmailJob.drain
              end.to have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_under_review).with(user.id)
                .and(not_have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_disabled))
            end

            it "invalidates a pending pause email when the account transitions to a rejected state before the debounce elapses" do
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "requirements.past_due"

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to change { StripePayoutsPausedEmailJob.jobs.size }.by(1)

              # Stripe rejects the account within the debounce window. Telling
              # the seller to provide information now would contradict the
              # rejection, so the claim is dropped entirely.
              rejected_event = stripe_event.deep_dup
              rejected_event["data"]["object"]["requirements"]["disabled_reason"] = "rejected.listed"
              described_class.handle_stripe_event(rejected_event)

              expect(merchant_account.reload.stripe_payouts_pause_email_sent).to be_nil
              expect(merchant_account.stripe_payouts_pause_email_claim_token).to be_nil

              expect do
                StripePayoutsPausedEmailJob.drain
              end.to not_have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_disabled)
                .and(not_have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_under_review))
            end

            it "clears the pause-email marker when Stripe re-enables payouts" do
              merchant_account.update!(stripe_payouts_pause_email_sent: "action_required", stripe_payouts_pause_email_claim_token: "stale-token")
              user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
              stripe_event["data"]["object"]["payouts_enabled"] = true

              described_class.handle_stripe_event(stripe_event)

              expect(merchant_account.reload.stripe_payouts_pause_email_sent).to be_nil
              expect(merchant_account.stripe_payouts_pause_email_claim_token).to be_nil
            end

            it "does not email when the pause resolves before the debounced job runs (Stripe verification blip)" do
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "requirements.past_due"

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to change { StripePayoutsPausedEmailJob.jobs.size }.by(1)

              # Stripe re-enables payouts a minute later, before the debounce
              # window elapses.
              resume_event = stripe_event.deep_dup
              resume_event["data"]["object"]["payouts_enabled"] = true
              described_class.handle_stripe_event(resume_event)
              expect(user.reload.payouts_paused_internally?).to be false

              # The delayed job runs, sees the pause resolved, and sends nothing.
              expect do
                StripePayoutsPausedEmailJob.drain
              end.to not_have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_disabled)
                .and(not_have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_under_review))
            end

            it "does not email when the job runs after a non-Stripe resume, and releases the claim so a later pause can email" do
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "requirements.past_due"
              described_class.handle_stripe_event(stripe_event)

              # An admin resumes payouts before the debounce window elapses. This
              # path does not clear the email marker itself.
              user.update!(payouts_paused_internally: false, payouts_paused_by: nil)

              expect do
                StripePayoutsPausedEmailJob.drain
              end.to not_have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_disabled)
                .and(not_have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_under_review))

              # The skipped email released the claim, as if it was never claimed.
              expect(merchant_account.reload.stripe_payouts_pause_email_sent).to be_nil
              expect(merchant_account.stripe_payouts_pause_email_claim_token).to be_nil
            end

            it "sends exactly one email for the second pause in a pause→resume→pause sequence (only the sustained pause emails)" do
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "requirements.past_due"
              resume_event = stripe_event.deep_dup
              resume_event["data"]["object"]["payouts_enabled"] = true

              # Blip: pause then resume within the window.
              described_class.handle_stripe_event(stripe_event)
              described_class.handle_stripe_event(resume_event)

              # Sustained pause: paused again and still paused when the jobs run.
              described_class.handle_stripe_event(stripe_event)
              expect(StripePayoutsPausedEmailJob.jobs.size).to eq(2)

              # Both delayed jobs run; only the one from the second (sustained)
              # pause matches the current claim token and sends.
              expect do
                StripePayoutsPausedEmailJob.drain
              end.to have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_disabled).with(user.id).once
            end

            it "does not re-send the pause email when re-paused after a non-Stripe resume while Stripe stays disabled" do
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "requirements.past_due"

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to change { StripePayoutsPausedEmailJob.jobs.size }.by(1)

              # an admin or update_payout_method resume clears the internal pause but not the marker
              user.update!(payouts_paused_internally: false, payouts_paused_by: nil)

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to change { StripePayoutsPausedEmailJob.jobs.size }
              expect(user.reload.payouts_paused_internally?).to be true
            end

            it "sends the action-required email for any disabled reason that still has outstanding requirements" do
              expect(user.reload.payouts_paused_internally?).to be false
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "listed"

              described_class.handle_stripe_event(stripe_event)

              expect do
                StripePayoutsPausedEmailJob.drain
              end.to have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_disabled).with(user.id)

              expect(user.reload.payouts_paused_internally?).to be true
              expect(user.payouts_paused_for_reason).to include("listed")
            end

            it "does not email the creator when the platform paused payouts" do
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "platform_paused"

              expect(MerchantRegistrationMailer).not_to receive(:stripe_payouts_disabled)
              expect(MerchantRegistrationMailer).not_to receive(:stripe_payouts_under_review)

              described_class.handle_stripe_event(stripe_event)

              expect(user.reload.payouts_paused_internally?).to be true
              expect(user.payouts_paused_for_reason).to include("platform_paused")
            end

            it "does not email the creator when Stripe rejected the account" do
              stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "rejected.listed"

              expect(MerchantRegistrationMailer).not_to receive(:stripe_payouts_disabled)
              expect(MerchantRegistrationMailer).not_to receive(:stripe_payouts_under_review)

              described_class.handle_stripe_event(stripe_event)

              expect(user.reload.payouts_paused_internally?).to be true
              expect(user.payouts_paused_for_reason).to include("rejected.listed")
            end

            context "when Stripe is not requesting any fields" do
              before do
                stripe_event["data"]["object"]["requirements"]["past_due"] = []
              end

              # Frozen for the same reason as the past_due case above: the matcher compares
              # the job's scheduled-at timestamp against a freshly computed one.
              it "sends the under-review email for a non-rejected reason with no outstanding requirements", :freeze_time do
                stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "requirements.pending_verification"

                described_class.handle_stripe_event(stripe_event)

                expect(StripePayoutsPausedEmailJob).to have_enqueued_sidekiq_job(
                  user.id, merchant_account.id, "under_review", kind_of(String)
                ).in(described_class::PAYOUTS_PAUSE_EMAIL_DEBOUNCE_DELAY)

                expect do
                  StripePayoutsPausedEmailJob.drain
                end.to have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_under_review).with(user.id)

                expect(user.reload.payouts_paused_internally?).to be true
              end

              it "sends the under-review email when only eventually-due (not yet required) fields exist" do
                stripe_event["data"]["object"]["requirements"]["disabled_reason"] = "requirements.pending_verification"
                stripe_event["data"]["object"]["requirements"]["eventually_due"] = ["individual.id_number"]

                described_class.handle_stripe_event(stripe_event)

                expect do
                  StripePayoutsPausedEmailJob.drain
                end.to have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_under_review).with(user.id)

                expect(user.reload.payouts_paused_internally?).to be true
              end
            end
          end

          describe "payouts are not explicitly enabled or disabled" do
            let(:merchant_account) { create(:merchant_account, user:) }

            let(:stripe_event) do
              {
                "api_version" => API_VERSION,
                "type" => "account.updated",
                "id" => "stripe-event-id",
                "account" => merchant_account.charge_processor_merchant_id,
                "user_id" => merchant_account.charge_processor_merchant_id,
                "created" => Time.current.to_i,
                "data" => {
                  "object" => {
                    "object" => "account",
                    "id" => merchant_account.charge_processor_merchant_id,
                    "business_type" => "individual",
                    "requirements" => {
                      "current_deadline" => 1_406_748_559, # "2014-07-30T19:29:19+00:00"
                      "currently_due" => [],
                      "eventually_due" => [],
                      "past_due" => [
                        "individual.ssn_last_4"
                      ]
                    }
                  }
                }
              }
            end

            it "does not pause payouts or email the creator about their payouts status" do
              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_disabled).with(user.id)

              expect(user.reload.payouts_paused_internally?).to be false
            end

            it "does not resume payouts or email the creator about their payouts status" do
              user.update!(payouts_paused_internally: true)

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.not_to have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_disabled).with(user.id)

              expect(user.reload.payouts_paused_internally?).to be true
            end
          end

          describe "payouts are enabled" do
            let(:merchant_account) { create(:merchant_account, user:) }

            let(:stripe_event) do
              {
                "api_version" => API_VERSION,
                "type" => "account.updated",
                "id" => "stripe-event-id",
                "account" => merchant_account.charge_processor_merchant_id,
                "user_id" => merchant_account.charge_processor_merchant_id,
                "data" => {
                  "object" => {
                    "object" => "account",
                    "id" => merchant_account.charge_processor_merchant_id,
                    "business_type" => "individual",
                    "charges_enabled" => true,
                    "payouts_enabled" => true,
                    "requirements" => {
                      "current_deadline" => 1_406_748_559, # "2014-07-30T19:29:19+00:00"
                      "currently_due" => [],
                      "eventually_due" => [],
                      "past_due" => [
                        "individual.ssn_last_4"
                      ]
                    }
                  },
                  "previous_attributes" => {
                    "payouts_enabled" => false
                  }
                }
              }
            end

            it "resumes payouts on the account and records a resume comment if payouts are paused internally by stripe" do
              user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
              expect(user.reload.payouts_paused_internally?).to be true
              expect(user.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_STRIPE)

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to change { user.comments.with_type_payouts_resumed.count }.by(1)

              expect(user.reload.payouts_paused_internally?).to be false
              expect(user.payouts_paused_by).to be nil
              expect(user.payouts_paused_by_source).to be nil
            end

            it "notes that payouts remain creator-paused when Stripe re-enables an account the creator also paused" do
              user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
              user.update!(payouts_paused_by_user: true)

              described_class.handle_stripe_event(stripe_event)

              user.reload
              expect(user.payouts_paused_internally?).to be false
              expect(user.payouts_paused?).to be true # still paused by the creator
              expect(user.comments.with_type_payouts_resumed.last.content).to include("remain paused by the creator")
            end

            it "rolls back the resume when clearing the pause-email marker fails, so a retry can recover" do
              merchant_account.update!(stripe_payouts_pause_email_sent: "action_required")
              user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
              allow_any_instance_of(MerchantAccount).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)

              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to raise_error(ActiveRecord::RecordInvalid)

              expect(user.reload.payouts_paused_internally?).to be true
              expect(user.comments.with_type_payouts_resumed.count).to eq(0)
            end

            it "does not resume payouts if payouts are paused internally by admin" do
              user.update!(payouts_paused_internally: true, payouts_paused_by: User.last.id)
              expect(user.reload.payouts_paused_internally?).to be true
              expect(user.payouts_paused_by).to eq(User.last.id)
              expect(user.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)

              described_class.handle_stripe_event(stripe_event)

              expect(user.reload.payouts_paused_internally?).to be true
              expect(user.payouts_paused_by).to eq(User.last.id)
              expect(user.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
            end

            it "does not resume payouts if payouts are paused internally by system" do
              user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
              expect(user.reload.payouts_paused_internally?).to be true
              expect(user.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_SYSTEM)

              described_class.handle_stripe_event(stripe_event)

              expect(user.reload.payouts_paused_internally?).to be true
              expect(user.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_SYSTEM)
            end
          end
        end

        describe "future requirements" do
          let(:merchant_account) { create(:merchant_account, user:) }

          let(:stripe_event) do
            {
              "api_version" => API_VERSION,
              "type" => "account.updated",
              "id" => "stripe-event-id",
              "account" => merchant_account.charge_processor_merchant_id,
              "user_id" => merchant_account.charge_processor_merchant_id,
              "data" => {
                "object" => {
                  "object" => "account",
                  "id" => merchant_account.charge_processor_merchant_id,
                  "business_type" => "individual",
                  "charges_enabled" => true,
                  "payouts_enabled" => true,
                  "requirements" => {
                    "current_deadline" => nil,
                    "currently_due" => [],
                    "eventually_due" => [],
                    "past_due" => []
                  },
                  "future_requirements" => {
                    "current_deadline" => 1712086847,
                    "currently_due" => ["individual.id_number"],
                    "eventually_due" => [],
                    "past_due" => []
                  }
                }
              }
            }
          end

          it "adds user compliance info request for future requirements and send kyc email to the creator" do
            expect do
              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w[individual_tax_id])
            end.to change(UserComplianceInfoRequest, :count).by(1)

            user_compliance_info_request = UserComplianceInfoRequest.last
            expect(user_compliance_info_request.user).to eq(user)
            expect(user_compliance_info_request.field_needed).to eq(UserComplianceInfoFields::Individual::TAX_ID)
            expect(user_compliance_info_request.only_needs_field_to_be_partially_provided).to be false
            expect(user_compliance_info_request.due_at).to eq(Time.zone.at(1712086847))
            expect(user_compliance_info_request.stripe_event_id).to eq("stripe-event-id")
          end
        end

        describe "alternative fields due" do
          let(:merchant_account) { create(:merchant_account, user:) }

          let(:stripe_event) do
            {
              "api_version" => API_VERSION,
              "type" => "account.updated",
              "id" => "stripe-event-id",
              "account" => merchant_account.charge_processor_merchant_id,
              "user_id" => merchant_account.charge_processor_merchant_id,
              "data" => {
                "object" => {
                  "object" => "account",
                  "id" => merchant_account.charge_processor_merchant_id,
                  "business_type" => "individual",
                  "charges_enabled" => true,
                  "payouts_enabled" => true,
                  "requirements" => {
                    "alternatives" => [
                      {
                        "alternative_fields_due" => [
                          "individual.verification.document"
                        ],
                        "original_fields_due" => [
                          "individual.address.line1"
                        ]
                      }
                    ],
                    "current_deadline" => 1712086848,
                    "currently_due" => [],
                    "eventually_due" => [],
                    "past_due" => []
                  },
                  "future_requirements" => {
                    "alternatives" => [
                      {
                        "alternative_fields_due" => [
                          "individual.verification.additional_document"
                        ],
                        "original_fields_due" => [
                          "individual.address.postal_code"
                        ]
                      }
                    ],
                    "current_deadline" => 1712086847,
                    "currently_due" => [],
                    "eventually_due" => [],
                    "past_due" => []
                  }
                }
              }
            }
          end

          it "adds user compliance info request for alternative fields due and sends kyc email to the creator" do
            expect do
              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w[stripe_identity_document_id stripe_additional_document_id])
            end.to change(UserComplianceInfoRequest, :count).by(2)

            user_compliance_info_request = UserComplianceInfoRequest.last(2).first
            expect(user_compliance_info_request.user).to eq(user)
            expect(user_compliance_info_request.field_needed).to eq(UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID)
            expect(user_compliance_info_request.only_needs_field_to_be_partially_provided).to be false
            expect(user_compliance_info_request.due_at).to eq(Time.zone.at(1712086847))
            expect(user_compliance_info_request.stripe_event_id).to eq("stripe-event-id")

            user_compliance_info_request = UserComplianceInfoRequest.last
            expect(user_compliance_info_request.user).to eq(user)
            expect(user_compliance_info_request.field_needed).to eq(UserComplianceInfoFields::Individual::STRIPE_ADDITIONAL_DOCUMENT_ID)
            expect(user_compliance_info_request.only_needs_field_to_be_partially_provided).to be false
            expect(user_compliance_info_request.due_at).to eq(Time.zone.at(1712086847))
            expect(user_compliance_info_request.stripe_event_id).to eq("stripe-event-id")
          end
        end
      end

      describe "multiple fields needed for verification that map to one field internally" do
        let(:merchant_account) { create(:merchant_account, user:) }

        let(:stripe_event) do
          {
            "api_version" => API_VERSION,
            "type" => "account.updated",
            "id" => "stripe-event-id",
            "account" => merchant_account.charge_processor_merchant_id,
            "user_id" => merchant_account.charge_processor_merchant_id,
            "data" => {
              "object" => {
                "object" => "account",
                "id" => merchant_account.charge_processor_merchant_id,
                "business_type" => "individual",
                "charges_enabled" => true,
                "payouts_enabled" => true,
                "requirements" => {
                  "current_deadline" => 1_406_748_559, # "2014-07-30T19:29:19+00:00"
                  "currently_due" => [
                    "individual.dob.day",
                    "individual.dob.month",
                    "individual.dob.year"
                  ],
                  "eventually_due" => [
                    "company.tax_id"
                  ],
                  "past_due" => [
                    "individual.ssn_last_4",
                    "individual.id_number"
                  ]
                }
              }
            }
          }
        end

        it "it should create a user compliance info request record" do
          described_class.handle_stripe_event(stripe_event)
          user_compliance_info_requests = UserComplianceInfoRequest.all
          expect(user_compliance_info_requests[0].user).to eq(user)
          expect(user_compliance_info_requests[0].field_needed).to eq(UserComplianceInfoFields::Individual::DATE_OF_BIRTH)
          expect(user_compliance_info_requests[0].only_needs_field_to_be_partially_provided).to eq(false)
          expect(user_compliance_info_requests[0].due_at).to eq(Time.zone.at(1_406_748_559))
          expect(user_compliance_info_requests[0].stripe_event_id).to eq("stripe-event-id")
          expect(user_compliance_info_requests[1].user).to eq(user)
          expect(user_compliance_info_requests[1].field_needed).to eq(UserComplianceInfoFields::Business::TAX_ID)
          expect(user_compliance_info_requests[1].only_needs_field_to_be_partially_provided).to eq(false)
          expect(user_compliance_info_requests[1].due_at).to eq(Time.zone.at(1_406_748_559))
          expect(user_compliance_info_requests[1].stripe_event_id).to eq("stripe-event-id")
          expect(user_compliance_info_requests[2].user).to eq(user)
          expect(user_compliance_info_requests[2].field_needed).to eq(UserComplianceInfoFields::Individual::TAX_ID)
          expect(user_compliance_info_requests[2].only_needs_field_to_be_partially_provided).to eq(true)
          expect(user_compliance_info_requests[2].due_at).to eq(Time.zone.at(1_406_748_559))
          expect(user_compliance_info_requests[2].stripe_event_id).to eq("stripe-event-id")
          expect(user_compliance_info_requests[3].user).to eq(user)
          expect(user_compliance_info_requests[3].field_needed).to eq(UserComplianceInfoFields::Individual::TAX_ID)
          expect(user_compliance_info_requests[3].only_needs_field_to_be_partially_provided).to eq(false)
          expect(user_compliance_info_requests[3].due_at).to eq(Time.zone.at(1_406_748_559))
          expect(user_compliance_info_requests[3].stripe_event_id).to eq("stripe-event-id")
        end

        it "emails the creator" do
          expect do
            described_class.handle_stripe_event(stripe_event)
          end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w[birthday business_tax_id individual_tax_id])
        end

        it "records the email being sent on the requests for user compliance info" do
          frozen_time = Time.current.change(usec: 0)

          travel_to(frozen_time) do
            described_class.handle_stripe_event(stripe_event)
          end

          user_compliance_info_requests = UserComplianceInfoRequest.all
          expect(user_compliance_info_requests[0].emails_sent_at).to eq([frozen_time])
          expect(user_compliance_info_requests[1].emails_sent_at).to eq([frozen_time])
          expect(user_compliance_info_requests[2].emails_sent_at).to eq([frozen_time])
          expect(user_compliance_info_requests[3].emails_sent_at).to eq([frozen_time])
        end

        it "results in the requests having a last contact at time of when the contact was made" do
          frozen_time = Time.current.change(usec: 0)

          travel_to(frozen_time) do
            described_class.handle_stripe_event(stripe_event)
          end

          user_compliance_info_requests = UserComplianceInfoRequest.all
          expect(user_compliance_info_requests[0].last_email_sent_at).to eq(frozen_time)
          expect(user_compliance_info_requests[1].last_email_sent_at).to eq(frozen_time)
          expect(user_compliance_info_requests[2].last_email_sent_at).to eq(frozen_time)
          expect(user_compliance_info_requests[3].last_email_sent_at).to eq(frozen_time)
        end
      end

      describe "person's fields need verification when company account" do
        let(:merchant_account) { create(:merchant_account, user:) }

        let(:stripe_event) do
          {
            "api_version" => API_VERSION,
            "type" => "account.updated",
            "id" => "stripe-event-id",
            "account" => merchant_account.charge_processor_merchant_id,
            "user_id" => merchant_account.charge_processor_merchant_id,
            "data" => {
              "object" => {
                "object" => "account",
                "id" => merchant_account.charge_processor_merchant_id,
                "business_type" => "company",
                "charges_enabled" => true,
                "payouts_enabled" => true,
                "requirements" => {
                  "current_deadline" => 1_406_748_559, # "2014-07-30T19:29:19+00:00"
                  "currently_due" => [
                    "person_IRWHQ2ZRlwIh1j.dob.day",
                    "person_IRWHQ2ZRlwIh1j.dob.month",
                    "person_IRWHQ2ZRlwIh1j.dob.year"
                  ],
                  "eventually_due" => [
                    "company.tax_id"
                  ],
                  "past_due" => [
                    "person_IRWHQ2ZRlwIh1j.ssn_last_4",
                    "person_IRWHQ2ZRlwIh1j.id_number"
                  ]
                }
              }
            }
          }
        end

        before do
          expect(Stripe::Account).to receive(:list_persons).and_return([
                                                                         {
                                                                           "id" => "person_IRWHQ2ZRlwIh1j",
                                                                           "object" => "person",
                                                                           "account" => merchant_account.charge_processor_merchant_id,
                                                                           "verification" => {
                                                                             "status" => "unverified"
                                                                           }
                                                                         }
                                                                       ])
        end

        it "creates user compliance info request records" do
          described_class.handle_stripe_event(stripe_event)
          user_compliance_info_requests = UserComplianceInfoRequest.all
          expect(user_compliance_info_requests[0].user).to eq(user)
          expect(user_compliance_info_requests[0].field_needed).to eq(UserComplianceInfoFields::Individual::DATE_OF_BIRTH)
          expect(user_compliance_info_requests[0].only_needs_field_to_be_partially_provided).to eq(false)
          expect(user_compliance_info_requests[0].due_at).to eq(Time.zone.at(1_406_748_559))
          expect(user_compliance_info_requests[0].stripe_event_id).to eq("stripe-event-id")
          expect(user_compliance_info_requests[1].user).to eq(user)
          expect(user_compliance_info_requests[1].field_needed).to eq(UserComplianceInfoFields::Business::TAX_ID)
          expect(user_compliance_info_requests[1].only_needs_field_to_be_partially_provided).to eq(false)
          expect(user_compliance_info_requests[1].due_at).to eq(Time.zone.at(1_406_748_559))
          expect(user_compliance_info_requests[1].stripe_event_id).to eq("stripe-event-id")
          expect(user_compliance_info_requests[2].user).to eq(user)
          expect(user_compliance_info_requests[2].field_needed).to eq(UserComplianceInfoFields::Individual::TAX_ID)
          expect(user_compliance_info_requests[2].only_needs_field_to_be_partially_provided).to eq(true)
          expect(user_compliance_info_requests[2].due_at).to eq(Time.zone.at(1_406_748_559))
          expect(user_compliance_info_requests[2].stripe_event_id).to eq("stripe-event-id")
          expect(user_compliance_info_requests[3].user).to eq(user)
          expect(user_compliance_info_requests[3].field_needed).to eq(UserComplianceInfoFields::Individual::TAX_ID)
          expect(user_compliance_info_requests[3].only_needs_field_to_be_partially_provided).to eq(false)
          expect(user_compliance_info_requests[3].due_at).to eq(Time.zone.at(1_406_748_559))
          expect(user_compliance_info_requests[3].stripe_event_id).to eq("stripe-event-id")
        end

        it "emails the creator" do
          expect do
            described_class.handle_stripe_event(stripe_event)
          end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w[birthday business_tax_id individual_tax_id])
        end

        it "records the email being sent on the requests for user compliance info" do
          frozen_time = Time.current.change(usec: 0)

          travel_to(frozen_time) do
            described_class.handle_stripe_event(stripe_event)
          end

          user_compliance_info_requests = UserComplianceInfoRequest.all
          expect(user_compliance_info_requests[0].emails_sent_at).to eq([frozen_time])
          expect(user_compliance_info_requests[1].emails_sent_at).to eq([frozen_time])
          expect(user_compliance_info_requests[2].emails_sent_at).to eq([frozen_time])
          expect(user_compliance_info_requests[3].emails_sent_at).to eq([frozen_time])
        end

        it "results in the requests having a last contact at time of when the contact was made" do
          frozen_time = Time.current.change(usec: 0)

          travel_to(frozen_time) do
            described_class.handle_stripe_event(stripe_event)
          end

          user_compliance_info_requests = UserComplianceInfoRequest.all
          expect(user_compliance_info_requests[0].last_email_sent_at).to eq(frozen_time)
          expect(user_compliance_info_requests[1].last_email_sent_at).to eq(frozen_time)
          expect(user_compliance_info_requests[2].last_email_sent_at).to eq(frozen_time)
          expect(user_compliance_info_requests[3].last_email_sent_at).to eq(frozen_time)
        end
      end

      describe "multiple requests for information" do
        let(:merchant_account) { create(:merchant_account, user:) }

        let(:stripe_event_1) do
          {
            "api_version" => API_VERSION,
            "type" => "account.updated",
            "id" => "stripe-event-id-1",
            "account" => merchant_account.charge_processor_merchant_id,
            "user_id" => merchant_account.charge_processor_merchant_id,
            "data" => {
              "object" => {
                "object" => "account",
                "id" => merchant_account.charge_processor_merchant_id,
                "business_type" => "individual",
                "requirements" => {
                  "current_deadline" => 1_406_748_559, # "2014-07-30T19:29:19+00:00"
                  "currently_due" => [
                    "individual.dob.day",
                    "individual.dob.month",
                    "individual.dob.year"
                  ],
                  "eventually_due" => [],
                  "past_due" => [
                    "company.tax_id"
                  ]
                }
              }
            }
          }
        end

        let(:stripe_event_2) do
          {
            "api_version" => API_VERSION,
            "type" => "account.updated",
            "id" => "stripe-event-id-2",
            "account" => merchant_account.charge_processor_merchant_id,
            "user_id" => merchant_account.charge_processor_merchant_id,
            "data" => {
              "object" => {
                "object" => "account",
                "id" => merchant_account.charge_processor_merchant_id,
                "business_type" => "individual",
                "requirements" => {
                  "current_deadline" => 1712086846,
                  "currently_due" => [
                    "individual.dob.day",
                    "individual.dob.month",
                    "individual.dob.year"
                  ],
                  "eventually_due" => [],
                  "past_due" => ["individual.ssn_last_4"]
                },
                "future_requirements" => {
                  "current_deadline" => 1712086847,
                  "currently_due" => ["individual.id_number"],
                  "eventually_due" => [],
                  "past_due" => []
                }
              }
            }
          }
        end

        it "it creates a user compliance info request record" do
          described_class.handle_stripe_event(stripe_event_1)
          described_class.handle_stripe_event(stripe_event_2)
          user_compliance_info_requests = UserComplianceInfoRequest.all
          expect(user_compliance_info_requests[0].user).to eq(user)
          expect(user_compliance_info_requests[0].field_needed).to eq(UserComplianceInfoFields::Individual::DATE_OF_BIRTH)
          expect(user_compliance_info_requests[0].only_needs_field_to_be_partially_provided).to eq(false)
          expect(user_compliance_info_requests[0].due_at).to eq(Time.zone.at(1_406_748_559))
          expect(user_compliance_info_requests[0].stripe_event_id).to eq("stripe-event-id-1")
          expect(user_compliance_info_requests[0].provided?).to be_falsey
          expect(user_compliance_info_requests[1].user).to eq(user)
          expect(user_compliance_info_requests[1].field_needed).to eq(UserComplianceInfoFields::Business::TAX_ID)
          expect(user_compliance_info_requests[1].only_needs_field_to_be_partially_provided).to eq(false)
          expect(user_compliance_info_requests[1].due_at).to eq(Time.zone.at(1_406_748_559))
          expect(user_compliance_info_requests[1].stripe_event_id).to eq("stripe-event-id-1")
          expect(user_compliance_info_requests[1].provided?).to be_truthy
          expect(user_compliance_info_requests[2].user).to eq(user)
          expect(user_compliance_info_requests[2].field_needed).to eq(UserComplianceInfoFields::Individual::TAX_ID)
          expect(user_compliance_info_requests[2].only_needs_field_to_be_partially_provided).to eq(true)
          expect(user_compliance_info_requests[2].due_at).to eq(Time.zone.at(1712086846))
          expect(user_compliance_info_requests[2].stripe_event_id).to eq("stripe-event-id-2")
          expect(user_compliance_info_requests[2].provided?).to be_falsey
          expect(user_compliance_info_requests[3].user).to eq(user)
          expect(user_compliance_info_requests[3].field_needed).to eq(UserComplianceInfoFields::Individual::TAX_ID)
          expect(user_compliance_info_requests[3].only_needs_field_to_be_partially_provided).to eq(false)
          expect(user_compliance_info_requests[3].due_at).to eq(Time.zone.at(1712086846))
          expect(user_compliance_info_requests[3].stripe_event_id).to eq("stripe-event-id-2")
          expect(user_compliance_info_requests[3].provided?).to be_falsey
        end

        it "emails the creator" do
          expect do
            described_class.handle_stripe_event(stripe_event_1)
          end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w[birthday business_tax_id])

          expect do
            described_class.handle_stripe_event(stripe_event_2)
          end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w[birthday individual_tax_id])
        end

        it "records the email being sent on the requests for user compliance info when the information is requested" do
          frozen_time = Time.current.change(usec: 0)

          travel_to(frozen_time) do
            StripeMerchantAccountManager.handle_stripe_event(stripe_event_1)
          end

          user_compliance_info_requests = UserComplianceInfoRequest.all
          expect(user_compliance_info_requests[0].emails_sent_at).to eq([frozen_time])

          travel_to(frozen_time) do
            described_class.handle_stripe_event(stripe_event_2)
          end

          user_compliance_info_requests = UserComplianceInfoRequest.all
          expect(user_compliance_info_requests[0].emails_sent_at).to eq([frozen_time])
          expect(user_compliance_info_requests[1].emails_sent_at).to eq([frozen_time])
          expect(user_compliance_info_requests[2].emails_sent_at).to eq([frozen_time])
          expect(user_compliance_info_requests[3].emails_sent_at).to eq([frozen_time])
        end

        describe "same set of information requested again" do
          let(:merchant_account) { create(:merchant_account, user:) }

          let(:stripe_event_1) do
            {
              "api_version" => API_VERSION,
              "type" => "account.updated",
              "id" => "stripe-event-id-1",
              "account" => merchant_account.charge_processor_merchant_id,
              "user_id" => merchant_account.charge_processor_merchant_id,
              "data" => {
                "object" => {
                  "object" => "account",
                  "id" => merchant_account.charge_processor_merchant_id,
                  "business_type" => "individual",
                  "requirements" => {
                    "current_deadline" => 1712086846,
                    "currently_due" => ["individual.verification.document"],
                    "eventually_due" => [],
                    "past_due" => ["individual.id_number"]
                  },
                  "future_requirements" => {
                    "current_deadline" => 1712086847,
                    "currently_due" => ["individual.verification.additional_document"],
                    "eventually_due" => [],
                    "past_due" => []
                  }
                }
              }
            }
          end

          let(:stripe_event_2) do
            {
              "api_version" => API_VERSION,
              "type" => "account.updated",
              "id" => "stripe-event-id-2",
              "account" => merchant_account.charge_processor_merchant_id,
              "user_id" => merchant_account.charge_processor_merchant_id,
              "data" => {
                "object" => {
                  "object" => "account",
                  "id" => merchant_account.charge_processor_merchant_id,
                  "business_type" => "individual",
                  "requirements" => {
                    "current_deadline" => 1712086846,
                    "currently_due" => ["individual.verification.document", "individual.verification.additional_document"],
                    "eventually_due" => [],
                    "past_due" => ["individual.id_number"]
                  }
                }
              }
            }
          end

          it "sends the kyc email again if it has been over 3 months since the last kyc email was sent for the same info" do
            travel_to(Time.find_zone("UTC").local(2024, 10, 1)) do
              expect do
                described_class.handle_stripe_event(stripe_event_1)
              end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w[stripe_identity_document_id individual_tax_id stripe_additional_document_id])
            end

            travel_to(Time.find_zone("UTC").local(2025, 1, 2)) do
              expect do
                described_class.handle_stripe_event(stripe_event_2)
              end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w[stripe_identity_document_id individual_tax_id stripe_additional_document_id])
            end
          end

          it "does not resend kyc email if last kyc email for the same info was sent less than 1 month ago" do
            travel_to(Time.find_zone("UTC").local(2024, 11, 1)) do
              expect do
                described_class.handle_stripe_event(stripe_event_1)
              end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w[stripe_identity_document_id individual_tax_id stripe_additional_document_id])
            end

            travel_to(Time.find_zone("UTC").local(2024, 11, 30)) do
              expect do
                described_class.handle_stripe_event(stripe_event_2)
              end.not_to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed)
            end
          end
        end
      end

      describe "request for information without a due by" do
        let(:merchant_account) { create(:merchant_account, user:) }

        let(:stripe_event_1) do
          {
            "api_version" => API_VERSION,
            "type" => "account.updated",
            "id" => "stripe-event-id-1",
            "account" => merchant_account.charge_processor_merchant_id,
            "user_id" => merchant_account.charge_processor_merchant_id,
            "data" => {
              "object" => {
                "object" => "account",
                "id" => merchant_account.charge_processor_merchant_id,
                "business_type" => "individual",
                "requirements" => {
                  "currently_due" => [],
                  "eventually_due" => [],
                  "past_due" => [
                    "individual.dob.day",
                    "individual.dob.month",
                    "individual.dob.year"
                  ]
                }
              }
            }
          }
        end

        it "creates a user compliance info request record" do
          described_class.handle_stripe_event(stripe_event_1)
          expect(UserComplianceInfoRequest.count).to eq 1
        end

        it "emails the creator" do
          expect do
            described_class.handle_stripe_event(stripe_event_1)
          end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w[birthday])
        end
      end

      describe "account.updated event with charges enabled and bank account that needs syncing to Stripe", :vcr do
        let(:user) { create(:user) }
        let(:user_compliance_info) { create(:user_compliance_info, user:) }
        let(:tos_agreement) { create(:tos_agreement, user:) }
        let(:bank_account) { create(:card_bank_account, user:, stripe_connect_account_id: nil, stripe_external_account_id: nil) }
        let(:merchant_account) { create(:merchant_account, user:, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id) }

        before do
          user
          user_compliance_info
          tos_agreement
          bank_account
          merchant_account
        end

        let(:stripe_event_1) do
          {
            "api_version" => API_VERSION,
            "type" => "account.updated",
            "id" => "evt_id",
            "user_id" => merchant_account.charge_processor_merchant_id,
            "data" => {
              "object" => {
                "object" => "account",
                "id" => merchant_account.charge_processor_merchant_id,
                "business_type" => "individual",
                "charges_enabled" => true,
                "requirements" => {
                  "currently_due" => [],
                  "eventually_due" => [],
                  "past_due" => []
                }
              }
            }
          }
        end

        it "syncs bank account details to Stripe" do
          described_class.handle_stripe_event(stripe_event_1)

          expect(user.active_bank_account.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
          expect(user.active_bank_account.stripe_external_account_id).to be_present
        end

        it "removes request for a card bank account if present" do
          stripe_event_1["data"]["object"]["requirements"]["past_due"] = ["external_account"]

          expect do
            described_class.handle_stripe_event(stripe_event_1)
          end.to_not have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed)

          expect(UserComplianceInfoRequest.count).to eq 0
        end
      end

      describe "account.updated event with charges disabled for user with card bank account", :vcr do
        let(:user) { create(:user) }
        let(:user_compliance_info) { create(:user_compliance_info, user:) }
        let(:tos_agreement) { create(:tos_agreement, user:) }
        let(:bank_account) { create(:card_bank_account, user:) }
        let(:merchant_account) { create(:merchant_account, charge_processor_merchant_id: "ac1", user:) }

        before do
          user
          user_compliance_info
          tos_agreement
          bank_account
          merchant_account
        end

        let(:stripe_event_1) do
          {
            "api_version" => API_VERSION,
            "type" => "account.updated",
            "id" => "stripe-event-id-1",
            "account" => "ac1",
            "user_id" => "ac1",
            "data" => {
              "object" => {
                "object" => "account",
                "id" => "ac1",
                "business_type" => "individual",
                "charges_enabled" => false,
                "requirements" => {
                  "currently_due" => [],
                  "eventually_due" => [],
                  "past_due" => [
                    "external_account"
                  ]
                }
              }
            }
          }
        end

        it "does not add request record or send kyc email if only bank account is requested" do
          expect do
            described_class.handle_stripe_event(stripe_event_1)
          end.to_not have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed)
          expect(UserComplianceInfoRequest.count).to eq 0
        end

        it "adds request record and sends kyc email for fields other than bank account" do
          stripe_event_1["data"]["object"]["requirements"]["past_due"] << "individual.id_number"

          expect do
            described_class.handle_stripe_event(stripe_event_1)
          end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w(individual_tax_id))

          expect(UserComplianceInfoRequest.count).to eq 1
          expect(UserComplianceInfoRequest.last.user).to eq(user)
          expect(UserComplianceInfoRequest.last.field_needed).to eq("individual_tax_id")
          expect(UserComplianceInfoRequest.last.stripe_event_id).to eq("stripe-event-id-1")
        end
      end

      describe "requests for information including some unrecognized fields" do
        let(:merchant_account) { create(:merchant_account, user:, charge_processor_merchant_id: "ac1") }

        let(:stripe_event_1) do
          {
            "api_version" => API_VERSION,
            "type" => "account.updated",
            "id" => "stripe-event-id-1",
            "account" => merchant_account.charge_processor_merchant_id,
            "user_id" => merchant_account.charge_processor_merchant_id,
            "data" => {
              "object" => {
                "object" => "account",
                "id" => merchant_account.charge_processor_merchant_id,
                "business_type" => "individual",
                "requirements" => {
                  "currently_due" => [],
                  "eventually_due" => [],
                  "past_due" => [
                    "individual.verification.unrecognized_field",
                    "individual.verification.additional_document",
                    "individual.verification.document"
                  ]
                }
              }
            }
          }
        end

        it "creates a user compliance info request record for all fields emails the creator" do
          expect do
            described_class.handle_stripe_event(stripe_event_1)
          end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w(individual.verification.unrecognized_field stripe_additional_document_id stripe_identity_document_id))

          expect(UserComplianceInfoRequest.count).to eq 3
          expect(user.user_compliance_info_requests.requested.pluck(:field_needed)).to match_array([UserComplianceInfoFields::Individual::STRIPE_ADDITIONAL_DOCUMENT_ID, UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID, "individual.verification.unrecognized_field"])
        end
      end

      it "removes all existing user_compliance_info_requests for the user if account is verified" do
        merchant_account = create(:merchant_account, user:, charge_processor_merchant_id: "ac1")
        create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID)
        create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::TAX_ID)
        expect(user.user_compliance_info_requests.requested.count).to eq(2)

        stripe_event =
          {
            "api_version" => API_VERSION,
            "type" => "account.updated",
            "id" => "stripe-event-id-1",
            "account" => merchant_account.charge_processor_merchant_id,
            "user_id" => merchant_account.charge_processor_merchant_id,
            "data" => {
              "object" => {
                "object" => "account",
                "id" => merchant_account.charge_processor_merchant_id,
                "business_type" => "individual",
                "individual" => {
                  "verification" => {
                    "status" => "verified"
                  }
                },
                "requirements" => {
                  "currently_due" => [],
                  "eventually_due" => [],
                  "past_due" => []
                }
              }
            }
          }

        described_class.handle_stripe_event(stripe_event)

        expect(user.user_compliance_info_requests.requested.count).to eq(0)
      end

      context "when ID is already provided but requested again" do
        let!(:merchant_account) { create(:merchant_account, user:, charge_processor_merchant_id: "ac1") }

        let(:stripe_event) do
          {
            "api_version" => API_VERSION,
            "type" => "account.updated",
            "id" => "stripe-event-id-1",
            "account" => merchant_account.charge_processor_merchant_id,
            "user_id" => merchant_account.charge_processor_merchant_id,
            "data" => {
              "object" => {
                "object" => "account",
                "id" => merchant_account.charge_processor_merchant_id,
                "business_type" => "individual",
                "requirements" => {
                  "currently_due" => [],
                  "eventually_due" => [],
                  "past_due" => [
                    "individual.verification.document"
                  ]
                }
              }
            }
          }
        end

        before do
          create(:user_compliance_info_request, user:, state: "provided", field_needed: UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID)
        end

        it "saves the verification error code and the message sent by Stripe" do
          stripe_error_code = "verification_document_failed_test_mode"
          stripe_error_reason = "A test data helper was supplied to simulate verification failure."
          stripe_event["data"]["object"]["requirements"]["errors"] = [
            {
              "code" => stripe_error_code,
              "reason" => stripe_error_reason,
              "requirement" => "individual.verification.document"
            }]

          described_class.handle_stripe_event(stripe_event)

          expect(user.user_compliance_info_requests.requested.count).to eq(1)
          user_compliance_info_request = user.user_compliance_info_requests.requested.first
          expect(user_compliance_info_request.field_needed).to eq(UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID)
          expect(user_compliance_info_request.verification_error["code"]).to eq(stripe_error_code)
          expect(user_compliance_info_request.verification_error["reason"]).to eq stripe_error_reason
        end

        it "sends the identity verification failed email instead of generic more kyc needed email" do
          stripe_error_code = "verification_failed_keyed_identity"
          stripe_error_reason = "The identity information you entered cannot be verified. Please correct any errors or upload a document that matches the identity fields (e.g., name and date of birth) that you entered."
          stripe_event["data"]["object"]["requirements"]["errors"] = [
            {
              "code" => stripe_error_code,
              "reason" => stripe_error_reason,
              "requirement" => "individual.verification.document"
            }]

          expect do
            expect do
              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to have_enqueued_mail(ContactingCreatorMailer, :stripe_identity_verification_failed).with(user.id, stripe_error_reason)
            end.not_to have_enqueued_mail(ContactingCreatorMailer, :stripe_document_verification_failed).with(user.id, anything)
          end.not_to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed)

          expect(user.user_compliance_info_requests.requested.count).to eq(1)
          user_compliance_info_request = user.user_compliance_info_requests.requested.first
          expect(user_compliance_info_request.field_needed).to eq(UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID)
          expect(user_compliance_info_request.verification_error["code"]).to eq(stripe_error_code)
        end

        it "sends the document verification failed email instead of generic more kyc needed email if it's a document error" do
          stripe_error_code = "verification_document_failed_test_mode"
          stripe_error_reason = "A test data helper was supplied to simulate verification failure."
          stripe_event["data"]["object"]["requirements"]["errors"] = [
            {
              "code" => stripe_error_code,
              "reason" => stripe_error_reason,
              "requirement" => "individual.verification.document"
            }]

          expect do
            expect do
              expect do
                described_class.handle_stripe_event(stripe_event)
              end.to have_enqueued_mail(ContactingCreatorMailer, :stripe_document_verification_failed).with(user.id, stripe_error_reason)
            end.not_to have_enqueued_mail(ContactingCreatorMailer, :stripe_identity_verification_failed).with(user.id, anything)
          end.not_to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed)

          expect(user.user_compliance_info_requests.requested.count).to eq(1)
          user_compliance_info_request = user.user_compliance_info_requests.requested.first
          expect(user_compliance_info_request.field_needed).to eq(UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID)
          expect(user_compliance_info_request.verification_error["code"]).to eq(stripe_error_code)
          expect(user_compliance_info_request.verification_error["reason"]).to eq stripe_error_reason
        end

        it "does not send an email when the user account is deleted" do
          user.mark_deleted!

          expect do
            expect do
              described_class.handle_stripe_event(stripe_event)
            end.not_to have_enqueued_mail(ContactingCreatorMailer, :id_mismatch_on_stripe).with(user.id)
          end.not_to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed)
        end

        it "emails the P.O. Box explanation instead of Stripe's unactionable address mismatch reason" do
          create(:user_compliance_info, user:, street_address: "PO Box 65")
          stripe_event["data"]["object"]["requirements"]["errors"] = [
            {
              "code" => "verification_document_address_mismatch",
              "reason" => "Address on the account doesn't match the verification document.",
              "requirement" => "individual.verification.document"
            }]

          expect do
            described_class.handle_stripe_event(stripe_event)
          end.to have_enqueued_mail(ContactingCreatorMailer, :stripe_document_verification_failed)
            .with(user.id, UserComplianceInfoRequest::PO_BOX_ADDRESS_DEADLOCK_MESSAGE)
        end

        it "still emails Stripe's reason for an address mismatch when no P.O. Box is involved" do
          create(:user_compliance_info, user:, street_address: "123 Main Street")
          stripe_error_reason = "Address on the account doesn't match the verification document."
          stripe_event["data"]["object"]["requirements"]["errors"] = [
            {
              "code" => "verification_document_address_mismatch",
              "reason" => stripe_error_reason,
              "requirement" => "individual.verification.document"
            }]

          expect do
            described_class.handle_stripe_event(stripe_event)
          end.to have_enqueued_mail(ContactingCreatorMailer, :stripe_document_verification_failed).with(user.id, stripe_error_reason)
        end

        it "does not send an email when the user account is suspended" do
          admin = create(:admin_user)
          user.flag_for_fraud!(author_id: admin.id)
          user.suspend_for_fraud!(author_id: admin.id)

          expect do
            expect do
              described_class.handle_stripe_event(stripe_event)
            end.not_to have_enqueued_mail(ContactingCreatorMailer, :id_mismatch_on_stripe).with(user.id)
          end.not_to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed)
        end

        describe "future requirements" do
          let(:stripe_event) do
            {
              "api_version" => API_VERSION,
              "type" => "account.updated",
              "id" => "stripe-event-id-1",
              "account" => merchant_account.charge_processor_merchant_id,
              "user_id" => merchant_account.charge_processor_merchant_id,
              "data" => {
                "object" => {
                  "object" => "account",
                  "id" => merchant_account.charge_processor_merchant_id,
                  "business_type" => "individual",
                  "requirements" => {
                    "currently_due" => [],
                    "eventually_due" => [],
                    "past_due" => []
                  },
                  "future_requirements" => {
                    "currently_due" => ["individual.id_number"],
                    "eventually_due" => [],
                    "past_due" => []
                  }
                }
              }
            }
          end

          it "saves the verification error from future requirements if present" do
            stripe_error_code = "verification_failed_keyed_identity"
            stripe_error_reason = "The identity information you entered cannot be verified. Please correct any errors or upload a document that matches the identity fields (e.g., name and date of birth) that you entered."
            stripe_event["data"]["object"]["future_requirements"]["errors"] = [
              {
                "code" => stripe_error_code,
                "reason" => stripe_error_reason,
                "requirement" => "individual.id_number"
              }]

            described_class.handle_stripe_event(stripe_event)

            expect(user.user_compliance_info_requests.requested.count).to eq(1)
            user_compliance_info_request = user.user_compliance_info_requests.requested.first
            expect(user_compliance_info_request.field_needed).to eq(UserComplianceInfoFields::Individual::TAX_ID)
            expect(user_compliance_info_request.verification_error["code"]).to eq(stripe_error_code)
          end
        end
      end

      it "handles stripe event data containing stripe objects correctly and sends kyc email to user" do
        create(:merchant_account, user:, charge_processor_merchant_id: "stripe-account-id")
        requirements = Stripe::StripeObject.new("id")
        requirements["currently_due"] = ["individual.id_number"]
        requirements["eventually_due"] = []
        requirements["past_due"] = []
        legal_entity_verification = Stripe::StripeObject.new("id2")
        stripe_event = {
          "api_version" => API_VERSION,
          "type" => "account.updated",
          "id" => "stripe-event-id",
          "data" => {
            "object" => {
              "object" => "account",
              "id" => "stripe-account-id",
              "requirements" => requirements,
              "business_type" => "individual",
              "individual" => {
                "verification" => legal_entity_verification
              }
            }
          }
        }

        expect do
          described_class.handle_stripe_event(stripe_event)
        end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed).with(user.id, %w[individual_tax_id])

        expect(user.user_compliance_info_requests.requested.count).to eq(1)
        expect(user.user_compliance_info_requests.requested.first.field_needed).to eq(UserComplianceInfoFields::Individual::TAX_ID)
      end

      it "handles stripe event data containing about more kyc but does not notify user if suspended" do
        suspended_user = create(:user, user_risk_state: "suspended_for_fraud")
        create(:merchant_account, user: suspended_user, charge_processor_merchant_id: "stripe-account-id")
        requirements = Stripe::StripeObject.new("id")
        requirements["currently_due"] = []
        requirements["eventually_due"] = []
        requirements["past_due"] = ["individual.id_number"]
        legal_entity_verification = Stripe::StripeObject.new("id2")
        stripe_event = {
          "api_version" => API_VERSION,
          "type" => "account.updated",
          "id" => "stripe-event-id",
          "data" => {
            "object" => {
              "object" => "account",
              "id" => "stripe-account-id",
              "business_type" => "individual",
              "requirements" => requirements,
              "individual" => {
                "verification" => legal_entity_verification
              }
            }
          }
        }

        expect do
          described_class.handle_stripe_event(stripe_event)
        end.to_not have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed)

        expect(user.user_compliance_info_requests.requested.count).to eq(0)
      end

      it "handles stripe event data containing about more kyc but does not notify user if merchant account inactive" do
        create(:merchant_account, user:, charge_processor_merchant_id: "stripe-account-id", deleted_at: Time.current)
        requirements = Stripe::StripeObject.new("id")
        requirements["currently_due"] = ["individual.id_number"]
        requirements["eventually_due"] = []
        requirements["past_due"] = []
        legal_entity_verification = Stripe::StripeObject.new("id2")
        stripe_event = {
          "api_version" => API_VERSION,
          "type" => "account.updated",
          "id" => "stripe-event-id",
          "data" => {
            "object" => {
              "object" => "account",
              "id" => "stripe-account-id",
              "business_type" => "individual",
              "requirements" => requirements,
              "individual" => {
                "verification" => legal_entity_verification
              }
            }
          }
        }

        expect do
          described_class.handle_stripe_event(stripe_event)
        end.to_not have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed)

        expect(user.user_compliance_info_requests.requested.count).to eq(0)
      end

      describe "risk-related information updates" do
        let(:merchant_account) { create(:merchant_account, user:) }

        let(:stripe_event) do
          {
            "api_version" => API_VERSION,
            "type" => "account.updated",
            "id" => "stripe-event-id-1",
            "account" => merchant_account.charge_processor_merchant_id,
            "user_id" => merchant_account.charge_processor_merchant_id,
            "data" => {
              "object" => {
                "object" => "account",
                "id" => merchant_account.charge_processor_merchant_id,
                "business_type" => "individual",
                "requirements" => {
                  "currently_due" => ["interv_cmVxbXRfMVEyOTViUzhuV09PRjdyT0ZPamtGelgxv1000c65GRfs.intellectual_property_usage.form"],
                  "eventually_due" => [],
                  "past_due" => [],
                  "current_deadline" => 1712086848,
                },
                "future_requirements" => {
                  "currently_due" => [],
                  "eventually_due" => [],
                  "past_due" => []
                }
              }
            }
          }
        end

        it "adds user compliance info request if supportability fields are due and sends remediation email to the creator" do
          expect do
            expect do
              described_class.handle_stripe_event(stripe_event)
            end.to have_enqueued_mail(ContactingCreatorMailer, :stripe_remediation).with(user.id)
          end.to change(UserComplianceInfoRequest, :count).by(1)

          user_compliance_info_request = UserComplianceInfoRequest.last
          expect(user_compliance_info_request.user).to eq(user)
          expect(user_compliance_info_request.state).to eq("requested")
          expect(user_compliance_info_request.field_needed).to eq("interv_cmVxbXRfMVEyOTViUzhuV09PRjdyT0ZPamtGelgxv1000c65GRfs.intellectual_property_usage.form")
          expect(user_compliance_info_request.only_needs_field_to_be_partially_provided).to be false
          expect(user_compliance_info_request.due_at).to eq(Time.zone.at(1712086848))
          expect(user_compliance_info_request.stripe_event_id).to eq("stripe-event-id-1")
        end

        it "adds user compliance info request if compliance fields are due and sends remediation email to the creator" do
          stripe_event.deep_merge!("data" => {
                                     "object" => {
                                       "requirements" => {
                                         "currently_due" => ["interv_cmVxbXRfMVEyOTViUzhuV09PRjdyT0ZPamtGelgxv1000c65GRfs.identity_verification.challenge"],
                                       }
                                     }
                                   })

          expect do
            expect do
              described_class.handle_stripe_event(stripe_event)
            end.to have_enqueued_mail(ContactingCreatorMailer, :stripe_remediation).with(user.id)
          end.to change(UserComplianceInfoRequest, :count).by(1)

          user_compliance_info_request = UserComplianceInfoRequest.last
          expect(user_compliance_info_request.user).to eq(user)
          expect(user_compliance_info_request.state).to eq("requested")
          expect(user_compliance_info_request.field_needed).to eq("interv_cmVxbXRfMVEyOTViUzhuV09PRjdyT0ZPamtGelgxv1000c65GRfs.identity_verification.challenge")
          expect(user_compliance_info_request.only_needs_field_to_be_partially_provided).to be false
          expect(user_compliance_info_request.due_at).to eq(Time.zone.at(1712086848))
          expect(user_compliance_info_request.stripe_event_id).to eq("stripe-event-id-1")
        end

        it "adds user compliance info request if credit-related fields are due and sends remediation email to the creator" do
          stripe_event.deep_merge!("data" => {
                                     "object" => {
                                       "requirements" => {
                                         "currently_due" => ["interv_cmVxbXRfMVEyOTViUzhuV09PRjdyT0ZPamtGelgxv1000c65GRfs.credit_review.form"],
                                       }
                                     }
                                   })

          expect do
            expect do
              described_class.handle_stripe_event(stripe_event)
            end.to have_enqueued_mail(ContactingCreatorMailer, :stripe_remediation).with(user.id)
          end.to change(UserComplianceInfoRequest, :count).by(1)

          user_compliance_info_request = UserComplianceInfoRequest.last
          expect(user_compliance_info_request.user).to eq(user)
          expect(user_compliance_info_request.state).to eq("requested")
          expect(user_compliance_info_request.field_needed).to eq("interv_cmVxbXRfMVEyOTViUzhuV09PRjdyT0ZPamtGelgxv1000c65GRfs.credit_review.form")
          expect(user_compliance_info_request.only_needs_field_to_be_partially_provided).to be false
          expect(user_compliance_info_request.due_at).to eq(Time.zone.at(1712086848))
          expect(user_compliance_info_request.stripe_event_id).to eq("stripe-event-id-1")
        end

        it "suspends the account if stripe has rejected account due to compliance issue" do
          stripe_event.deep_merge!("data" => {
                                     "object" => {
                                       "requirements" => {
                                         "currently_due" => ["interv_cmVxbXRfMVEyOTViUzhuV09PRjdyT0ZPamtGelgxv1000c65GRfs.rejection_appeal.support"],
                                       }
                                     }
                                   })

          expect do
            described_class.handle_stripe_event(stripe_event)
          end.to have_enqueued_mail(ContactingCreatorMailer, :suspended_due_to_stripe_risk).with(user.id)

          expect(user.reload.suspended_for_tos_violation?).to be true
        end

        it "suspends the account and notifies the user via email if stripe has rejected account due to supportability issue" do
          stripe_event.deep_merge!("data" => {
                                     "object" => {
                                       "requirements" => {
                                         "currently_due" => ["interv_cmVxbXRfMVEyOTViUzhuV09PRjdyT0ZPamtGelgxv1000c65GRfs.supportability_rejection_appeal.support"],
                                       }
                                     }
                                   })

          expect do
            described_class.handle_stripe_event(stripe_event)
          end.to have_enqueued_mail(ContactingCreatorMailer, :suspended_due_to_stripe_risk).with(user.id)

          expect(user.reload.suspended_for_tos_violation?).to be true
        end
      end
    end

    describe "event: account.application.deauthorized" do
      describe "for an account not in our system" do
        let(:stripe_event) do
          {
            "api_version" => API_VERSION,
            "type" => "account.updated",
            "id" => "stripe-event-id",
            "data" => {
              "object" => {
                "object" => "account",
                "id" => "stripe-account-id"
              }
            }
          }
        end

        it "raise an error" do
          expect { described_class.handle_stripe_event(stripe_event) }.to raise_error("No Merchant Account for Stripe Account ID stripe-account-id")
        end
      end

      describe "Deauthorization from Stripe Account" do
        let(:merchant_account) { create(:merchant_account, user:) }

        let(:stripe_event) do
          {
            "api_version" => API_VERSION,
            "type" => "account.application.deauthorized",
            "id" => "stripe-event-id",
            "account" => merchant_account.charge_processor_merchant_id,
            "user_id" => merchant_account.charge_processor_merchant_id,
            "data" => {
              "object" => {
                "object" => "account",
                "id" => merchant_account.charge_processor_merchant_id,
                "business_type" => "individual",
              }
            }
          }
        end

        it "does not email users about the event" do
          expect do
            described_class.handle_stripe_event(stripe_event)
          end.to_not have_enqueued_mail(MerchantRegistrationMailer, :account_deauthorized_to_user)
        end

        context "merchant migration enabled" do
          before do
            Feature.activate_user(:merchant_migration, user)
          end

          after do
            Feature.deactivate_user(:merchant_migration, user)
          end

          it "emails users about the event" do
            expect do
              described_class.handle_stripe_event(stripe_event)
            end.to have_enqueued_mail(MerchantRegistrationMailer, :account_deauthorized_to_user).with(user.id, merchant_account.charge_processor_id)
          end
        end

        it "deactivates merchant account" do
          described_class.handle_stripe_event(stripe_event)
          merchant_account.reload
          expect(merchant_account.alive?).to be(false)
        end
      end
    end
  end

  describe "event: capability.updated" do
    let!(:merchant_account) do create(:merchant_account,
                                      user:,
                                      charge_processor_merchant_id: "acct_1QVBf52m2ugQR0I1",
                                      country: "JP") end
    let!(:user_compliance_info) { create(:user_compliance_info, user:, country: "Japan") }
    let(:verification_error_reason) { "The identity information you entered cannot be verified. Please correct any errors or upload a document that matches the identity fields (e.g., name and date of birth) that you entered." }

    let(:stripe_event) do
      {
        "id" => "evt_1QVBfg2m2ugQR0I1VshF1FC2",
        "object" => "event",
        "account" => "acct_1QVBf52m2ugQR0I1",
        "api_version" => "2023-10-16",
        "created" => 1734007152,
        "data" => {
          "object" => {
            "id" => "transfers",
            "object" => "capability",
            "account" => "acct_1QVBf52m2ugQR0I1",
            "future_requirements" => {
              "alternatives" => [],
              "current_deadline" => nil,
              "currently_due" => [],
              "disabled_reason" => nil,
              "errors" => [],
              "eventually_due" => [],
              "past_due" => [],
              "pending_verification" => []
            },
            "requested" => true,
            "requested_at" => 1734007117,
            "requirements" => {
              "alternatives" => [],
              "current_deadline" => nil,
              "currently_due" => ["individual.verification.document"],
              "disabled_reason" => nil,
              "errors" =>
                 [{ "code" => "verification_failed_keyed_identity",
                    "reason" => verification_error_reason,
                    "requirement" => "individual.verification.document" }],
              "eventually_due" => ["individual.verification.document"],
              "past_due" => ["individual.verification.document"],
              "pending_verification" => [] },
            "status" => "active"
          },
          "previous_attributes" => { "requirements" => { "errors" => [] } }
        },
        "livemode" => false,
        "pending_webhooks" => 1,
        "request" => { "id" => nil, "idempotency_key" => nil },
        "type" => "capability.updated"
      }
    end

    it "adds user compliance info request and sends kyc email to the creator" do
      expect do
        expect do
          described_class.handle_stripe_event(stripe_event)
        end.to have_enqueued_mail(ContactingCreatorMailer, :stripe_identity_verification_failed).with(user.id, verification_error_reason)
      end.to change(UserComplianceInfoRequest, :count).by(1)

      user_compliance_info_request = UserComplianceInfoRequest.last
      expect(user_compliance_info_request.user).to eq(user)
      expect(user_compliance_info_request.field_needed).to eq(UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID)
      expect(user_compliance_info_request.only_needs_field_to_be_partially_provided).to be false
      expect(user_compliance_info_request.stripe_event_id).to eq("evt_1QVBfg2m2ugQR0I1VshF1FC2")
    end

    context "when account is not found" do
      let(:stripe_event) do
        {
          "api_version" => API_VERSION,
          "type" => "capability.updated",
          "id" => "stripe-event-id",
          "data" => {
            "object" => {
              "object" => "capability",
              "id" => "transfers",
              "account" => "non-existent-account"
            }
          }
        }
      end

      it "does nothing and returns" do
        expect { described_class.handle_stripe_event(stripe_event) }.not_to change(UserComplianceInfoRequest, :count)
      end
    end
  end

  describe "payment method availability refresh on account/capability webhooks" do
    let(:seller) { create(:user) }
    let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }

    def capability_updated_event(account_id)
      {
        "api_version" => API_VERSION,
        "type" => "capability.updated",
        "id" => "stripe-event-id",
        "data" => {
          "object" => {
            "object" => "capability",
            "id" => "cashapp_payments",
            "account" => account_id,
            "status" => "active",
          }
        }
      }
    end

    def account_updated_event(account_id)
      {
        "api_version" => API_VERSION,
        "type" => "account.updated",
        "id" => "stripe-event-id",
        "account" => account_id,
        "user_id" => account_id,
        "data" => {
          "object" => {
            "object" => "account",
            "id" => account_id,
            "type" => "standard",
            "requirements" => { "currently_due" => [], "eventually_due" => [], "past_due" => [] }
          }
        }
      }
    end

    it "enqueues a refresh for a connect account on capability.updated — including non-JP accounts, which the JP-only guard below the call returns early for" do
      expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).to receive(:perform_async).with(connect_account.id)

      described_class.handle_stripe_event(capability_updated_event(connect_account.charge_processor_merchant_id))
    end

    it "enqueues a refresh for a connect account on account.updated — including standard accounts, which handle_stripe_info_requirements returns early for" do
      expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).to receive(:perform_async).with(connect_account.id)

      described_class.handle_stripe_event(account_updated_event(connect_account.charge_processor_merchant_id))
    end

    it "does not enqueue for an unknown account" do
      expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).not_to receive(:perform_async)

      described_class.handle_stripe_event(capability_updated_event("acct_nonexistent"))
    end

    it "does not enqueue for a non-connect (Gumroad-managed) account" do
      managed_account = create(:merchant_account)
      expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).not_to receive(:perform_async)

      described_class.handle_stripe_event(capability_updated_event(managed_account.charge_processor_merchant_id))
    end

    it "does not enqueue for a deauthorized (charge-processor-dead) connect account" do
      connect_account.update!(charge_processor_alive_at: nil)
      expect(RefreshMerchantAccountPaymentMethodAvailabilityWorker).not_to receive(:perform_async)

      described_class.handle_stripe_event(capability_updated_event(connect_account.charge_processor_merchant_id))
    end
  end

  describe "handling information update" do
    let(:user) { create(:user) }
    let(:user_compliance_info) { create(:user_compliance_info, user:) }
    let(:bank_account) { create(:ach_account_stripe_succeed, user:) }
    let(:tos_agreement) { create(:tos_agreement, user:) }

    before do
      user
      user_compliance_info
      bank_account
      tos_agreement
    end

    describe "handle_new_user_compliance_info" do
      describe "creator has a stripe account" do
        let(:merchant_account) { subject.create_account(user, passphrase: "1234") }

        before { merchant_account }

        it "calls update account for the user" do
          expect(subject).to receive(:update_account).with(user, passphrase: "1234", notify: true, force_address_resync: false)
          subject.handle_new_user_compliance_info(user_compliance_info)
        end
      end

      describe "creator does not have a stripe account" do
        it "calls update account for the user" do
          expect(subject).not_to receive(:update_account)
          subject.handle_new_user_compliance_info(user_compliance_info)
        end
      end
    end

    describe "handle_new_bank_account" do
      describe "creator has a stripe account" do
        let(:merchant_account) { subject.create_account(user, passphrase: "1234") }

        before { merchant_account }

        it "calls update account for the user" do
          expect(subject).to receive(:update_bank_account).with(user, passphrase: "1234")
          subject.handle_new_bank_account(user_compliance_info)
        end
      end

      describe "creator does not have a stripe account" do
        it "calls update account for the user" do
          expect(subject).not_to receive(:update_bank_account)
          subject.handle_new_bank_account(user_compliance_info)
        end
      end
    end
  end

  describe ".update_person" do
    let(:user) { create(:user, email: "rep@example.com") }
    let(:user_compliance_info) { create(:user_compliance_info_business, user:) }
    let(:stripe_account) { Stripe::Account.construct_from(id: "acct_multi_owner_123") }

    let(:representative_person) do
      Stripe::Person.construct_from(
        id: "person_representative",
        object: "person",
        account: stripe_account.id,
        relationship: { representative: true, owner: true, percent_ownership: 33.33 }
      )
    end
    let(:co_director_owner) do
      Stripe::Person.construct_from(
        id: "person_co_director",
        object: "person",
        account: stripe_account.id,
        relationship: { representative: false, owner: true, percent_ownership: 33.33 }
      )
    end
    let(:third_owner) do
      Stripe::Person.construct_from(
        id: "person_third_owner",
        object: "person",
        account: stripe_account.id,
        relationship: { representative: false, owner: true, percent_ownership: 33.34 }
      )
    end

    before { user_compliance_info }

    context "list_persons filters by relationship.representative on Stripe's side" do
      it "queries Stripe with relationship: { representative: true }, limit: 1 — no client-side scanning" do
        expect(Stripe::Account).to receive(:list_persons)
          .with(stripe_account.id, relationship: { representative: true }, limit: 1)
          .and_return("data" => [representative_person])
        expect(Stripe::Account).to receive(:update_person)
          .with(stripe_account.id, representative_person.id, anything)
          .and_return(true)

        described_class.update_person(user, stripe_account, nil, "1234")
      end
    end

    context "with the representative on the Stripe account" do
      it "sends only representative: true and lets Stripe preserve owner/title/percent_ownership set via BeneficialOwnersSection" do
        expect(Stripe::Account).to receive(:list_persons)
          .with(stripe_account.id, relationship: { representative: true }, limit: 1)
          .and_return("data" => [representative_person])

        captured_attributes = nil
        expect(Stripe::Account).to receive(:update_person) do |_account_id, _person_id, attributes|
          captured_attributes = attributes
          true
        end

        described_class.update_person(user, stripe_account, nil, "1234")

        expect(captured_attributes[:relationship]).to eq(representative: true)
      end
    end

    context "when Stripe returns no persons for the account" do
      it "returns early without calling update_person" do
        expect(Stripe::Account).to receive(:list_persons)
          .with(stripe_account.id, relationship: { representative: true }, limit: 1)
          .and_return("data" => [])
        expect(Stripe::Account).not_to receive(:update_person)

        described_class.update_person(user, stripe_account, nil, "1234")
      end
    end

    context "individual→company transition" do
      def stub_owner_list(persons)
        allow(Stripe::Account).to receive(:list_persons)
          .with(stripe_account.id, relationship: { owner: true }, limit: 100)
          .and_return("data" => persons)
      end

      def capture_person_update(last_individual_info)
        captured_attributes = nil
        expect(Stripe::Account).to receive(:update_person) do |_account_id, _person_id, attributes|
          captured_attributes = attributes
          true
        end

        described_class.update_person(user, stripe_account, last_individual_info.external_id, "1234")
        captured_attributes
      end

      let(:last_individual_info) do
        info = create(:user_compliance_info, user:)
        info.mark_deleted!
        create(:user_compliance_info_business, user:)
        info
      end

      before do
        allow(Stripe::Account).to receive(:list_persons)
          .with(stripe_account.id, relationship: { representative: true }, limit: 1)
          .and_return("data" => [representative_person])
      end

      it "seeds owner: true, title, percent_ownership: 100 when nobody else owns any of the company" do
        stub_owner_list([representative_person])

        captured_attributes = capture_person_update(last_individual_info)

        expect(captured_attributes[:relationship]).to include(
          representative: true,
          owner: true,
          percent_ownership: 100,
        )
        expect(captured_attributes[:relationship][:title]).to be_present
      end

      it "claims only the ownership the existing beneficial owners have not, so Stripe does not reject the switch for exceeding 100 percent" do
        stub_owner_list([co_director_owner, third_owner])

        captured_attributes = capture_person_update(last_individual_info)

        expect(captured_attributes[:relationship]).to include(
          representative: true,
          owner: true,
          percent_ownership: 33.33,
        )
      end

      it "rounds the claimed share DOWN so a fractional remainder cannot push the company over 100 percent" do
        almost_everything_owner = Stripe::Person.construct_from(
          id: "person_almost_everything",
          object: "person",
          account: stripe_account.id,
          relationship: { representative: false, owner: true, percent_ownership: 99.995 }
        )
        stub_owner_list([almost_everything_owner])

        captured_attributes = capture_person_update(last_individual_info)

        # Rounding to the nearest hundredth would ask for 0.01 here, totalling 100.005 and drawing
        # the very rejection this guard exists to prevent. Rounding down leaves nothing to claim.
        expect(captured_attributes[:relationship]).not_to have_key(:percent_ownership)
        expect(captured_attributes[:relationship]).not_to have_key(:owner)
      end

      it "treats an owner with no recorded share as owning nothing" do
        share_less_owner = Stripe::Person.construct_from(
          id: "person_share_less",
          object: "person",
          account: stripe_account.id,
          relationship: { representative: false, owner: true, percent_ownership: nil }
        )
        stub_owner_list([share_less_owner])

        captured_attributes = capture_person_update(last_individual_info)

        expect(captured_attributes[:relationship][:percent_ownership]).to eq(100)
      end

      it "claims nothing when the recorded owners already add up to more than the whole company" do
        over_claimed = [
          Stripe::Person.construct_from(id: "person_a", object: "person", account: stripe_account.id,
                                        relationship: { representative: false, owner: true, percent_ownership: 80 }),
          Stripe::Person.construct_from(id: "person_b", object: "person", account: stripe_account.id,
                                        relationship: { representative: false, owner: true, percent_ownership: 40 }),
        ]
        stub_owner_list(over_claimed)

        captured_attributes = capture_person_update(last_individual_info)

        expect(captured_attributes[:relationship]).not_to have_key(:owner)
        expect(captured_attributes[:relationship]).not_to have_key(:percent_ownership)
      end

      it "uses the ownership figure the caller already read instead of asking Stripe again" do
        expect(Stripe::Account).not_to receive(:list_persons)
          .with(stripe_account.id, relationship: { owner: true }, limit: 100)

        captured_attributes = nil
        expect(Stripe::Account).to receive(:update_person) do |_account_id, _person_id, attributes|
          captured_attributes = attributes
          true
        end

        described_class.update_person(user, stripe_account, last_individual_info.external_id, "1234", unclaimed_percent_ownership: 25.0)

        expect(captured_attributes[:relationship][:percent_ownership]).to eq(25.0)
      end

      it "claims no ownership at all when the existing beneficial owners already account for the whole company" do
        full_owner = Stripe::Person.construct_from(
          id: "person_full_owner",
          object: "person",
          account: stripe_account.id,
          relationship: { representative: false, owner: true, percent_ownership: 100 }
        )
        stub_owner_list([full_owner])

        captured_attributes = capture_person_update(last_individual_info)

        expect(captured_attributes[:relationship]).to include(representative: true)
        expect(captured_attributes[:relationship]).not_to have_key(:owner)
        expect(captured_attributes[:relationship]).not_to have_key(:percent_ownership)
        expect(captured_attributes[:relationship][:title]).to be_present
      end

      it "ignores the representative's own existing ownership share when working out what is unclaimed" do
        stub_owner_list([representative_person, co_director_owner])

        captured_attributes = capture_person_update(last_individual_info)

        expect(captured_attributes[:relationship][:percent_ownership]).to eq(66.67)
      end

      context "when a beneficial owner changes between the caller's ownership read and the person update" do
        # The caller reads the unclaimed share BEFORE Stripe::Account.update, so a beneficial owner
        # added or enlarged in that window makes the number stale and too large. Stripe then rejects
        # the person update for exceeding 100% — the exact seller-visible breakage this code prevents
        # — after the account update has already committed, so it must recover in place.
        let(:exceeded_error) do
          Stripe::InvalidRequestError.new(
            "The total combined ownership of the company would exceed 100 percent.",
            "relationship[percent_ownership]"
          )
        end

        it "re-reads the live ownership and retries with the smaller share" do
          # A new owner took 60% after the caller read 100% as unclaimed.
          stub_owner_list([
                            Stripe::Person.construct_from(id: "person_new", object: "person", account: stripe_account.id,
                                                          relationship: { representative: false, owner: true, percent_ownership: 60 })
                          ])

          attempts = []
          call_count = 0
          allow(Stripe::Account).to receive(:update_person) do |_account_id, _person_id, attributes|
            call_count += 1
            attempts << attributes[:relationship].dup
            raise exceeded_error if call_count == 1
            true
          end

          described_class.update_person(user, stripe_account, last_individual_info.external_id, "1234", unclaimed_percent_ownership: 100)

          expect(attempts.length).to eq(2)
          expect(attempts.first[:percent_ownership]).to eq(100)
          expect(attempts.last[:percent_ownership]).to eq(40)
          expect(attempts.last[:owner]).to be(true)
        end

        it "drops the ownership claim entirely when the new owners now account for the whole company" do
          stub_owner_list([
                            Stripe::Person.construct_from(id: "person_new", object: "person", account: stripe_account.id,
                                                          relationship: { representative: false, owner: true, percent_ownership: 100 })
                          ])

          attempts = []
          call_count = 0
          allow(Stripe::Account).to receive(:update_person) do |_account_id, _person_id, attributes|
            call_count += 1
            attempts << attributes[:relationship].dup
            raise exceeded_error if call_count == 1
            true
          end

          described_class.update_person(user, stripe_account, last_individual_info.external_id, "1234", unclaimed_percent_ownership: 100)

          expect(attempts.length).to eq(2)
          expect(attempts.last).not_to have_key(:percent_ownership)
          expect(attempts.last).not_to have_key(:owner)
          expect(attempts.last[:representative]).to be(true)
        end

        it "does not retry when the live ownership is unchanged, so a genuine rejection still surfaces" do
          # Nothing moved: retrying would send the identical payload and fail identically.
          stub_owner_list([representative_person])

          call_count = 0
          allow(Stripe::Account).to receive(:update_person) do |_account_id, _person_id, _attributes|
            call_count += 1
            raise exceeded_error
          end

          expect do
            described_class.update_person(user, stripe_account, last_individual_info.external_id, "1234", unclaimed_percent_ownership: 100)
          end.to raise_error(Stripe::InvalidRequestError, /exceed 100/)

          expect(call_count).to eq(1)
        end

        it "does not swallow unrelated Stripe rejections" do
          stub_owner_list([representative_person])
          other_error = Stripe::InvalidRequestError.new("Invalid postal code", "person[address][postal_code]")

          call_count = 0
          allow(Stripe::Account).to receive(:update_person) do |_account_id, _person_id, _attributes|
            call_count += 1
            raise other_error
          end

          expect do
            described_class.update_person(user, stripe_account, last_individual_info.external_id, "1234", unclaimed_percent_ownership: 100)
          end.to raise_error(Stripe::InvalidRequestError, /postal code/)

          expect(call_count).to eq(1)
        end
      end
    end

    context "when an earlier switch left the account a company that nobody owns" do
      # The individual→business switch writes the compliance-info marker into Stripe's account
      # metadata before seeding the representative, so a failure in between leaves an account whose
      # business_type is already "company" while no person holds any ownership. Our marker then says
      # "already a business" forever, and without a live ownership check nothing ever seeds the
      # representative again.
      let(:unowned_representative) do
        Stripe::Person.construct_from(
          id: "person_representative",
          object: "person",
          account: stripe_account.id,
          relationship: { representative: true, owner: false }
        )
      end

      before do
        allow(Stripe::Account).to receive(:list_persons)
          .with(stripe_account.id, relationship: { representative: true }, limit: 1)
          .and_return("data" => [unowned_representative])
        allow(Stripe::Account).to receive(:list_persons)
          .with(stripe_account.id, relationship: { owner: true }, limit: 100)
          .and_return("data" => [])
      end

      it "seeds the representative's ownership when the caller says to, even with no prior individual compliance record" do
        captured_attributes = nil
        expect(Stripe::Account).to receive(:update_person) do |_account_id, _person_id, attributes|
          captured_attributes = attributes
          true
        end

        described_class.update_person(user, stripe_account, nil, "1234", seed_representative_ownership: true)

        expect(captured_attributes[:relationship]).to include(representative: true, owner: true, percent_ownership: 100)
      end

      it "leaves ownership alone when the caller says not to seed it" do
        captured_attributes = nil
        expect(Stripe::Account).to receive(:update_person) do |_account_id, _person_id, attributes|
          captured_attributes = attributes
          true
        end

        described_class.update_person(user, stripe_account, nil, "1234", seed_representative_ownership: false)

        expect(captured_attributes[:relationship]).to eq(representative: true)
      end
    end

    # gumroad-private#1575. The representative's identifier is split onto its own call for the same
    # reason as the seller's, and the rejection note is the retry marker, so it is recorded no
    # matter which caller triggered the rejection.
    context "when the account country disagrees with the legal-entity country" do
      let(:user_compliance_info) do
        create(:user_compliance_info_business, user:, country: "Korea, Republic of",
                                               business_country: "Korea, Republic of", individual_tax_id: "1234567890")
      end
      let(:stripe_account) { Stripe::Account.construct_from(id: "acct_mismatch_person", country: "US") }
      let(:rejection) { Stripe::InvalidRequestError.new("Invalid ID number", "id_number") }

      before do
        allow(Stripe::Account).to receive(:list_persons)
          .with(stripe_account.id, relationship: { representative: true }, limit: 1)
          .and_return("data" => [representative_person])
        allow(Stripe::Account).to receive(:update_person) do |_account_id, _person_id, attributes|
          raise rejection if attributes.key?(:id_number) || attributes.key?(:ssn_last_4)

          true
        end
      end

      def representative_rejection_notes
        user.comments.with_type_payout_note.alive
            .where("content LIKE ?", "#{StripeMerchantAccountManager::IDENTITY_REJECTION_NOTE_PREFIX} (representative)%")
      end

      it "records the rejection as a payout note" do
        described_class.update_person(user, stripe_account, nil, "1234")

        expect(representative_rejection_notes.count).to eq(1)
      end

      # Same guard as the account path: the note is the only retry state, so a verdict must not be
      # swallowed when the write that was supposed to persist it failed.
      it "re-raises the rejection when the retry marker cannot be recorded" do
        allow(user).to receive(:add_payout_note).and_raise(ActiveRecord::RecordInvalid.new(Comment.new))

        expect do
          described_class.update_person(user, stripe_account, nil, "1234")
        end.to raise_error(rejection)
      end
    end
  end

  describe "healing an account left mid individual-to-business migration" do
    let(:user) { create(:user) }
    let(:tos_agreement) { create(:tos_agreement, user:) }
    let(:individual_info) { create(:user_compliance_info, user:) }
    let(:business_info) { create(:user_compliance_info_business, user:) }
    let!(:merchant_account) { create(:merchant_account, user:, charge_processor_merchant_id: "acct_stuck_migration") }

    let(:representative) do
      Stripe::Person.construct_from(
        id: "person_representative",
        object: "person",
        account: "acct_stuck_migration",
        relationship: { representative: true, owner: false }
      )
    end

    # The marker already points at the CURRENT business record, which is what makes the account
    # invisible to the switch branch: as far as update_account is concerned it has always been a
    # business, so nothing re-seeds the representative.
    def stuck_account(owners_provided_in:)
      requirements = { currently_due: [], past_due: [], eventually_due: [] }
      requirements[owners_provided_in] = ["company.owners_provided"]
      Stripe::Account.construct_from(
        id: "acct_stuck_migration",
        object: "account",
        business_type: "company",
        company: { owners_provided: false },
        capabilities: {},
        metadata: { "user_compliance_info_id" => business_info.external_id },
        requirements:
      )
    end

    before do
      tos_agreement
      individual_info.mark_deleted!
      business_info
      allow(Stripe::Account).to receive(:list_persons)
        .with("acct_stuck_migration", relationship: { representative: true }, limit: 1)
        .and_return("data" => [representative])
      allow(Stripe::Account).to receive(:list_persons)
        .with("acct_stuck_migration", relationship: { owner: true }, limit: 100)
        .and_return("data" => [])
      allow(Stripe::Account).to receive(:list_persons)
        .with("acct_stuck_migration", limit: 100)
        .and_return("data" => [representative])
      allow(Stripe::Account).to receive(:update_person).and_return(true)
    end

    it "seeds the representative and attests the owner list on a save the seller makes themselves" do
      account = stuck_account(owners_provided_in: :past_due)
      allow(Stripe::Account).to receive(:retrieve).with("acct_stuck_migration").and_return(account)

      seeded = nil
      attested = false
      allow(Stripe::Account).to receive(:update) do |_id, params|
        attested = true if params.dig(:company, :owners_provided)
        account
      end
      # Stripe really does hold the seeded owner from this point on, and the attestation re-reads the
      # list before stating it is complete — a stub frozen at empty would make that read a no-op and
      # hide whether the attestation ever fires.
      allow(Stripe::Account).to receive(:update_person) do |_id, _person_id, attributes|
        seeded = attributes[:relationship]
        allow(Stripe::Account).to receive(:list_persons)
          .with("acct_stuck_migration", relationship: { owner: true }, limit: 100)
          .and_return("data" => [
                        Stripe::Person.construct_from(
                          id: "person_representative",
                          object: "person",
                          account: "acct_stuck_migration",
                          relationship: attributes[:relationship]
                        )
                      ])
        true
      end

      described_class.update_account(user, passphrase: "1234")

      expect(seeded).to include(owner: true, percent_ownership: 100)
      expect(attested).to be(true)
    end

    # eventually_due requirements only bind at a future volume threshold, so the account is not
    # blocked and there is nothing to repair. Acting on it would mean re-seeding ownership and
    # attesting owner lists across business accounts that are working fine.
    it "leaves an account alone when the requirement is only eventually due" do
      account = stuck_account(owners_provided_in: :eventually_due)
      allow(Stripe::Account).to receive(:retrieve).with("acct_stuck_migration").and_return(account)

      seeded = nil
      attested = false
      allow(Stripe::Account).to receive(:update) do |_id, params|
        attested = true if params.dig(:company, :owners_provided)
        account
      end
      allow(Stripe::Account).to receive(:update_person) do |_id, _person_id, attributes|
        seeded = attributes[:relationship]
        true
      end

      described_class.update_account(user, passphrase: "1234")

      expect(seeded).to eq(representative: true)
      expect(attested).to be(false)
    end

    # Without an earlier individual record this is an account created as a business whose seller
    # never filled the beneficial-owners form. Seeding a 100% owner there would invent an ownership
    # claim the seller never made, and then attest it to Stripe as complete.
    it "leaves an account created as a business alone even when nobody owns it" do
      individual_info.destroy!
      account = stuck_account(owners_provided_in: :past_due)
      allow(Stripe::Account).to receive(:retrieve).with("acct_stuck_migration").and_return(account)

      seeded = nil
      attested = false
      allow(Stripe::Account).to receive(:update) do |_id, params|
        attested = true if params.dig(:company, :owners_provided)
        account
      end
      allow(Stripe::Account).to receive(:update_person) do |_id, _person_id, attributes|
        seeded = attributes[:relationship]
        true
      end

      described_class.update_account(user, passphrase: "1234")

      expect(seeded).to eq(representative: true)
      expect(attested).to be(false)
    end

    # A seller who switched successfully and then unchecked Owner on their own representative. The
    # form submits percent_ownership 0 for that, so the total is zero exactly as it is on a switch
    # that never seeded — the difference is that Stripe holds the share AS zero rather than not
    # holding one at all. Seeding 100% here would overwrite a share the seller set on purpose, and
    # then attest it.
    it "leaves a representative whose ownership the seller set to zero alone" do
      representative_at_zero = Stripe::Person.construct_from(
        id: "person_representative",
        object: "person",
        account: "acct_stuck_migration",
        relationship: { representative: true, owner: false, percent_ownership: 0 }
      )
      allow(Stripe::Account).to receive(:list_persons)
        .with("acct_stuck_migration", limit: 100)
        .and_return("data" => [representative_at_zero])
      allow(Stripe::Account).to receive(:list_persons)
        .with("acct_stuck_migration", relationship: { owner: true }, limit: 100)
        .and_return("data" => [representative_at_zero])
      account = stuck_account(owners_provided_in: :past_due)
      allow(Stripe::Account).to receive(:retrieve).with("acct_stuck_migration").and_return(account)

      seeded = nil
      attested = false
      allow(Stripe::Account).to receive(:update) do |_id, params|
        attested = true if params.dig(:company, :owners_provided)
        account
      end
      allow(Stripe::Account).to receive(:update_person) do |_id, _person_id, attributes|
        seeded = attributes[:relationship]
        true
      end

      described_class.update_account(user, passphrase: "1234")

      expect(seeded).to eq(representative: true)
      expect(attested).to be(false)
    end

    # The other 9 of the 25 stuck accounts: the representative already holds 100%, and the account is
    # blocked purely because nothing ever attested the list. Seeding here would be wrong; attesting
    # is the entire fix, so it must not be gated behind the seeding decision.
    it "attests without seeding when the representative already owns the company" do
      allow(Stripe::Account).to receive(:list_persons)
        .with("acct_stuck_migration", relationship: { owner: true }, limit: 100)
        .and_return("data" => [
                      Stripe::Person.construct_from(
                        id: "person_representative",
                        object: "person",
                        account: "acct_stuck_migration",
                        relationship: { representative: true, owner: true, percent_ownership: 100 }
                      )
                    ])
      account = stuck_account(owners_provided_in: :currently_due)
      allow(Stripe::Account).to receive(:retrieve).with("acct_stuck_migration").and_return(account)

      seeded = nil
      attested = false
      allow(Stripe::Account).to receive(:update) do |_id, params|
        attested = true if params.dig(:company, :owners_provided)
        account
      end
      allow(Stripe::Account).to receive(:update_person) do |_id, _person_id, attributes|
        seeded = attributes[:relationship]
        true
      end

      described_class.update_account(user, passphrase: "1234")

      expect(seeded).to eq(representative: true)
      expect(attested).to be(true)
    end

    # A failed persons read is not evidence that nobody owns anything. Guessing either way here
    # would mean inventing an ownership claim or attesting a list we never saw.
    it "does nothing when the ownership read fails" do
      allow(Stripe::Account).to receive(:list_persons)
        .with("acct_stuck_migration", relationship: { owner: true }, limit: 100)
        .and_raise(Stripe::APIError.new("Stripe is down"))
      allow(ErrorNotifier).to receive(:notify)
      account = stuck_account(owners_provided_in: :past_due)
      allow(Stripe::Account).to receive(:retrieve).with("acct_stuck_migration").and_return(account)

      seeded = nil
      attested = false
      allow(Stripe::Account).to receive(:update) do |_id, params|
        attested = true if params.dig(:company, :owners_provided)
        account
      end
      allow(Stripe::Account).to receive(:update_person) do |_id, _person_id, attributes|
        seeded = attributes[:relationship]
        true
      end

      described_class.update_account(user, passphrase: "1234")

      expect(seeded).to eq(representative: true)
      expect(attested).to be(false)
    end

    # The false-attestation case: a company whose representative holds 25% has 75% belonging to
    # beneficial owners nobody has entered. Telling Stripe that list is complete is a false statement
    # that can clear the payout restriction while three quarters of the company is unaccounted for.
    it "does not attest a list that accounts for only part of the company" do
      allow(Stripe::Account).to receive(:list_persons)
        .with("acct_stuck_migration", relationship: { owner: true }, limit: 100)
        .and_return("data" => [
                      Stripe::Person.construct_from(
                        id: "person_representative",
                        object: "person",
                        account: "acct_stuck_migration",
                        relationship: { representative: true, owner: true, percent_ownership: 25 }
                      )
                    ])
      account = stuck_account(owners_provided_in: :currently_due)
      allow(Stripe::Account).to receive(:retrieve).with("acct_stuck_migration").and_return(account)

      seeded = nil
      attested = false
      allow(Stripe::Account).to receive(:update) do |_id, params|
        attested = true if params.dig(:company, :owners_provided)
        account
      end
      allow(Stripe::Account).to receive(:update_person) do |_id, _person_id, attributes|
        seeded = attributes[:relationship]
        true
      end

      described_class.update_account(user, passphrase: "1234")

      expect(seeded).to eq(representative: true)
      expect(attested).to be(false)
    end

    # Shares Stripe and our own form accept with more than two decimals do not sum to exactly 100, so
    # a list that really does cover the company must still read as complete.
    it "attests a list whose shares cover the company after rounding" do
      thirds = [33.33, 33.33, 33.33].each_with_index.map do |percent, index|
        Stripe::Person.construct_from(
          id: "person_owner_#{index}",
          object: "person",
          account: "acct_stuck_migration",
          relationship: { representative: false, owner: true, percent_ownership: percent }
        )
      end
      allow(Stripe::Account).to receive(:list_persons)
        .with("acct_stuck_migration", relationship: { owner: true }, limit: 100)
        .and_return("data" => thirds)
      account = stuck_account(owners_provided_in: :currently_due)
      allow(Stripe::Account).to receive(:retrieve).with("acct_stuck_migration").and_return(account)

      attested = false
      allow(Stripe::Account).to receive(:update) do |_id, params|
        attested = true if params.dig(:company, :owners_provided)
        account
      end

      described_class.update_account(user, passphrase: "1234")

      expect(attested).to be(true)
    end

    # A seller who switched long ago, has saved payout settings since, and later cleared their
    # representative's ownership has a legitimate company state. The record immediately before the
    # live one is a business, so the soft-deleted individual record further back must not read as an
    # interrupted switch and re-seed a 100% claim.
    it "leaves a settled company alone when the individual record is not the one before the live record" do
      business_info.mark_deleted!
      later_business_info = create(:user_compliance_info_business, user:)
      account = stuck_account(owners_provided_in: :past_due)
      allow(account.metadata).to receive(:[]).with("user_compliance_info_id").and_return(later_business_info.external_id)
      allow(Stripe::Account).to receive(:retrieve).with("acct_stuck_migration").and_return(account)

      seeded = nil
      attested = false
      allow(Stripe::Account).to receive(:update) do |_id, params|
        attested = true if params.dig(:company, :owners_provided)
        account
      end
      allow(Stripe::Account).to receive(:update_person) do |_id, _person_id, attributes|
        seeded = attributes[:relationship]
        true
      end

      described_class.update_account(user, passphrase: "1234")

      expect(seeded).to eq(representative: true)
      expect(attested).to be(false)
    end

    # A zero-ownership list on an account the seller has entered people into is a shape they
    # configured — the beneficial-owners form can clear the representative's own share — so seeding
    # 100% there would overwrite a claim they deliberately gave up.
    it "leaves ownership alone when the seller has entered someone besides the representative" do
      director = Stripe::Person.construct_from(
        id: "person_director",
        object: "person",
        account: "acct_stuck_migration",
        relationship: { representative: false, owner: false, director: true }
      )
      allow(Stripe::Account).to receive(:list_persons)
        .with("acct_stuck_migration", limit: 100)
        .and_return("data" => [representative, director])
      account = stuck_account(owners_provided_in: :past_due)
      allow(Stripe::Account).to receive(:retrieve).with("acct_stuck_migration").and_return(account)

      seeded = nil
      attested = false
      allow(Stripe::Account).to receive(:update) do |_id, params|
        attested = true if params.dig(:company, :owners_provided)
        account
      end
      allow(Stripe::Account).to receive(:update_person) do |_id, _person_id, attributes|
        seeded = attributes[:relationship]
        true
      end

      described_class.update_account(user, passphrase: "1234")

      expect(seeded).to eq(representative: true)
      expect(attested).to be(false)
    end
  end

  # The whole heal turns on Stripe distinguishing "no share was ever recorded" from "the share is
  # zero". Every other example here constructs the person locally, which cannot prove that: if Stripe
  # normalised an explicit zero to null, a seller who deliberately unchecked Owner would read as a
  # never-seeded representative and get 100% written over their own choice. These examples pin the
  # round trip against Stripe itself, recorded, so the distinction is a fact about the API rather than
  # an assumption in a stub.
  describe "how Stripe stores a representative's percent_ownership" do
    let(:account_id) do
      Stripe::Account.create(
        type: "custom",
        country: "US",
        business_type: "company",
        capabilities: { transfers: { requested: true }, card_payments: { requested: true } }
      ).id
    end

    def representative_on(account_id)
      Stripe::Account.create_person(
        account_id,
        first_name: "Rep",
        last_name: "Resentative",
        relationship: { representative: true, title: "CEO" }
      )
    end

    it "leaves percent_ownership absent on a representative created without one" do
      person = representative_on(account_id)

      expect(Stripe::Account.retrieve_person(account_id, person.id).relationship.percent_ownership).to be_nil
    end

    it "keeps an explicit zero as zero rather than normalising it to null" do
      person = representative_on(account_id)

      # What the beneficial-owners form sends when the seller unchecks Owner on their representative.
      Stripe::Account.update_person(account_id, person.id, relationship: { owner: false, percent_ownership: 0 })

      expect(Stripe::Account.retrieve_person(account_id, person.id).relationship.percent_ownership).to eq(0)
    end

    it "keeps a seeded share when owner is later unset" do
      person = representative_on(account_id)
      Stripe::Account.update_person(account_id, person.id, relationship: { owner: true, percent_ownership: 100 })

      Stripe::Account.update_person(account_id, person.id, relationship: { owner: false })

      relationship = Stripe::Account.retrieve_person(account_id, person.id).relationship
      expect(relationship.owner).to be(false)
      expect(relationship.percent_ownership).to eq(100)
    end
  end

  describe "company.owners_provided attestation" do
    let(:account_id) { "acct_owners_provided_123" }

    def stripe_account_object(owners_provided:, outstanding:)
      Stripe::Account.construct_from(
        id: account_id,
        object: "account",
        business_type: "company",
        company: { owners_provided: },
        requirements: { currently_due: outstanding, past_due: [], eventually_due: [] }
      )
    end

    def owner_list(persons)
      allow(Stripe::Account).to receive(:list_persons)
        .with(account_id, relationship: { owner: true }, limit: 100)
        .and_return("data" => persons)
    end

    def owning_representative
      Stripe::Person.construct_from(
        id: "person_representative",
        object: "person",
        account: account_id,
        relationship: { representative: true, owner: true, percent_ownership: 100 }
      )
    end

    it "tells Stripe the owner list is complete once someone actually holds ownership" do
      owner_list([owning_representative])
      expect(Stripe::Account).to receive(:update).with(account_id, { company: { owners_provided: true } })

      described_class.send(:attest_owners_provided, account_id)
    end

    it "reports no recorded ownership distinctly from a Stripe read that failed" do
      owner_list([])
      expect(described_class.send(:recorded_ownership_percent_on, account_id)).to eq(0)

      allow(Stripe::Account).to receive(:list_persons).and_raise(Stripe::APIError.new("Stripe is down"))
      allow(ErrorNotifier).to receive(:notify)

      expect(described_class.send(:recorded_ownership_percent_on, account_id)).to be_nil
    end

    # The caller decides to attest from its intent to seed, and update_person returns without seeding
    # when the account has no representative person. Attesting then would tell Stripe an empty list
    # is complete.
    it "does not attest an owner list nobody is on" do
      owner_list([])

      expect(Stripe::Account).not_to receive(:update)

      described_class.send(:attest_owners_provided, account_id)
    end

    # The tolerance absorbs decimal rounding, nothing more: a total short by a whole percentage point
    # is a list missing a share, not a list that rounded.
    it "does not attest a total that falls short by more than the rounding allowance" do
      owner_list([
                   Stripe::Person.construct_from(
                     id: "person_representative",
                     object: "person",
                     account: account_id,
                     relationship: { representative: true, owner: true, percent_ownership: 99 }
                   )
                 ])

      expect(Stripe::Account).not_to receive(:update)

      described_class.send(:attest_owners_provided, account_id)
    end

    it "does not attest when the ownership read fails" do
      allow(Stripe::Account).to receive(:list_persons).and_raise(Stripe::APIError.new("Stripe is down"))
      allow(ErrorNotifier).to receive(:notify)

      expect(Stripe::Account).not_to receive(:update)

      described_class.send(:attest_owners_provided, account_id)
    end

    it "reads an account Stripe has already accepted the attestation for as not blocking" do
      account = stripe_account_object(owners_provided: true, outstanding: [])

      expect(described_class.send(:owners_provided_blocking_payouts?, account)).to be(false)
    end

    it "reads an account Stripe is still holding on the attestation as blocking" do
      account = stripe_account_object(owners_provided: false, outstanding: ["company.owners_provided"])

      expect(described_class.send(:owners_provided_blocking_payouts?, account)).to be(true)
    end

    it "does not treat an unrelated outstanding requirement as this one" do
      account = stripe_account_object(owners_provided: false, outstanding: ["company.tax_id"])

      expect(described_class.send(:owners_provided_blocking_payouts?, account)).to be(false)
    end

    # The seller's own compliance details are already saved on Stripe by the time this runs, so a
    # failure here must not turn a successful save into an error on the payments settings page.
    it "reports a Stripe failure without raising, so the seller's save still succeeds" do
      owner_list([owning_representative])
      allow(Stripe::Account).to receive(:update).and_raise(Stripe::APIError.new("Stripe is down"))

      expect(ErrorNotifier).to receive(:notify).with(instance_of(Stripe::APIError))

      expect { described_class.send(:attest_owners_provided, account_id) }.not_to raise_error
    end
  end

  describe "soft-future requirement skip" do
    let(:user) { create(:user) }
    let(:merchant_account) { create(:merchant_account, user:) }

    before { create(:user_compliance_info, user:, country: Compliance::Countries::USA.common_name) }

    def stripe_event(eventually_due:, currently_due: [], past_due: [], deadline: 90.days.from_now.to_i)
      {
        "api_version" => API_VERSION,
        "type" => "account.updated",
        "id" => "stripe-event-id-soft",
        "account" => merchant_account.charge_processor_merchant_id,
        "user_id" => merchant_account.charge_processor_merchant_id,
        "data" => {
          "object" => {
            "object" => "account",
            "id" => merchant_account.charge_processor_merchant_id,
            "business_type" => "individual",
            "charges_enabled" => true,
            "payouts_enabled" => true,
            "requirements" => {
              "current_deadline" => deadline,
              "currently_due" => currently_due,
              "eventually_due" => eventually_due,
              "past_due" => past_due
            }
          }
        }
      }
    end

    it "records the request but does not email when the only new field is in eventually_due with a far-future deadline" do
      expect do
        described_class.handle_stripe_event(stripe_event(eventually_due: ["individual.id_number"]))
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed)
      expect(user.user_compliance_info_requests.requested.count).to eq(1)
    end

    it "emails as usual when the new field is currently_due even if other fields are eventually_due" do
      expect do
        described_class.handle_stripe_event(stripe_event(
                                              currently_due: ["individual.id_number"],
                                              eventually_due: ["company.tax_id"]
                                            ))
      end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed)
    end

    it "emails as usual when the eventually_due field has a near-term deadline" do
      expect do
        described_class.handle_stripe_event(stripe_event(
                                              eventually_due: ["individual.id_number"],
                                              deadline: 7.days.from_now.to_i
                                            ))
      end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed)
    end

    it "still emails when an outstanding currently_due field remains alongside a new soft eventually_due field" do
      create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Business::TAX_ID)

      expect do
        described_class.handle_stripe_event(stripe_event(
                                              currently_due: ["business.tax_id"],
                                              eventually_due: ["individual.id_number"]
                                            ))
      end.to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed)
    end

    it "does not re-notify on the monthly path when every outstanding requested field is soft" do
      create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::TAX_ID, created_at: 2.months.ago)

      expect do
        described_class.handle_stripe_event(stripe_event(eventually_due: ["individual.id_number"]))
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :more_kyc_needed)
    end
  end
end
