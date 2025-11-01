# frozen_string_literal: true

require "spec_helper"

describe Admin::MerchantAccountPresenter do
  describe "#props" do
    let(:merchant_account) { create(:merchant_account, *merchant_account_traits) }
    let(:merchant_account_traits) { [] }
    let(:presenter) { described_class.new(merchant_account:) }

    subject(:props) { presenter.props }

    describe "database attributes" do
      before do
        allow(Stripe::Account).to receive(:retrieve).and_return(double(:account, charges_enabled: false, payouts_enabled: false, requirements: double(:requirements, disabled_reason: "rejected.fraud", as_json: {})))
        allow_any_instance_of(MerchantAccount).to receive(:paypal_account_details).and_return(nil)
      end

      describe "basic structure" do
        it "returns a hash with all expected keys" do
          expect(props).to include(
            :id,
            :charge_processor_id,
            :charge_processor_merchant_id,
            :created_at,
            :external_id,
            :user_id,
            :country,
            :country_name,
            :currency,
            :holder_of_funds,
            :stripe_account_url,
            :charge_processor_alive_at,
            :charge_processor_verified_at,
            :charge_processor_deleted_at,
            :updated_at,
            :deleted_at,
            :live_attributes
          )
        end
      end

      describe "fields" do
        it "returns the correct field values" do
          expect(props[:id]).to eq(merchant_account.id)
          expect(props[:charge_processor_id]).to eq(merchant_account.charge_processor_id)
          expect(props[:charge_processor_merchant_id]).to eq(merchant_account.charge_processor_merchant_id)
          expect(props[:created_at]).to eq(merchant_account.created_at)
          expect(props[:external_id]).to eq(merchant_account.external_id)
          expect(props[:user_id]).to eq(merchant_account.user_id)
          expect(props[:country]).to eq(merchant_account.country)
          expect(props[:currency]).to eq(merchant_account.currency)
          expect(props[:holder_of_funds]).to eq(merchant_account.holder_of_funds)
          expect(props[:charge_processor_alive_at]).to eq(merchant_account.charge_processor_alive_at)
          expect(props[:charge_processor_verified_at]).to eq(merchant_account.charge_processor_verified_at)
          expect(props[:charge_processor_deleted_at]).to eq(merchant_account.charge_processor_deleted_at)
          expect(props[:updated_at]).to eq(merchant_account.updated_at)
          expect(props[:deleted_at]).to eq(merchant_account.deleted_at)
        end
      end

      describe "country information" do
        context "when merchant account has a country" do
          let(:merchant_account) { create(:merchant_account, country: "US") }

          it "returns the country name" do
            expect(props[:country]).to eq("US")
            expect(props[:country_name]).to eq("United States")
          end
        end

        context "when merchant account has no country" do
          let(:merchant_account) { create(:merchant_account, country: nil) }

          it "returns nil for country_name" do
            expect(props[:country]).to be_nil
            expect(props[:country_name]).to be_nil
          end
        end
      end

      describe "stripe account url" do
        context "when merchant account is for Stripe" do
          let(:merchant_account) do
            create(:merchant_account,
                  charge_processor_id: StripeChargeProcessor.charge_processor_id,
                  charge_processor_merchant_id: "acct_test123")
          end

          it "returns the Stripe account URL" do
            expect(props[:stripe_account_url]).to include("acct_test123")
          end
        end

        context "when merchant account is for PayPal" do
          let(:merchant_account) do
            create(:merchant_account_paypal,
                  charge_processor_merchant_id: "PAYPAL123")
          end

          it "returns nil for stripe_account_url" do
            expect(props[:stripe_account_url]).to be_nil
          end
        end
      end
    end

    describe "live attributes" do
      context "for Stripe merchant accounts", :vcr do
        let(:merchant_account) do
          create(:merchant_account, charge_processor_merchant_id: "acct_19paZxAQqMpdRp2I")
        end

        it "returns the correct attribute values" do
          live_attrs = props[:live_attributes]

          expect(props[:live_attributes]).to match(
            "Charges enabled" => false,
            "Payout enabled" => false,
            "Disabled reason" => "rejected.fraud",
            "Fields needed" => hash_including(
              "pending_verification" => ["business_profile.url"]
            )
          )
        end
      end

      context "for PayPal merchant accounts", :vcr do
        let(:merchant_account) do
          create(:merchant_account_paypal, charge_processor_merchant_id: "B66YJBBNCRW6L")
        end

        it "returns the email address associated with the PayPal account" do
          expect(props[:live_attributes]).to eq(
            "Email" => "sb-byx2u2205460@business.example.com"
          )
        end
      end

      context "when PayPal account details are not available" do
        let(:merchant_account) do
          create(:merchant_account_paypal, charge_processor_merchant_id: "INVALID_ID")
        end

        before do
          allow(merchant_account).to receive(:paypal_account_details).and_return(nil)
        end

        it "returns an empty hash for live_attributes" do
          expect(props[:live_attributes]).to eq({})
        end
      end
    end
  end
end

