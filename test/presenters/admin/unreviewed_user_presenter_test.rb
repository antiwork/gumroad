# frozen_string_literal: true

require "test_helper"

class AdminUnreviewedUserPresenterTest < ActiveSupport::TestCase
  self.described_class = Admin::UnreviewedUserPresenter



  context_ Admin::UnreviewedUserPresenter do
    include Rails.application.routes.url_helpers

  context_ "#props" do
      let(:user) do
        create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
      end

      let(:balance) { create(:balance, user:, amount_cents: 5000) }

      before do
        balance
        # Simulate the total_balance_cents attribute that comes from the service query
        allow(user).to receive(:total_balance_cents).and_return(5000)
      end

  test "returns external_id" do
        props = described_class.new(user).props

        expect(props[:external_id]).to eq(user.external_id)
      end

  test "returns display name" do
        props = described_class.new(user).props

        expect(props[:name]).to eq(user.display_name)
      end

  test "returns email" do
        props = described_class.new(user).props

        expect(props[:email]).to eq(user.email)
      end

  test "returns unpaid_balance_cents" do
        props = described_class.new(user).props

        expect(props[:unpaid_balance_cents]).to eq(5000)
      end

  test "returns admin_url with external_id" do
        props = described_class.new(user).props

        expect(props[:admin_url]).to eq(admin_user_path(user.external_id))
      end

  test "returns created_at in ISO8601 format" do
        props = described_class.new(user).props

        expect(props[:created_at]).to eq(user.created_at.iso8601)
      end

  test "returns account_age_days" do
        user.update!(created_at: 30.days.ago)

        props = described_class.new(user).props

        expect(props[:account_age_days]).to eq(30)
      end

  context_ "payout_method" do
  test "returns nil when no payout method is configured" do
          user.update!(payment_address: nil)

          props = described_class.new(user).props

          expect(props[:payout_method]).to be_nil
        end

  test "returns 'Stripe Connect' when user has Stripe Connect account" do
          allow(user).to receive(:has_stripe_account_connected?).and_return(true)

          props = described_class.new(user).props

          expect(props[:payout_method]).to eq("Stripe Connect")
        end

  test "returns 'Stripe' when user has active bank account" do
          create(:ach_account, user:)

          props = described_class.new(user).props

          expect(props[:payout_method]).to eq("Stripe")
        end

  test "returns 'PayPal Connect' when user has PayPal account connected" do
          allow(user).to receive(:has_paypal_account_connected?).and_return(true)
          user.update!(payment_address: nil)

          props = described_class.new(user).props

          expect(props[:payout_method]).to eq("PayPal Connect")
        end

  test "returns 'PayPal' when user has legacy PayPal email" do
          user.update!(payment_address: "paypal@example.com")

          props = described_class.new(user).props

          expect(props[:payout_method]).to eq("PayPal")
        end
      end

  context_ "revenue_sources" do
  test "returns empty array when no revenue sources exist" do
          props = described_class.new(user).props

          expect(props[:revenue_sources]).to eq([])
        end

  test "includes 'sales' when user has sales balance" do
          product = create(:product, user:)
          create(:purchase, seller: user, link: product, purchase_success_balance: balance)

          props = described_class.new(user).props

          expect(props[:revenue_sources]).to include("sales")
        end

  test "includes 'affiliate' when user has affiliate credits" do
          product = create(:product)
          direct_affiliate = create(:direct_affiliate, affiliate_user: user, seller: product.user, products: [product])
          purchase = create(:purchase, link: product, affiliate: direct_affiliate)
          create(:affiliate_credit, affiliate_user: user, seller: product.user, purchase:, link: product, affiliate: direct_affiliate, affiliate_credit_success_balance: balance)

          props = described_class.new(user).props

          expect(props[:revenue_sources]).to include("affiliate")
          expect(props[:revenue_sources]).not_to include("collaborator")
        end

  test "includes 'collaborator' when user has collaborator credits" do
          seller = create(:user)
          product = create(:product, user: seller)
          collaborator = create(:collaborator, affiliate_user: user, seller: seller, products: [product])
          purchase = create(:purchase, link: product, affiliate: collaborator)
          create(:affiliate_credit, affiliate_user: user, seller: seller, purchase:, link: product, affiliate: collaborator, affiliate_credit_success_balance: balance)

          props = described_class.new(user).props

          expect(props[:revenue_sources]).to include("collaborator")
          expect(props[:revenue_sources]).not_to include("affiliate")
        end

  test "includes 'credit' when user has credits" do
          create(:credit, user:, balance:, amount_cents: 1000)

          props = described_class.new(user).props

          expect(props[:revenue_sources]).to include("credit")
        end

  test "includes multiple revenue sources when applicable" do
          # Add sales
          product = create(:product, user:)
          create(:purchase, seller: user, link: product, purchase_success_balance: balance)

          # Add credit
          create(:credit, user:, balance:, amount_cents: 1000)

          props = described_class.new(user).props

          expect(props[:revenue_sources]).to include("sales")
          expect(props[:revenue_sources]).to include("credit")
        end
      end
    end
  end
end
