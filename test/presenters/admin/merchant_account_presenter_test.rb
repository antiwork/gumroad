# frozen_string_literal: true

require "test_helper"

class AdminMerchantAccountPresenterTest < ActiveSupport::TestCase
  self.described_class = Admin::MerchantAccountPresenter



  context_ Admin::MerchantAccountPresenter do
  context_ "#props" do
      let(:merchant_account) { create(:merchant_account) }
      let(:presenter) { described_class.new(merchant_account:) }

      subject(:props) { presenter.props }

  context_ "database attributes" do
        before do
          allow(Stripe::Account).to receive(:retrieve).and_return(double(:account, charges_enabled: false, payouts_enabled: false, requirements: double(:requirements, disabled_reason: "rejected.fraud", as_json: {})))
          allow_any_instance_of(MerchantAccount).to receive(:paypal_account_details).and_return(nil)
        end

  context_ "fields" do
  test "returns the correct field values" do
            expect(props).to match(
              charge_processor_id: merchant_account.charge_processor_id,
              charge_processor_merchant_id: merchant_account.charge_processor_merchant_id,
              created_at: merchant_account.created_at,
              external_id: merchant_account.external_id,
              user_external_id: merchant_account.user.external_id,
              country: merchant_account.country,
              country_name: "United States",
              currency: merchant_account.currency,
              holder_of_funds: merchant_account.holder_of_funds,
              stripe_account_url: include("dashboard.stripe.com"),
              charge_processor_alive_at: merchant_account.charge_processor_alive_at,
              charge_processor_verified_at: merchant_account.charge_processor_verified_at,
              charge_processor_deleted_at: merchant_account.charge_processor_deleted_at,
              updated_at: merchant_account.updated_at,
              deleted_at: merchant_account.deleted_at,
              live_attributes: include({ label: "Charges enabled", value: false }),
            )
          end
        end

  context_ "country information" do
  context_ "when merchant account has a country" do
            let(:merchant_account) { create(:merchant_account, country: "US") }

  test "returns the country name" do
              expect(props[:country]).to eq("US")
              expect(props[:country_name]).to eq("United States")
            end
          end

  context_ "when merchant account has no country" do
            let(:merchant_account) { create(:merchant_account, country: nil) }

  test "returns nil for country_name" do
              expect(props[:country]).to be_nil
              expect(props[:country_name]).to be_nil
            end
          end
        end

  context_ "stripe account url" do
  context_ "when merchant account is for Stripe" do
            let(:merchant_account) do
              create(:merchant_account,
                     charge_processor_id: StripeChargeProcessor.charge_processor_id,
                     charge_processor_merchant_id: "acct_test123")
            end

  test "returns the Stripe account URL" do
              expect(props[:stripe_account_url]).to include("acct_test123")
            end
          end

  context_ "when merchant account is for PayPal" do
            let(:merchant_account) do
              create(:merchant_account_paypal,
                     charge_processor_merchant_id: "PAYPAL123")
            end

  test "returns nil for stripe_account_url" do
              expect(props[:stripe_account_url]).to be_nil
            end
          end
        end
      end

  context_ "live attributes" do
  context_ "for Stripe merchant accounts", :vcr do
          let(:merchant_account) do
            create(:merchant_account, charge_processor_merchant_id: "acct_19paZxAQqMpdRp2I")
          end

  test "returns the correct attribute values" do
            props[:live_attributes]

            expect(props[:live_attributes]).to match_array([
                                                             { label: "Charges enabled", value: false },
                                                             { label: "Payout enabled", value: false },
                                                             { label: "Disabled reason", value: "rejected.fraud" },
                                                             { label: "Fields needed", value: hash_including("pending_verification" => ["business_profile.url"]) }
                                                           ])
          end
        end

  context_ "when Stripe account access has been revoked" do
          let(:merchant_account) do
            create(:merchant_account, charge_processor_merchant_id: "acct_revoked123")
          end

          before do
            allow(Stripe::Account).to receive(:retrieve).with("acct_revoked123").and_raise(
              Stripe::PermissionError.new("The provided key does not have access to account 'acct_revoked123'")
            )
          end

  test "returns an error message instead of raising" do
            expect(props[:live_attributes]).to eq(
              [{ label: "Error", value: "Stripe account access has been revoked or the account no longer exists" }]
            )
          end
        end

  context_ "for PayPal merchant accounts", :vcr do
          let(:merchant_account) do
            create(:merchant_account_paypal, charge_processor_merchant_id: "B66YJBBNCRW6L")
          end

  test "returns the email address associated with the PayPal account" do
            expect(props[:live_attributes]).to eq([
                                                    { label: "Email", value: "sb-byx2u2205460@business.example.com" }
                                                  ])
          end
        end

  context_ "when PayPal account details are not available" do
          let(:merchant_account) do
            create(:merchant_account_paypal, charge_processor_merchant_id: "INVALID_ID")
          end

          before do
            allow(merchant_account).to receive(:paypal_account_details).and_return(nil)
          end

  test "returns an empty array for live_attributes" do
            expect(props[:live_attributes]).to eq([])
          end
        end
      end
    end
  end
end
