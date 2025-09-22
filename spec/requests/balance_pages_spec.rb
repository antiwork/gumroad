# frozen_string_literal: true

require "spec_helper"
require "ostruct"
require "shared_examples/authorize_called"

describe "Balance Pages Scenario", js: true, type: :system do
  include CollabProductHelper

  let(:seller) { create(:named_seller) }
  let(:get_label_value) do
    -> (text) do
      find("h4", text:).find(:xpath, "..").find(":last-child").text
    end
  end

  include_context "with switching account to user as admin for seller"

  describe "index page", type: :system do
    it "shows empty notice if creator hasn't reached balance" do
      visit balance_path
      expect(page).to have_content "Let's get you paid."
    end

    describe "affiliate commission" do
      let(:seller) { create(:affiliate_user, username: "momoney", user_risk_state: "compliant") }
      before do
        @affiliate_user = create(:affiliate_user)
        @product = create :product, user: seller, price_cents: 10_00
        @direct_affiliate = create :direct_affiliate, affiliate_user: @affiliate_user, seller:, affiliate_basis_points: 3000, products: [@product]

        @affiliate_product = create :product, price_cents: 150_00
        @seller_affiliate = create :direct_affiliate, affiliate_user: seller, seller: @affiliate_product.user, affiliate_basis_points: 4000, products: [@affiliate_product]
      end

      it "displays credits and fees in separate rows" do
        @purchase = create(:purchase_in_progress, seller:, link: @product, affiliate: @direct_affiliate)
        @affiliate_purchase = create(:purchase_in_progress, link: @affiliate_product, affiliate: @seller_affiliate)
        [@purchase, @affiliate_purchase].each do |purchase|
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end

        affiliate_commission_received = seller.affiliate_credits.sum("amount_cents")
        affiliate_commission_paid = seller.sales.sum("affiliate_credit_cents")
        index_model_records(Purchase)

        visit balance_path

        expect(get_label_value["Affiliate or collaborator fees received"]).to eq format_money(affiliate_commission_received)
        expect(get_label_value["Affiliate or collaborator fees paid"]).to eq format_money_negative(affiliate_commission_paid)
      end

      it "reflects refunds of affiliate and own sales separately" do
        3.times.map { create(:purchase_in_progress, seller:, link: @product, affiliate: @direct_affiliate) }.each do |purchase|
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end
        2.times.map { create(:purchase_in_progress, link: @affiliate_product, affiliate: @seller_affiliate) }.each do |purchase|
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end

        affiliate_commission_received = seller.affiliate_credits.sum("amount_cents")
        affiliate_commission_paid = seller.sales.sum("affiliate_credit_cents")

        visit balance_path

        expect(get_label_value["Affiliate or collaborator fees received"]).to eq format_money(affiliate_commission_received)
        expect(get_label_value["Affiliate or collaborator fees paid"]).to eq format_money_negative(affiliate_commission_paid)

        @purchase = seller.sales.last
        @affiliate_purchase = seller.affiliate_credits.last.purchase
        [@purchase, @affiliate_purchase].each do |purchase|
          purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, purchase.total_transaction_cents), seller.id)
        end

        visit balance_path

        commission_received_refund = @affiliate_purchase.affiliate_credit_cents
        commission_paid_refund = @purchase.affiliate_credit_cents

        expect(get_label_value["Affiliate or collaborator fees received"]).to eq format_money(affiliate_commission_received - commission_received_refund)
        expect(get_label_value["Affiliate or collaborator fees paid"]).to eq format_money_negative(affiliate_commission_paid - commission_paid_refund)
      end
    end

    describe "current payout" do
      let!(:now) { Time.current }
      let(:seller) { create :user, user_risk_state: "compliant" }

      it "show processing payment for current payout" do
        product = create :product, user: seller, name: "Petting Capybaras For Fun And Profit"

        purchase = create :purchase, price_cents: 1000, seller:, link: product, card_type: CardType::PAYPAL, purchase_state: "in_progress"
        purchase.update_balance_and_mark_successful!

        payment, _ = Payouts.create_payment(now, PayoutProcessorType::PAYPAL, seller)
        payment.update(correlation_id: "12345")
        payment.txn_id = 123

        data = {
          should_be_shown_currencies_always: true,
          displayable_payout_period_range: "Activity up to #{humanize_date(now)}",
          payout_date_formatted: humanize_date(now),
          payout_currency: "USD",
          payout_cents: 1000,
          payout_displayed_amount: "$10.00 USD",
          is_processing: true,
          arrival_date: 3.days.from_now.strftime("%B #{3.days.from_now.day.ordinalize}, %Y"),
          status: "processing",
          payment_external_id: "12345",
          sales_cents: 1000,
          refunds_cents: 0,
          chargebacks_cents: 0,
          credits_cents: 0,
          loan_repayment_cents: 0,
          fees_cents: 0,
          taxes_cents: 0,
          discover_fees_cents: 0,
          direct_fees_cents: 0,
          discover_sales_count: 0,
          direct_sales_count: 0,
          affiliate_credits_cents: 0,
          affiliate_fees_cents: 0,
          paypal_payout_cents: 0,
          stripe_connect_payout_cents: 0,
          payout_method_type: "none",
          payout_note: nil,
          type: Payouts::PAYOUT_TYPE_STANDARD,
          has_stripe_connect: false
        }

        allow_any_instance_of(UserBalanceStatsService).to receive(:payout_period_data).and_return(data)

        visit balance_path

        within_section "Payout initiated on #{humanize_date now}", match: :first do
          expect(page).to have_content("Sales\n$10.00 USD")
        end
      end

      it "shows processing payments for all bank account types" do
        UpdatePayoutMethod.bank_account_types.each do |bank_account_type, params|
          bank_account = create(bank_account_type.underscore, user: seller)

          data = {
            should_be_shown_currencies_always: true,
            displayable_payout_period_range: "Activity up to May 6th, 2022",
            payout_date_formatted: "May 14th, 2022",
            payout_currency: bank_account.currency,
            payout_cents: 3293600,
            payout_displayed_amount: "$90.70 USD",
            is_processing: true,
            arrival_date: 3.days.from_now.strftime("%B #{3.days.from_now.day.ordinalize}, %Y"),
            status: "processing",
            payment_external_id: "l5C1XQfr2TG3WXcGY7YrUg==",
            sales_cents: 10000,
            refunds_cents: 0,
            chargebacks_cents: 0,
            credits_cents: 0,
            loan_repayment_cents: 0,
            fees_cents: 930,
            taxes_cents: 0,
            discover_fees_cents: 0,
            direct_fees_cents: 0,
            discover_sales_count: 0,
            direct_sales_count: 0,
            affiliate_credits_cents: 0,
            affiliate_fees_cents: 0,
            paypal_payout_cents: 0,
            stripe_connect_payout_cents: 0,
            account_number: "1112121234",
            bank_account_type: bank_account.bank_account_type,
            bank_number: "9876",
            routing_number: "100",
            payout_method_type: "bank",
            payout_note: "Payout on November 7, 2024 was skipped because a bank account wasn't added at the time.",
            type: Payouts::PAYOUT_TYPE_STANDARD,
            has_stripe_connect: false
          }.merge(params[:permitted_params].index_with { |_p| "000" })
          allow_any_instance_of(UserBalanceStatsService).to receive(:payout_period_data).and_return(data)
          create(:payment, user: seller)

          visit balance_path

          expect(page).to have_text("Account: 1112121234")
          expect(page).to have_text("Payout initiated on May 14th, 2022")
          expect(page).to have_text("Expected deposit on #{3.days.from_now.strftime("%B #{3.days.from_now.day.ordinalize}, %Y")}")
          expect(page).not_to have_text("Payout on November 7, 2024 was skipped because a bank account wasn't added at the time.")
        end
      end

      it "shows processing payments for creator-owned Stripe Connect payouts" do
        merchant_account = create(:merchant_account_stripe_connect, user: seller)
        create(:payment, user: seller)

        data = {
          should_be_shown_currencies_always: true,
          displayable_payout_period_range: "Activity up to May 6th, 2022",
          payout_date_formatted: "May 14th, 2022",
          payout_currency: "USD",
          payout_cents: 3293600,
          payout_displayed_amount: "$90.70 USD",
          is_processing: true,
          arrival_date: nil,
          status: "processing",
          payment_external_id: "l5C1XQfr2TG3WXcGY7YrUg==",
          sales_cents: 10000,
          refunds_cents: 0,
          chargebacks_cents: 0,
          credits_cents: 0,
          loan_repayment_cents: 0,
          fees_cents: 930,
          taxes_cents: 0,
          discover_fees_cents: 0,
          direct_fees_cents: 0,
          discover_sales_count: 0,
          direct_sales_count: 0,
          affiliate_credits_cents: 0,
          affiliate_fees_cents: 0,
          paypal_payout_cents: 0,
          stripe_connect_payout_cents: 0,
          stripe_connect_account_id: merchant_account.charge_processor_merchant_id,
          payout_method_type: "stripe_connect",
          payout_note: nil,
          type: Payouts::PAYOUT_TYPE_STANDARD,
          has_stripe_connect: true
        }
        allow_any_instance_of(UserBalanceStatsService).to receive(:payout_period_data).and_return(data)

        visit balance_path
        expect(page).to have_text("Stripe account: #{merchant_account.charge_processor_merchant_id}")
        expect(page).not_to have_text("Expected deposit on")
      end

      it "shows completed payments for creator-owned Stripe Connect payouts" do
        merchant_account = create(:merchant_account_stripe_connect, user: seller)
        create(:payment_completed, user: seller)

        top_period_data = {
          status: "not_payable",
          should_be_shown_currencies_always: true,
          minimum_payout_amount_cents: 1000,
        }

        data = {
          should_be_shown_currencies_always: true,
          displayable_payout_period_range: "Activity up to May 6th, 2022",
          payout_date_formatted: "May 14th, 2022",
          payout_currency: "USD",
          payout_cents: 3293600,
          payout_displayed_amount: "$90.70 USD",
          arrival_date: nil,
          status: "completed",
          is_processing: false,
          payment_external_id: "l5C1XQfr2TG3WXcGY7YrUg==",
          sales_cents: 10000,
          refunds_cents: 0,
          chargebacks_cents: 0,
          credits_cents: 0,
          loan_repayment_cents: 0,
          fees_cents: 930,
          taxes_cents: 0,
          discover_fees_cents: 0,
          direct_fees_cents: 0,
          discover_sales_count: 0,
          direct_sales_count: 0,
          affiliate_credits_cents: 0,
          affiliate_fees_cents: 0,
          paypal_payout_cents: 0,
          stripe_connect_payout_cents: 0,
          stripe_connect_account_id: merchant_account.charge_processor_merchant_id,
          payout_method_type: "stripe_connect",
          type: Payouts::PAYOUT_TYPE_STANDARD,
          has_stripe_connect: true
        }
        allow_any_instance_of(UserBalanceStatsService).to receive(:payout_period_data).and_return(top_period_data)
        allow_any_instance_of(PayoutsPresenter).to receive(:payout_period_data).and_return(data)


        visit balance_path
        expect(page).to have_text("Stripe account: #{merchant_account.charge_processor_merchant_id}")
        expect(page).not_to have_text("Expected deposit on")
      end

      describe "instant payouts" do
        let(:seller) { create(:compliant_user, unpaid_balance_cents: 10_01) }
        let!(:merchant_account) { create(:merchant_account_stripe_connect, user: seller) }
        let(:stripe_connect_account_id) { merchant_account.charge_processor_merchant_id }

        before do
          create(:ach_account, user: seller, stripe_bank_account_id: stripe_connect_account_id)
          create(:user_compliance_info, user: seller)
        end

        context "when there is a processing instant payout" do
          let!(:instant_payout) do
            create(:payment, user: seller, processor: PayoutProcessorType::STRIPE, state: "processing", stripe_connect_account_id:, payout_period_end_date: 1.month.ago, json_data: { payout_type: Payouts::PAYOUT_TYPE_INSTANT })
          end

          it "only renders the instant payout" do
            visit balance_path

            expect(page).to have_text("Payout initiated on #{humanize_date(instant_payout.created_at)}\nInstant\nActivity")
            expect(page).to_not have_text("Next payout")
          end

          context "when there is also a processing standard payout" do
            let!(:standard_payout) do
              create(:payment, user: seller, processor: PayoutProcessorType::STRIPE, state: "processing", stripe_connect_account_id:)
            end

            it "renders both instant and standard payouts as processing, and no next payout" do
              visit balance_path

              expect(page).to have_text("Payout initiated on #{humanize_date(instant_payout.created_at)}\nInstant\nActivity")
              expect(page).to have_text("Payout initiated on #{humanize_date(standard_payout.created_at)}\nActivity")
              expect(page).not_to have_text("Next payout")
            end
          end
        end
      end

      context "when current payment is not processing" do
        let(:seller) { create(:user, user_risk_state: "compliant") }
        let(:product) { create(:product, user: seller, price_cents: 20_00) }
        let(:merchant_account) { create(:merchant_account_stripe_connect, user: seller) }

        before do
          (0..13).each do |days_count|
            travel_to(Date.parse("2013-08-14") - days_count.days) do
              create(:purchase_with_balance, link: product)
            end
          end
          seller.add_payout_note(content: "Payout on November 7, 2024 was skipped because a bank account wasn't added at the time.")
        end

        context "when payouts status is payable" do
          it "renders the date in heading" do
            travel_to(Date.parse("2013-08-14")) do
              visit balance_path

              expect(page).not_to have_content "Your payouts have been paused."
              expect(page).to have_text("Payout on November 7, 2024 was skipped because a bank account wasn't added at the time.")

              expect(page).to have_section("Next payout: August 16th, 2013")
            end
          end

          it "shows the creator-owned Stripe Connect account when it is the destination of the 'Next Payout'" do
            data = {
              should_be_shown_currencies_always: true,
              displayable_payout_period_range: "Activity up to May 6th, 2022",
              payout_date_formatted: "May 14th, 2022",
              payout_currency: "USD",
              payout_cents: 3293600,
              payout_displayed_amount: "$90.70 USD",
              arrival_date: nil,
              status: "payable",
              payment_external_id: "l5C1XQfr2TG3WXcGY7YrUg==",
              sales_cents: 10000,
              refunds_cents: 0,
              chargebacks_cents: 0,
              credits_cents: 0,
              loan_repayment_cents: 0,
              fees_cents: 930,
              taxes_cents: 0,
              discover_fees_cents: 0,
              direct_fees_cents: 0,
              discover_sales_count: 0,
              direct_sales_count: 0,
              affiliate_credits_cents: 0,
              affiliate_fees_cents: 0,
              paypal_payout_cents: 0,
              stripe_connect_payout_cents: 0,
              stripe_connect_account_id: merchant_account.charge_processor_merchant_id,
              payout_method_type: "stripe_connect",
              payout_note: nil,
              type: Payouts::PAYOUT_TYPE_STANDARD,
              has_stripe_connect: true
            }
            allow_any_instance_of(UserBalanceStatsService).to receive(:payout_period_data).and_return(data)

            visit balance_path
            expect(page).to have_content("For Stripe Connect users, all future payouts will be deposited directly to your Stripe account")
          end
        end

        context "when payouts have been manually paused by admin" do
          before do
            seller.update!(payouts_paused_internally: true)
          end

          it "renders notice and paused in the heading" do
            travel_to(Date.parse("2013-08-14")) do
              visit balance_path

              expect(page).to have_status(text: "Your payouts have been paused by Gumroad admin.")
              expect(page).to have_section("Next payout: paused")
              expect(page).not_to have_text("Payout on November 7, 2024 was skipped because a bank account wasn't added at the time.")
            end
          end

          it "includes the reason provided by admin in the notice" do
            seller.comments.create!(
              author_id: User.last.id,
              content: "Chargeback rate is too high.",
              comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED
            )

            travel_to(Date.parse("2013-08-14")) do
              visit balance_path

              expect(page).to have_status(text: "Your payouts have been paused by Gumroad admin. Reason for pause: Chargeback rate is too high.")
              expect(page).to have_section("Next payout: paused")
              expect(page).not_to have_text("Payout on November 7, 2024 was skipped because a bank account wasn't added at the time.")
            end
          end
        end

        context "when payouts have been automatically paused by the system" do
          before do
            seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
          end

          it "renders notice and paused in the heading" do
            travel_to(Date.parse("2013-08-14")) do
              visit balance_path

              expect(page).to have_status(text: "Your payouts have been automatically paused for a security review and will be resumed once the review completes.")
              expect(page).to have_section("Next payout: paused")
              expect(page).not_to have_text("Payout on November 7, 2024 was skipped because a bank account wasn't added at the time.")
            end
          end
        end

        context "when payouts have been paused by Stripe" do
          before do
            seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
          end

          it "renders notice and paused in the heading" do
            travel_to(Date.parse("2013-08-14")) do
              visit balance_path

              expect(page).to have_status(text: "Your payouts are currently paused by our payment processor. Please check your Payment Settings for any verification requirements.")
              expect(page).to have_section("Next payout: paused")
              expect(page).not_to have_text("Payout on November 7, 2024 was skipped because a bank account wasn't added at the time.")
            end
          end
        end

        context "when payouts have been paused by the seller" do
          before do
            seller.update!(payouts_paused_by_user: true)
          end

          it "renders notice and paused in the heading" do
            travel_to(Date.parse("2013-08-14")) do
              visit balance_path

              expect(page).to have_status(text: "You have paused your payouts. Please go to Payment Settings to resume payouts.")
              expect(page).to have_section("Next payout: paused")
              expect(page).not_to have_text("Payout on November 7, 2024 was skipped because a bank account wasn't added at the time.")
            end
          end
        end

        describe "payout-skipped notes" do
          context "when the payout was skipped because the account was not compliant" do
            before do
              seller.flag_for_tos_violation!(author_name: "iffy", bulk: true)
              seller.suspend_for_tos_violation!(author_name: "iffy", bulk: true)
              Payouts.is_user_payable(seller, Date.yesterday, add_comment: true, from_admin: false)
              seller.mark_compliant!(author_name: "iffy")
            end

            it "shows the payout-skipped notice" do
              visit balance_path

              expect(page).to have_text("Payout on #{Time.current.to_fs(:formatted_date_full_month)} was skipped because the account was not compliant.")
            end
          end

          context "when the payout was skipped because the payouts were paused by the admin" do
            before do
              seller.update!(payouts_paused_internally: true)
              Payouts.is_user_payable(seller, Date.yesterday, add_comment: true, from_admin: false)
              seller.update!(payouts_paused_internally: false)
            end

            it "shows the payout-skipped notice" do
              visit balance_path

              expect(page).to have_text("Payout on #{Time.current.to_fs(:formatted_date_full_month)} was skipped because payouts on the account were paused by the admin.")
            end
          end

          context "when the payout was skipped because the payouts were paused by the system" do
            before do
              seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
              Payouts.is_user_payable(seller, Date.yesterday, add_comment: true, from_admin: false)
              seller.update!(payouts_paused_internally: false, payouts_paused_by: nil)
            end

            it "shows the payout-skipped notice" do
              visit balance_path

              expect(page).to have_text("Payout on #{Time.current.to_fs(:formatted_date_full_month)} was skipped because payouts on the account were paused by the system.")
            end
          end

          context "when the payout was skipped because the payouts were paused by Stripe" do
            before do
              seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
              Payouts.is_user_payable(seller, Date.yesterday, add_comment: true, from_admin: false)
              seller.update!(payouts_paused_internally: false, payouts_paused_by: nil)
            end

            it "shows the payout-skipped notice" do
              visit balance_path

              expect(page).to have_text("Payout on #{Time.current.to_fs(:formatted_date_full_month)} was skipped because payouts on the account were paused by the payout processor.")
            end
          end

          context "when the payout was skipped because the payouts were paused by the seller" do
            before do
              seller.update!(payouts_paused_by_user: true)
              Payouts.is_user_payable(seller, Date.yesterday, add_comment: true, from_admin: false)
              seller.update!(payouts_paused_by_user: false)
            end

            it "shows the payout-skipped notice" do
              visit balance_path

              expect(page).to have_text("Payout on #{Time.current.to_fs(:formatted_date_full_month)} was skipped because payouts on the account were paused by the user.")
            end
          end

          context "when the payout was skipped because the payout amount was less than the threshold" do
            before do
              allow_any_instance_of(User).to receive(:unpaid_balance_cents_up_to_date).and_return(5_00)
              Payouts.is_user_payable(seller, Date.yesterday, add_comment: true, from_admin: false)
            end

            it "shows the payout-skipped notice" do
              visit balance_path

              expect(page).to have_text("Payout on #{Time.current.to_fs(:formatted_date_full_month)} was skipped because the account balance $5 USD was less than the minimum payout amount of $10 USD.")
            end
          end

          context "when the payout was skipped because a payout was already in processing" do
            before do
              payment = create(:payment, user: seller)
              Payouts.is_user_payable(seller, Date.yesterday, add_comment: true, from_admin: false)
              payment.mark_failed!
            end

            it "shows the payout-skipped notice" do
              visit balance_path

              expect(page).to have_text("Payout on #{Time.current.to_fs(:formatted_date_full_month)} was skipped because there was already a payout in processing.")
            end
          end

          context "when the payout was skipped because there was no bank account on record" do
            before do
              Payouts.is_user_payable(seller, Date.yesterday, add_comment: true, from_admin: false)
            end

            it "shows the payout-skipped notice" do
              visit balance_path

              expect(page).to have_text("Payout on #{Time.current.to_fs(:formatted_date_full_month)} was skipped because a bank account wasn't added at the time.")
            end
          end

          context "when the payout was skipped because bank account info is not correctly updated" do
            before do
              create(:ach_account, user: seller)
              Payouts.is_user_payable(seller, Date.yesterday, add_comment: true, from_admin: false)
            end

            it "shows the payout-skipped notice" do
              visit balance_path

              expect(page).to have_text("Payout on #{Time.current.to_fs(:formatted_date_full_month)} was skipped because the payout bank account was not correctly set up.")
            end
          end

          context "when the payout was skipped because payout amount was less than the local currency threshold" do
            before do
              create(:user_compliance_info, user: seller, country: "South Korea")
              create(:korea_bank_account, user: seller, stripe_connect_account_id: "sc_id", stripe_bank_account_id: "ba_id")
              create(:merchant_account, user: seller)
              allow_any_instance_of(User).to receive(:unpaid_balance_cents_up_to_date).and_return(15_00)
              Payouts.is_user_payable(seller, Date.yesterday, add_comment: true, from_admin: false)
            end

            it "shows the payout-skipped notice" do
              visit balance_path

              expect(page).to have_text("Payout on #{Time.current.to_fs(:formatted_date_full_month)} was skipped because the account balance $15 USD was less than the minimum payout amount of $34.74 USD.")
            end
          end
        end
      end

      it "shows currency conversion message when payout currency is not USD" do
        seller = create(:user, user_risk_state: "compliant")
        create(:ach_account, user: seller)

        data = {
          should_be_shown_currencies_always: true,
          displayable_payout_period_range: "Activity up to May 6th, 2022",
          payout_date_formatted: "May 14th, 2022",
          payout_currency: "EUR",
          payout_cents: 10000,
          payout_displayed_amount: "€100.00 EUR",
          is_processing: false,
          arrival_date: nil,
          status: "payable",
          payment_external_id: "l5C1XQfr2TG3WXcGY7YrUg==",
          sales_cents: 11000,
          refunds_cents: 0,
          chargebacks_cents: 0,
          credits_cents: 0,
          loan_repayment_cents: 0,
          fees_cents: 930,
          taxes_cents: 0,
          discover_fees_cents: 0,
          direct_fees_cents: 0,
          discover_sales_count: 0,
          direct_sales_count: 0,
          affiliate_credits_cents: 0,
          affiliate_fees_cents: 0,
          paypal_payout_cents: 0,
          stripe_connect_payout_cents: 0,
          account_number: "1112121234",
          bank_account_type: "ACH",
          bank_number: "9876",
          routing_number: "100",
          payout_method_type: "bank",
          payout_note: nil,
          type: Payouts::PAYOUT_TYPE_STANDARD,
          has_stripe_connect: false
        }
        allow_any_instance_of(UserBalanceStatsService).to receive(:payout_period_data).and_return(data)

        visit balance_path

        expect(page).to have_text("Will be converted to EUR and sent to:")
      end

      it "shows expected deposit date and non-USD amount for processing payments" do
        seller = create(:user, user_risk_state: "compliant")
        create(:ach_account, user: seller)

        data = {
          should_be_shown_currencies_always: true,
          displayable_payout_period_range: "Activity up to #{2.days.ago.strftime('%B %-d, %Y')}",
          payout_date_formatted: Date.today.strftime("%B %-d, %Y"),
          payout_currency: "EUR",
          payout_cents: 10000,
          payout_displayed_amount: "€100.00 EUR",
          is_processing: true,
          arrival_date: 3.days.from_now.strftime("%B #{3.days.from_now.day.ordinalize}, %Y"),
          status: "processing",
          payment_external_id: "l5C1XQfr2TG3WXcGY7YrUg==",
          sales_cents: 11000,
          refunds_cents: 0,
          chargebacks_cents: 0,
          credits_cents: 0,
          loan_repayment_cents: 0,
          fees_cents: 930,
          taxes_cents: 0,
          direct_fees_cents: 0,
          discover_fees_cents: 0,
          discover_sales_count: 0,
          direct_sales_count: 0,
          affiliate_credits_cents: 0,
          affiliate_fees_cents: 0,
          paypal_payout_cents: 0,
          stripe_connect_payout_cents: 0,
          account_number: "1112121234",
          bank_account_type: "ACH",
          bank_number: "9876",
          routing_number: "100",
          payout_method_type: "bank",
          payout_note: nil,
          type: "standard",
          has_stripe_connect: false,
          minimum_payout_amount_cents: 1000,
          is_payable: true
        }
        allow_any_instance_of(UserBalanceStatsService).to receive(:payout_period_data).and_return(data)

        visit balance_path

        expect(page).to have_text("Expected deposit on")
        expect(page).to have_text("€100.00 EUR")
      end
    end

    describe "instant payout" do
      context "when user has a balance and is eligible for instant payouts" do
        before do
          create(:tos_agreement, user: seller)
          create(:user_compliance_info, user: seller)
          create_list(:payment_completed, 4, user: seller)
          create(:bank, routing_number: "110000000", name: "Bank of America")
          create(:ach_account_stripe_succeed,
                 user: seller,
                 routing_number: "110000000",
                 stripe_connect_account_id: "acct_1Qplf7S17V0i16U7",
                 stripe_external_account_id: "ba_1Qplf7S17V0i16U7S5L4chWo",
                 stripe_fingerprint: "dx7dqwoGHEQDKLLK",
                 )
          create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_1Qplf7S17V0i16U7")

          Credit.create_for_credit!(user: seller, amount_cents: 1000, crediting_user: seller)
          allow_any_instance_of(User).to receive(:compliant?).and_return(true)
        end

        it "allows the user to trigger an instant payout" do
          visit balance_path

          expect(page).to have_status(text: "You have $10.00 available for instant payout: No need to wait—get paid now!")
          click_on "Get paid!"
          within_modal "Instant payout" do
            expect(page).to have_text("You can request instant payouts 24/7, including weekends and holidays. Funds typically appear in your bank account within 30 minutes, though some payouts may take longer to be credited.")
            expect(page).to have_select("Pay out balance up to", selected: Date.current.strftime("%B %-d, %Y"))
            expect(page).to have_text("Sent to Bank of America", normalize_ws: true)
            expect(page).to have_text("Amount $10", normalize_ws: true)
            expect(page).to have_text("Instant payout fee (3%) -$0.30", normalize_ws: true)
            expect(page).to have_text("You'll receive $9.70", normalize_ws: true)
            click_on "Cancel"
          end
          expect(page).to_not have_modal("Instant payout")

          click_on "Get paid!"
          within_modal "Instant payout" do
            click_on "Get paid!"
          end

          current_date = Time.current.strftime("%B #{Time.current.day.ordinalize}, %Y")
          expect(page).to have_text("Payout initiated on #{current_date} Instant", normalize_ws: true)
          expect(page).to have_text("Sales $0.00", normalize_ws: true)
          expect(page).to have_text("Credits $10.00", normalize_ws: true)
          expect(page).to have_text("Direct sales fees - $0.29", normalize_ws: true)
          expect(page).to have_text("Expected deposit to Bank of America on #{current_date} Routing number: 110000000 Account: ******6789 $9.70", normalize_ws: true)
        end
      end

      context "when user's balance is greater than the maximum instant payout amount but a single balance does not exceed the maximum instant payout amount" do
        before do
          allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(true)
          allow_any_instance_of(User).to receive(:instantly_payable_unpaid_balance_cents).and_return(1500000)
          allow_any_instance_of(User).to receive_message_chain(:active_bank_account, :bank_account_type).and_return("ACH")
          allow_any_instance_of(User).to receive_message_chain(:active_bank_account, :bank_name).and_return("Test Bank")
          allow_any_instance_of(User).to receive_message_chain(:active_bank_account, :routing_number).and_return("110000000")
          allow_any_instance_of(User).to receive_message_chain(:active_bank_account, :account_number_visual).and_return("******6789")
          allow_any_instance_of(User).to receive(:instantly_payable_unpaid_balances).and_return(
            [
              OpenStruct.new(
                external_id: "1",
                date: "2025-01-01",
                holding_amount_cents: 500000
              ),
              OpenStruct.new(
                external_id: "2",
                date: "2025-01-02",
                holding_amount_cents: 400000
              ),
              OpenStruct.new(
                external_id: "3",
                date: "2025-01-03",
                holding_amount_cents: 600000
              )
            ]
          )
        end

        it "displays a notice and allows instant payouts" do
          visit balance_path

          expect(page).to have_status(text: "You have $15,000.00 available for instant payout: No need to wait—get paid now!")
          click_on "Get paid!"
          within_modal "Instant payout" do
            expect(page).to have_text("You can request instant payouts 24/7, including weekends and holidays. Funds typically appear in your bank account within 30 minutes, though some payouts may take longer to be credited.")
            expect(page).to have_text("Sent to Test Bank", normalize_ws: true)

            expect(page).to have_select("Pay out balance up to", selected: "January 3, 2025")
            expect(page).to have_text("Amount $15,000", normalize_ws: true)
            expect(page).to have_text("Instant payout fee (3%) -$436.90", normalize_ws: true)
            expect(page).to have_text("You'll receive $14,563.10", normalize_ws: true)
            expect(page).to have_status(text: "Your balance exceeds the maximum amount for a single instant payout, so we'll automatically split your balance into multiple payouts.")
            select "January 2, 2025", from: "Pay out balance up to"
            click_on "Cancel"
          end
          click_on "Get paid!"
          within_modal "Instant payout" do
            expect(page).to have_text("Amount $9,000", normalize_ws: true)
            expect(page).to have_text("Instant payout fee (3%) -$262.14", normalize_ws: true)
            expect(page).to have_text("You'll receive $8,737.86", normalize_ws: true)
            expect(page).to_not have_status(text: "Your balance exceeds the maximum amount for a single instant payout, so we'll automatically split your balance into multiple payouts.")
            select "January 1, 2025", from: "Pay out balance up to"
            click_on "Cancel"
          end
          click_on "Get paid!"
          within_modal "Instant payout" do
            expect(page).to have_text("Amount $5,000", normalize_ws: true)
            expect(page).to have_text("Instant payout fee (3%) -$145.64", normalize_ws: true)
            expect(page).to have_text("You'll receive $4,854.36", normalize_ws: true)
            expect(page).to_not have_status(text: "Your balance exceeds the maximum amount for a single instant payout, so we'll automatically split your balance into multiple payouts.")
          end
        end
      end

      context "when the user has a single balance that exceeds the maximum instant payout amount" do
        before do
          allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(true)
          allow_any_instance_of(User).to receive(:instantly_payable_unpaid_balance_cents).and_return(1500000)
          allow_any_instance_of(User).to receive_message_chain(:active_bank_account, :bank_account_type).and_return("ACH")
          allow_any_instance_of(User).to receive_message_chain(:active_bank_account, :bank_name).and_return("Test Bank")
          allow_any_instance_of(User).to receive_message_chain(:active_bank_account, :routing_number).and_return("110000000")
          allow_any_instance_of(User).to receive_message_chain(:active_bank_account, :account_number_visual).and_return("******6789")
          allow_any_instance_of(User).to receive(:instantly_payable_unpaid_balances).and_return(
            [
              OpenStruct.new(
                external_id: "1",
                date: Time.current.to_s,
                holding_amount_cents: 1500000
              )
            ]
          )
        end

        it "shows instant payout alert" do
          visit balance_path

          expect(page).to have_status(text: "You have $15,000.00 available for instant payout")
          expect(page).to have_selector("a", text: "Contact us for an instant payout")
        end
      end

      context "when user's balance is less than the minimum instant payout amount" do
        before do
          allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(true)
          allow_any_instance_of(User).to receive(:instantly_payable_unpaid_balance_cents).and_return(500)
          allow(StripePayoutProcessor).to receive(:instantly_payable_amount_cents_on_stripe).and_return(485)
          allow_any_instance_of(User).to receive_message_chain(:active_bank_account, :bank_account_type).and_return("ACH")
          allow_any_instance_of(User).to receive_message_chain(:active_bank_account, :bank_name).and_return("Test Bank")
          allow_any_instance_of(User).to receive_message_chain(:active_bank_account, :routing_number).and_return("110000000")
          allow_any_instance_of(User).to receive_message_chain(:active_bank_account, :account_number_visual).and_return("******6789")
        end

        it "does not show instant payout alert" do
          visit balance_path

          expect(page).not_to have_text("instant payout")
        end
      end

      context "when user is eligible for instant payouts but their payout account does not support them" do
        before do
          allow_any_instance_of(User).to receive(:eligible_for_instant_payouts?).and_return(true)
        end

        it "shows the instant payout notice" do
          visit balance_path

          expect(page).to have_status(text: "To enable instant payouts, update your payout method to one of the supported bank accounts or debit cards.")
          expect(page).to have_link("update your payout method", href: settings_payments_path)
          expect(page).to have_link("supported bank accounts or debit cards", href: "https://docs.stripe.com/payouts/instant-payouts-banks")
        end
      end
    end

    describe "past payouts" do
      let!(:now) { Time.current }
      let!(:payout_date) { 1.week.ago }
      let(:payout_processor_type) { PayoutProcessorType::STRIPE }
      let(:seller) { create(:named_seller, country: "US") }

      before do
        MerchantAccount.find_or_create_by!(user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id) do |ma|
          ma.charge_processor_alive_at = Time.current
        end
        MerchantAccount.find_or_create_by!(user: nil, charge_processor_id: PaypalChargeProcessor.charge_processor_id) do |ma|
          ma.charge_processor_alive_at = Time.current
        end

        create(:merchant_account_stripe, user: seller)
        create(:merchant_account_paypal, user: seller, charge_processor_merchant_id: "CJS32DZ7NDN5L")

        affiliate_product = create :product, price_cents: 1500
        creator_as_affiliate = create :direct_affiliate, affiliate_user: seller, seller: affiliate_product.user, affiliate_basis_points: 4000, products: [affiliate_product]

        base_past_date = 1.month.ago
        travel_to(base_past_date) do
          @product = create :product, user: seller, name: "Hunting Capybaras For Fun And Profit"
        end
        direct_affiliate = create(:direct_affiliate, seller:, affiliate_user: create(:affiliate_user), affiliate_basis_points: 2000, products: [@product])

        travel_to(base_past_date - 2.days) do
          @purchase_to_chargeback = create_purchase price_cents: 1000, seller:, link: @product
        end

        travel_to(base_past_date) do
          event = OpenStruct.new(created_at: 1.day.ago, extras: {}, flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @purchase_to_chargeback.total_transaction_cents))
          allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!).and_return(nil)
          @purchase_to_chargeback.handle_event_dispute_formalized!(event)

          @regular_purchase = create_purchase price_cents: 1000, seller:, link: @product
          create_purchase price_cents: 1000, seller:, link: @product,
                          affiliate: direct_affiliate,
                          charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                          chargeable: create(:native_paypal_chargeable),
                          merchant_account: create(:merchant_account_paypal, user: seller,
                                                                             charge_processor_merchant_id: "CJS32DZ7NDN5L",
                                                                             country: "GB", currency: "gbp")
          @paypal_purchase_to_refund = create_purchase price_cents: 1000, seller:, link: @product,
                                                       charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                                       chargeable: create(:native_paypal_chargeable),
                                                       merchant_account: create(:merchant_account_paypal, user: seller,
                                                                                                          charge_processor_merchant_id: "CJS32DZ7NDN5L",
                                                                                                          country: "GB", currency: "gbp"),
                                                       affiliate: direct_affiliate
          create_purchase price_cents: 1500, link: affiliate_product, affiliate: creator_as_affiliate
          @purchase_with_tax = create_purchase price_cents: 1000, seller:, link: @product, tax_cents: 200
          @purchase_to_refund = create_purchase price_cents: 1000, seller:, link: @product
          @purchase_to_refund.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @purchase_to_refund.total_transaction_cents), seller)
          @paypal_purchase_to_refund.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @paypal_purchase_to_refund.total_transaction_cents / 2), seller)
          Credit.create_for_financing_paydown!(purchase: @regular_purchase, amount_cents: -150, merchant_account: seller.stripe_account, stripe_loan_paydown_id: "cptxn_1234567")
        end

        create(:ach_account_stripe_succeed, user: seller)
        create(:bank, routing_number: "110000000", name: "Bank of America N.A.")
        create_payout(payout_date, payout_processor_type, seller)
        allow_any_instance_of(Payment).to receive(:arrival_date).and_return 1.day.ago.to_i
      end

      it "displays past payouts, including correct gross sales, refunds, chargebacks, fees, taxes, and net" do
        visit balance_path

        past_payouts = page.all("[aria-label='Payout period']")

        expect(past_payouts.count).to eq 1

        latest_payout = past_payouts[0]

        expect(latest_payout).to have_text(humanize_date(Time.current), normalize_ws: true)
        expect(latest_payout).to have_text("Activity up to #{humanize_date payout_date}", normalize_ws: true)

        expect(latest_payout).to have_text("Sales $60.00", normalize_ws: true)
        expect(latest_payout).to have_text("Affiliate or collaborator fees received $4.90", normalize_ws: true)
        expect(latest_payout).to have_text("Refunds - $15.00", normalize_ws: true)
        expect(latest_payout).to have_text("Chargebacks - $10.00", normalize_ws: true)
        expect(latest_payout).not_to have_text("Discover sales fees", normalize_ws: true)
        expect(latest_payout).to have_text("Direct sales fees on 6 sales - $7.02", normalize_ws: true)
        expect(latest_payout).to have_text("Loan repayments - $1.50", normalize_ws: true)
        expect(latest_payout).to have_text("Affiliate or collaborator fees paid - $2.55", normalize_ws: true)
        expect(latest_payout).to have_text("PayPal payouts - $10.20", normalize_ws: true) # Remove (?) from this line
        expect(latest_payout).to have_text("Deposited to Bank of America N.A. on #{1.day.ago.strftime("%B #{1.day.ago.day.ordinalize}, %Y")}")
        expect(latest_payout).to have_text("Routing number: 110000000 Account: ******6789 $18.63", normalize_ws: true)
      end

      it "shows failed payouts with a displayable failure reason and without expected deposit copy" do
        visit balance_path

        payment = seller.payments.last
        payment.update!(state: Payment::FAILED, failure_reason: "account_closed")

        visit balance_path

        failed_section = page.all("[aria-label='Payout period']").first
        expect(failed_section).to have_text("Failed", normalize_ws: true)
        expect(page).to have_text("This payout failed due to", normalize_ws: true)
        expect(page).to_not have_text("Expected deposit on")
      end

      it "shows failed payouts with verification required message" do
        visit balance_path

        payment = seller.payments.last
        payment.update!(state: Payment::FAILED, failure_reason: "account_closed")

        visit balance_path

        failed_section = page.all("[aria-label='Payout period']").first
        expect(failed_section).to have_text("Failed", normalize_ws: true)
        expect(page).to have_text("This payout failed due to", normalize_ws: true)
        expect(page).to have_text("once verification is complete", normalize_ws: true)
      end

      it "shows failed payouts with retry message for non-verification failures" do
        visit balance_path

        payment = seller.payments.last
        payment.update!(state: Payment::FAILED, failure_reason: "insufficient_funds")

        visit balance_path

        failed_section = page.all("[aria-label='Payout period']").first
        expect(failed_section).to have_text("Failed", normalize_ws: true)
        expect(page).to have_text("This payout failed due to", normalize_ws: true)
        expect(page).to have_text("in the next cycle", normalize_ws: true)
      end

      it "shows carried over amounts from failed payouts in current payout period" do
        failed_payment = seller.payments.last
        failed_payment.update!(state: Payment::FAILED, failure_reason: "insufficient_funds")

        product = create(:product, user: seller)
        purchase = create(:purchase_in_progress, link: product, price_cents: 1000, seller: seller, purchase_state: "in_progress")
        purchase.update_balance_and_mark_successful!

        PayoutUsersService.new(date_string: Date.current, processor_type: PayoutProcessorType::STRIPE, user_ids: [seller.id]).process

        visit balance_path

        current_payout_section = page.all("[aria-label='Payout period']").first
        expect(current_payout_section).to have_text("Carried over from", normalize_ws: true)
      end

      it "shows included in payout information for failed payouts that were later processed" do
        failed_payment = seller.payments.last
        failed_payment.update!(state: Payment::FAILED, failure_reason: "insufficient_funds")

        product = create(:product, user: seller)
        purchase = create(:purchase_in_progress, link: product, price_cents: 1000, seller: seller, purchase_state: "in_progress")
        purchase.update_balance_and_mark_successful!

        PayoutUsersService.new(date_string: Date.current, processor_type: PayoutProcessorType::STRIPE, user_ids: [seller.id]).process

        visit balance_path

        failed_section = page.all("[aria-label='Payout period']").last
        expect(failed_section).to have_text("Included in payout on", normalize_ws: true)
      end

      it "allows CSV download" do
        visit balance_path

        past_payouts = page.all("[aria-label='Payout period']")

        expect(past_payouts.count).to eq 1

        within past_payouts[0] do
          click_on "Export"
          wait_for_ajax
        end

        expect(page).to have_alert(text: "You will receive an email in your inbox shortly with the data you've requested.")

        payment = seller.payments.last
        expect(ExportPayoutData).to have_enqueued_sidekiq_job([payment.id], user_with_role_for_seller.id)
      end

      it "displays 'show older payouts' button when there's pagination" do
        product = create(:product, user: seller)
        [300, 400, 500, 600, 700, 1756].each do |days|
          travel_to((days + 10).days.ago) do
            purchase = create(:purchase_in_progress, link: product, price_cents: days, seller:, purchase_state: "in_progress")
            purchase.update_balance_and_mark_successful!
          end
          travel_to(days.days.ago) do
            create_payout(Time.current, PayoutProcessorType::PAYPAL, seller)
          end
        end
        index_model_records(Balance)
        index_model_records(Purchase)

        visit balance_path

        expect(page).to_not have_content("$7.00")
        expect(page).to_not have_content("$17.56")
        click_on "Show older payouts"

        expect(page).to have_content("$7.00")
        expect(page).to_not have_content("$17.56")
        click_on "Show older payouts"

        expect(page).to have_content("$17.56")
        expect(page).to_not have_content("Show older payouts")
      end

      def create_purchase(**attrs)
        purchase = create :purchase, **attrs, card_type: CardType::PAYPAL, purchase_state: "in_progress"
        purchase.update_balance_and_mark_successful!
        purchase
      end
    end

    def format_money_negative(amount)
      "- #{format_money(amount)}"
    end

    def format_money(amount, no_cents_if_whole: false)
      MoneyFormatter.format(amount, :usd, no_cents_if_whole:, symbol: true)
    end

    def create_payout(payout_date, processor_type, user)
      payment, _ = Payouts.create_payment(payout_date, processor_type, user)
      payment.update(correlation_id: "12345")
      payment.txn_id = 123
      payment.stripe_transfer_id = "tr_1234"
      payment.mark_completed!
      payment
    end

    def humanize_date(date)
      date = Time.zone.parse(date.to_s)
      date.strftime("%B #{date.day.ordinalize}, %Y")
    end
  end

  describe "Split Payment Functionality", type: :system do
    let(:seller) { create(:named_seller) }

    before do
      allow_any_instance_of(User).to receive(:active_bank_account).and_return(nil)
      allow_any_instance_of(User).to receive(:paypal_payout_email).and_return("test@example.com")
      # Mock the authentication for the balance page
      allow_any_instance_of(ApplicationController).to receive(:current_seller).and_return(seller)
    end

    context "when user has split payments with all parts completed" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 5000, "txn_id" => "txn_1", "completed_at" => 1.day.ago },
                 { "state" => "completed", "amount_cents" => 3000, "txn_id" => "txn_2", "completed_at" => 1.day.ago }
               ])
      end

      it "displays multi-payment success message" do
        visit balance_path

        expect(page).to have_content("This payout was paid in multiple payments")
        expect(page).to have_content("$80")
        expect(page).to have_content("was paid via PayPal")
      end

      it "includes proper date formatting in the message" do
        visit balance_path

        expect(page).to have_content(1.day.ago.strftime("%B"))
        expect(page).to have_content(1.day.ago.day.ordinalize)
        expect(page).to have_content(1.day.ago.year.to_s)
      end
    end

    context "when user has split payments with partial failures" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 5000, "txn_id" => "txn_1", "completed_at" => 1.day.ago },
                 { "state" => "failed", "amount_cents" => 3000, "txn_id" => "txn_2", "failure_reason" => "insufficient_funds" }
               ])
      end

      it "displays partial payout failure message" do
        visit balance_path

        expect(page).to have_content("This payout was partially processed")
        expect(page).to have_content("$50")
        expect(page).to have_content("was successfully paid via PayPal")
        expect(page).to have_content("$30")
        expect(page).to have_content("could not be sent due to insufficient_funds")
        expect(page).to have_content("will be included in your next payout automatically")
      end

      it "includes proper status information" do
        visit balance_path

        expect(page).to have_content("This payout was partially processed")
      end
    end

    context "when user has split payments with all parts failed" do
      let!(:payment) do
        create(:payment_failed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "failed", "amount_cents" => 5000, "txn_id" => "txn_1", "failure_reason" => "insufficient_funds" },
                 { "state" => "failed", "amount_cents" => 3000, "txn_id" => "txn_2", "failure_reason" => "invalid_account" }
               ])
      end

      it "displays failed payment with enhanced error messages" do
        visit balance_path

        expect(page).to have_content("Failed")
        expect(page).to have_content("This payout failed due to insufficient_funds and other issues")
        expect(page).to have_content("This payout failed due to insufficient_funds and other issues")
      end
    end

    context "when user has split payments still processing" do
      let!(:payment) do
        create(:payment,
               user: seller,
               state: "processing",
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 5000, "txn_id" => "txn_1" },
                 { "state" => "processing", "amount_cents" => 3000, "txn_id" => "txn_2" }
               ])
      end

      it "does not show partial payout info until all payments are resolved" do
        visit balance_path

        expect(page).not_to have_content("This payout was partially processed")
        expect(page).not_to have_content("This payout was paid in multiple payments")
      end
    end

    context "when user has split payments with mixed states" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 10000, "txn_id" => "txn_1", "completed_at" => 1.day.ago },
                 { "state" => "failed", "amount_cents" => 5000, "txn_id" => "txn_2", "failure_reason" => "insufficient_funds" },
                 { "state" => "completed", "amount_cents" => 2000, "txn_id" => "txn_3", "completed_at" => 1.day.ago }
               ])
      end

      it "displays correct partial payout information with multiple completed and failed parts" do
        visit balance_path

        expect(page).to have_content("This payout was partially processed")
        expect(page).to have_content("$120") # $100 + $20 completed
        expect(page).to have_content("$50") # failed amount
        expect(page).to have_content("was successfully paid via PayPal")
        expect(page).to have_content("could not be sent due to insufficient_funds")
      end
    end

    context "when user has large split payments" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 1000000, "txn_id" => "txn_1", "completed_at" => 1.day.ago }, # $10,000
                 { "state" => "failed", "amount_cents" => 500000, "txn_id" => "txn_2", "failure_reason" => "insufficient_funds" } # $5,000
               ])
      end

      it "handles large amounts correctly in partial payout messages" do
        visit balance_path

        expect(page).to have_content("$10,000")
        expect(page).to have_content("$5,000")
        expect(page).to have_content("This payout was partially processed")
      end
    end

    context "when user has zero amount split payments" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 0, "txn_id" => "txn_1", "completed_at" => 1.day.ago },
                 { "state" => "failed", "amount_cents" => 0, "txn_id" => "txn_2", "failure_reason" => "insufficient_funds" }
               ])
      end

      it "handles zero amounts correctly" do
        visit balance_path

        expect(page).to have_content("$0")
        expect(page).to have_content("This payout was partially processed")
      end
    end

    context "when user has single split payment" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 10000, "txn_id" => "txn_1", "completed_at" => 1.day.ago }
               ])
      end

      it "handles single payment correctly in multi-payment success message" do
        visit balance_path

        expect(page).to have_content("This payout was paid in multiple payments")
        expect(page).to have_content("$100")
        expect(page).to have_content("was paid via PayPal")
      end
    end

    context "when user has split payments with different completion dates" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 5000, "txn_id" => "txn_1", "completed_at" => 2.days.ago },
                 { "state" => "completed", "amount_cents" => 3000, "txn_id" => "txn_2", "completed_at" => 1.day.ago }
               ])
      end

      it "uses the earliest completion date for multi-payment success message" do
        visit balance_path

        expect(page).to have_content("This payout was paid in multiple payments")
        expect(page).to have_content("$80")
        # Should use the earliest completion date (2 days ago)
        expect(page).to have_content(2.days.ago.strftime("%B"))
      end
    end

    context "when user has split payments without completion dates" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               created_at: 3.days.ago,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 5000, "txn_id" => "txn_1" },
                 { "state" => "completed", "amount_cents" => 3000, "txn_id" => "txn_2" }
               ])
      end

      it "falls back to payment created_at when completed_at is not available" do
        visit balance_path

        expect(page).to have_content("This payout was paid in multiple payments")
        expect(page).to have_content("$80")
        # Should use payment created_at (3 days ago)
        expect(page).to have_content(3.days.ago.strftime("%B"))
      end
    end

    context "when user has non-split payments" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: false,
               split_payments_info: nil)
      end

      it "does not show split payment messages for regular payments" do
        visit balance_path

        expect(page).not_to have_content("This payout was paid in multiple payments")
        expect(page).not_to have_content("This payout was partially processed")
      end
    end

    context "when user has split payments with nil split_payments_info" do
      let!(:payment) do
        # Create a payment and then manually set split_payments_info to nil to bypass validation
        payment = create(:payment_completed,
                        user: seller,
                        was_created_in_split_mode: false)
        payment.split_payments_info = nil
        payment.save!(validate: false)
        payment
      end

      it "does not show split payment messages when split_payments_info is nil" do
        visit balance_path

        expect(page).not_to have_content("This payout was paid in multiple payments")
        expect(page).not_to have_content("This payout was partially processed")
      end
    end

    context "when user has split payments with empty split_payments_info" do
      let!(:payment) do
        # Create a payment and then manually set split_payments_info to empty to bypass validation
        payment = create(:payment_completed,
                        user: seller,
                        was_created_in_split_mode: false)
        payment.split_payments_info = []
        payment.save!(validate: false)
        payment
      end

      it "does not show split payment messages when split_payments_info is empty" do
        visit balance_path

        expect(page).not_to have_content("This payout was paid in multiple payments")
        expect(page).not_to have_content("This payout was partially processed")
      end
    end

    context "when user has both split and regular payments" do
      let!(:split_payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 5000, "txn_id" => "txn_1", "completed_at" => 1.day.ago },
                 { "state" => "failed", "amount_cents" => 3000, "txn_id" => "txn_2", "failure_reason" => "insufficient_funds" }
               ])
      end

      let!(:regular_payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: false,
               split_payments_info: nil)
      end

      it "shows split payment messages only for split payments" do
        visit balance_path

        expect(page).to have_content("This payout was partially processed")
        # Should not show split payment messages for regular payments
      end
    end

    context "when user has multiple split payments with different scenarios" do
      let!(:successful_split_payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 5000, "txn_id" => "txn_1", "completed_at" => 1.day.ago },
                 { "state" => "completed", "amount_cents" => 3000, "txn_id" => "txn_2", "completed_at" => 1.day.ago }
               ])
      end

      let!(:partial_failure_split_payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 4000, "txn_id" => "txn_3", "completed_at" => 2.days.ago },
                 { "state" => "failed", "amount_cents" => 2000, "txn_id" => "txn_4", "failure_reason" => "invalid_account" }
               ])
      end

      it "shows appropriate messages for each split payment scenario" do
        visit balance_path

        expect(page).to have_content("This payout was paid in multiple payments")
        expect(page).to have_content("This payout was partially processed")
        expect(page).to have_content("$80") # $50 + $30 from successful split
        expect(page).to have_content("$40") # $40 from partial failure split
        expect(page).to have_content("$20") # $20 failed from partial failure split
      end
    end

    context "when user has split payments with many parts" do
      let(:split_payments_info) do
        (1..50).map do |i|
          { "state" => "completed", "amount_cents" => 1000, "txn_id" => "txn_#{i}", "completed_at" => 1.day.ago }
        end
      end

      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: split_payments_info)
      end

      it "handles large number of split payments efficiently" do
        visit balance_path

        expect(page).to have_content("This payout was paid in multiple payments")
        expect(page).to have_content("$500") # 50 * $10
      end
    end

    context "when user has split payments with mixed large and small amounts" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 1000000, "txn_id" => "txn_1", "completed_at" => 1.day.ago }, # $10,000
                 { "state" => "failed", "amount_cents" => 1, "txn_id" => "txn_2", "failure_reason" => "insufficient_funds" } # $0.01
               ])
      end

      it "handles mixed large and small amounts correctly" do
        visit balance_path

        expect(page).to have_content("$10,000")
        expect(page).to have_content("$0.01")
        expect(page).to have_content("This payout was partially processed")
      end
    end

    context "when user has split payments with whole dollar amounts" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 10000, "txn_id" => "txn_1", "completed_at" => 1.day.ago }, # $100
                 { "state" => "failed", "amount_cents" => 5000, "txn_id" => "txn_2", "failure_reason" => "insufficient_funds" } # $50
               ])
      end

      it "formats whole dollar amounts without cents" do
        visit balance_path

        expect(page).to have_content("$100")
        expect(page).to have_content("$50")
        expect(page).not_to have_content("$100.00")
        expect(page).not_to have_content("$50.00")
      end
    end

    context "when user has split payments with different date scenarios" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 5000, "txn_id" => "txn_1", "completed_at" => Date.parse("2024-11-10") },
                 { "state" => "completed", "amount_cents" => 3000, "txn_id" => "txn_2", "completed_at" => Date.parse("2024-11-10") }
               ])
      end

      it "formats dates correctly in messages" do
        visit balance_path

        expect(page).to have_content("November 10th, 2024")
      end
    end

    context "when user has split payments with fallback to payment created_at" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               created_at: Date.parse("2024-12-01"),
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 5000, "txn_id" => "txn_1" }, # no completed_at
                 { "state" => "completed", "amount_cents" => 3000, "txn_id" => "txn_2" } # no completed_at
               ])
      end

      it "falls back to payment created_at when completed_at is not available" do
        visit balance_path

        expect(page).to have_content("December 1st, 2024")
      end
    end

    context "when user has split payments with malformed data" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => "invalid", "txn_id" => "txn_1" }
               ])
      end

      it "handles malformed data gracefully" do
        visit balance_path

        # Should not crash and should render the page normally
        expect(page).not_to have_content("This payout was paid in multiple payments")
        expect(page).not_to have_content("This payout was partially processed")
      end
    end

    context "when user has split payments with missing required fields" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed" } # missing amount_cents and txn_id
               ])
      end

      it "handles missing fields gracefully" do
        visit balance_path

        # Should not crash and should render the page normally
        expect(page).not_to have_content("This payout was paid in multiple payments")
        expect(page).not_to have_content("This payout was partially processed")
      end
    end

    context "when user has split payments with nil values" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => nil, "txn_id" => "txn_1" }
               ])
      end

      it "handles nil values gracefully" do
        visit balance_path

        # Should not crash and should render the page normally
        expect(page).not_to have_content("This payout was paid in multiple payments")
        expect(page).not_to have_content("This payout was partially processed")
      end
    end

    context "when user has split payments with invalid state" do
      let!(:payment) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "invalid_state", "amount_cents" => 5000, "txn_id" => "txn_1" }
               ])
      end

      it "handles invalid states gracefully" do
        visit balance_path

        # Should not crash and should handle gracefully
      end
    end

    context "when testing message readability and consistency" do
      let!(:payment1) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 5000, "txn_id" => "txn_1", "completed_at" => 1.day.ago },
                 { "state" => "completed", "amount_cents" => 3000, "txn_id" => "txn_2", "completed_at" => 1.day.ago }
               ])
      end

      let!(:payment2) do
        create(:payment_completed,
               user: seller,
               was_created_in_split_mode: true,
               split_payments_info: [
                 { "state" => "completed", "amount_cents" => 4000, "txn_id" => "txn_3", "completed_at" => 2.days.ago },
                 { "state" => "failed", "amount_cents" => 2000, "txn_id" => "txn_4", "failure_reason" => "invalid_account" }
               ])
      end

      it "provides clear and actionable messages" do
        visit balance_path

        expect(page).to have_content("This payout was partially processed")
        expect(page).to have_content("will be included in your next payout automatically")

        # Messages should be clear about what happened and what to expect
        expect(page).to have_content("was successfully paid")
        expect(page).to have_content("could not be sent due to invalid_account")
      end

      it "maintains consistent message formatting across different scenarios" do
        visit balance_path

        # Both messages should follow the same format pattern
        expect(page).to have_content("This payout was paid in multiple payments")
        expect(page).to have_content("This payout was partially processed")

        # Both should include proper formatting
        expect(page).to have_content("$80")
        expect(page).to have_content("$40")
        expect(page).to have_content("$20")
      end
    end
  end
end
