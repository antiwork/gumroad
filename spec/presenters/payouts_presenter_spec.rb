# frozen_string_literal: true

describe PayoutsPresenter do
  include PayoutsHelper
  include CurrencyHelper

  describe "#props" do
    it "does not return current period payouts data if user is not payable" do
      user = create(:user, user_risk_state: "compliant")
      product = create(:product, user:, price_cents: 9_99)
      purchase = create :purchase_in_progress, price_cents: 9_99, link: product, seller: user, purchase_state: "in_progress"
      purchase.process!
      purchase.update_balance_and_mark_successful!
      balance = UserBalanceStatsService.new(user:).fetch
      instance = described_class.new(
        next_payout_period_data: balance[:next_payout_period_data],
        processing_payout_periods_data: balance[:processing_payout_periods_data],
        seller: user,
        past_payouts: [],
        pagination: {}
      )

      expect(instance.props).to eq(
        {
          next_payout_period_data: {
            status: "not_payable",
            should_be_shown_currencies_always: false,
            minimum_payout_amount_cents: 1000,
            is_user_payable: false,
            payout_note: nil,
            has_stripe_connect: false
          },
          processing_payout_periods_data: [],
          payouts_status: "payable",
          payouts_paused_by: nil,
          payouts_paused_for_reason: nil,
          past_payout_period_data: [],
          instant_payout: nil,
          show_instant_payouts_notice: false,
          pagination: {}
        }
      )
    end

    context "when user is payable" do
      it "returns no-account state if the user has no associated payout method" do
        user = create(:user, user_risk_state: "compliant", payment_address: nil)
        product = create(:product, user:, price_cents: 15_00)
        purchase = create :purchase_in_progress, price_cents: 15_00, link: product, seller: user, purchase_state: "in_progress"
        purchase.process!
        purchase.update_balance_and_mark_successful!
        balance = UserBalanceStatsService.new(user:).fetch
        instance = described_class.new(
          next_payout_period_data: balance[:next_payout_period_data],
          processing_payout_periods_data: balance[:processing_payout_periods_data],
          seller: user,
          past_payouts: [],
          pagination: {}
        )
        allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(true)
        allow_any_instance_of(User).to receive(:instantly_payable_unpaid_balance_cents).and_return(1000)
        allow(StripePayoutProcessor).to receive(:instantly_payable_amount_cents_on_stripe).and_return(2000)
        allow_any_instance_of(User).to receive_message_chain(:active_bank_account, :bank_account_type).and_return("checking")
        allow_any_instance_of(User).to receive_message_chain(:active_bank_account, :bank_name).and_return("Test Bank")
        allow_any_instance_of(User).to receive_message_chain(:active_bank_account, :routing_number).and_return("123456789")
        allow_any_instance_of(User).to receive_message_chain(:active_bank_account, :account_number_visual).and_return("****1234")

        expect(instance.props).to eq(
          {
            next_payout_period_data: {
              should_be_shown_currencies_always: false,
              minimum_payout_amount_cents: 1000,
              is_user_payable: true,
              displayable_payout_period_range: balance[:next_payout_period_data][:displayable_payout_period_range],
              payout_currency: "usd",
              payout_cents: 1226,
              payout_displayed_amount: "$12.26",
              payout_date_formatted: formatted_payout_date(user.next_payout_date),
              sales_cents: 1500,
              refunds_cents: 0,
              chargebacks_cents: 0,
              credits_cents: 0,
              fees_cents: 274, # 1500 * 0.129 + 50 + 30
              discover_fees_cents: 0,
              direct_fees_cents: 274,
              discover_sales_count: 0,
              direct_sales_count: 1,
              taxes_cents: 0,
              loan_repayment_cents: 0,
              affiliate_credits_cents: 0,
              affiliate_fees_cents: 0,
              paypal_payout_cents: 0,
              stripe_connect_payout_cents: 0,
              payout_method_type: "none",
              status: "payable",
              payout_note: nil,
              type: "standard",
              has_stripe_connect: false
            },
            processing_payout_periods_data: [],
            payouts_status: "payable",
            payouts_paused_by: nil,
            payouts_paused_for_reason: nil,
            past_payout_period_data: [],
            instant_payout: {
              payable_amount_cents: 1000,
              payable_balances: [
                {
                  id: user.balances.last.external_id,
                  date: Date.today,
                  amount_cents: 1226
                }
              ],
              bank_account_type: "checking",
              bank_name: "Test Bank",
              routing_number: "123456789",
              account_number: "****1234"
            },
            show_instant_payouts_notice: false,
            pagination: {}
          }
        )
      end

      it "returns paypal account's current period payouts data" do
        user = create(:user, user_risk_state: "compliant")
        create(:merchant_account_paypal, user:)
        link = create(:product, user:, price_cents: 15_00)
        purchase = create :purchase_in_progress, price_cents: 15_00, link:, seller: user, purchase_state: "in_progress"
        purchase.process!
        purchase.update_balance_and_mark_successful!
        balance = UserBalanceStatsService.new(user:).fetch
        instance = described_class.new(
          next_payout_period_data: balance[:next_payout_period_data],
          processing_payout_periods_data: balance[:processing_payout_periods_data],
          seller: user,
          past_payouts: [],
          pagination: {}
        )

        expect(instance.props).to eq(
          {
            next_payout_period_data: {
              status: "payable",
              should_be_shown_currencies_always: false,
              minimum_payout_amount_cents: 1000,
              is_user_payable: true,
              displayable_payout_period_range: balance[:next_payout_period_data][:displayable_payout_period_range],
              payout_currency: "usd",
              payout_cents: 1226,
              payout_displayed_amount: "$12.26",
              payout_date_formatted: formatted_payout_date(user.next_payout_date),
              sales_cents: 1500,
              refunds_cents: 0,
              chargebacks_cents: 0,
              credits_cents: 0,
              fees_cents: 274, # 1500 * 0.129 + 50 + 30
              discover_fees_cents: 0,
              direct_fees_cents: 274,
              discover_sales_count: 0,
              direct_sales_count: 1,
              taxes_cents: 0,
              loan_repayment_cents: 0,
              affiliate_credits_cents: 0,
              affiliate_fees_cents: 0,
              paypal_payout_cents: 0,
              stripe_connect_payout_cents: 0,
              payout_method_type: "paypal",
              paypal_address: user.payment_address,
              payout_note: nil,
              type: "standard",
              has_stripe_connect: false
            },
            processing_payout_periods_data: [],
            payouts_status: "payable",
            payouts_paused_by: nil,
            payouts_paused_for_reason: nil,
            past_payout_period_data: [],
            instant_payout: nil,
            show_instant_payouts_notice: false,
            pagination: {}
          }
        )
      end
    end

    it "returns has_stripe_connect set to false if the user is not stripe connect" do
      user = create(:user, user_risk_state: "compliant")
      balance = UserBalanceStatsService.new(user: user).fetch
      instance = described_class.new(
        next_payout_period_data: balance[:next_payout_period_data],
        processing_payout_periods_data: balance[:processing_payout_periods_data],
        seller: user,
        past_payouts: [],
        pagination: {}
      )
      expect(instance.props[:next_payout_period_data]).to include(has_stripe_connect: false)
    end

    it "returns has_stripe_connect set to true if the user is stripe connect" do
      user = create(:user, user_risk_state: "compliant")
      MerchantAccount.create!(
        user: user,
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        charge_processor_merchant_id: "acct_test123",
        charge_processor_verified_at: Time.current,
        charge_processor_alive_at: Time.current,
        json_data: { meta: { stripe_connect: "true" } }
      )
      balance = UserBalanceStatsService.new(user: user).fetch
      instance = described_class.new(
        next_payout_period_data: balance[:next_payout_period_data],
        processing_payout_periods_data: balance[:processing_payout_periods_data],
        seller: user,
        past_payouts: [],
        pagination: {}
      )
      expect(instance.props[:next_payout_period_data]).to include(has_stripe_connect: true)
    end

    context "when seller's payouts are paused" do
      it "returns the payout pause source and reason if present" do
        user = create(:user, user_risk_state: "compliant", payouts_paused_internally: true)
        product = create(:product, user:, price_cents: 20_00)
        purchase = create :purchase_in_progress, price_cents: 20_00, link: product, seller: user, purchase_state: "in_progress"
        purchase.process!
        purchase.update_balance_and_mark_successful!
        balance = UserBalanceStatsService.new(user:).fetch
        instance = described_class.new(
          next_payout_period_data: balance[:next_payout_period_data],
          processing_payout_periods_data: balance[:processing_payout_periods_data],
          seller: user,
          past_payouts: [],
          pagination: {}
        )
        expect(instance.props[:payouts_status]).to eq("paused")
        expect(instance.props[:payouts_paused_by]).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
        expect(instance.props[:payouts_paused_for_reason]).to eq(nil)

        user.update!(payouts_paused_internally: true, payouts_paused_by: User.last.id)
        user.comments.create!(
          author_id: User.last.id,
          content: "Chargeback rate too high.",
          comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED
        )
        expect(instance.props[:payouts_paused_by]).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
        expect(instance.props[:payouts_paused_for_reason]).to eq("Chargeback rate too high.")

        user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
        expect(instance.props[:payouts_paused_by]).to eq(User::PAYOUT_PAUSE_SOURCE_STRIPE)
        expect(instance.props[:payouts_paused_for_reason]).to eq(nil)

        user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
        expect(instance.props[:payouts_paused_by]).to eq(User::PAYOUT_PAUSE_SOURCE_SYSTEM)
        expect(instance.props[:payouts_paused_for_reason]).to eq(nil)

        user.update!(payouts_paused_internally: false, payouts_paused_by_user: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_USER)
        expect(instance.props[:payouts_paused_by]).to eq(User::PAYOUT_PAUSE_SOURCE_USER)
        expect(instance.props[:payouts_paused_for_reason]).to eq(nil)

        user.update!(payouts_paused_internally: false, payouts_paused_by_user: false, payouts_paused_by: nil)
        expect(instance.props[:payouts_paused_by]).to eq(nil)
        expect(instance.props[:payouts_paused_for_reason]).to eq(nil)
      end
    end
  end
end
