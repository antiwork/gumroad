# frozen_string_literal: true

require "spec_helper"

describe OauthCompletionsController, :vcr do
  describe "#stripe" do
    let(:auth_uid) { "acct_1SOb0DEwFhlcVS6d" }
    let(:referer) { settings_payments_path }
    let(:user) { create(:user) }

    def set_session_data
      session[:stripe_connect_data] = {
        "auth_uid" => auth_uid,
        "referer" => referer,
        "signup" => false
      }
    end

    before do
      set_session_data
      sign_in user
    end

    context "when connecting a new Stripe account" do
      it "links to existing user account" do
        post :stripe

        expect(user.reload.stripe_connect_account).to be_present
        expect(user.stripe_connect_account.charge_processor_merchant_id).to eq(auth_uid)
        expect(flash[:notice]).to eq "You have successfully connected your Stripe account!"
        expect(response).to redirect_to settings_payments_url
      end

      it "redirects to dashboard when referer is not settings payments path" do
        session[:stripe_connect_data]["referer"] = dashboard_path

        post :stripe

        expect(response).to redirect_to dashboard_url
      end

      it "shows success message for new signups" do
        session[:stripe_connect_data]["signup"] = true

        post :stripe

        expect(flash[:notice]).to eq "You have successfully signed in with your Stripe account!"
      end

      it "allows connecting a Stripe account from Czechia" do
        session[:stripe_connect_data]["auth_uid"] = "acct_1SOk5nRHVSLfjXtK"

        post :stripe

        expect(user.reload.stripe_connect_account.country).to eq("CZ")
        expect(flash[:notice]).to eq "You have successfully connected your Stripe account!"
        expect(response).to redirect_to settings_payments_url
      end
    end

    context "when replacing a Gumroad-managed Stripe account" do
      let!(:managed_account) { create(:merchant_account, user:, charge_processor_merchant_id: "acct_managed_predecessor") }

      before do
        allow(Stripe::Account).to receive(:retrieve).with(auth_uid).and_return(
          Stripe::Account.construct_from(id: auth_uid, default_currency: "usd", country: "US")
        )
      end

      def expect_replacement_refused
        post :stripe

        expect(response).to redirect_to settings_payments_url
        expect(flash[:alert]).to eq OauthCompletionsController::UNSETTLED_BALANCE_ALERT
        expect(flash[:notice]).to be_nil
        expect(MerchantAccount.where(charge_processor_merchant_id: auth_uid)).to be_empty
        expect(user.reload.stripe_account).to eq(managed_account)
        expect(managed_account.reload).to be_active
        expect(user.check_merchant_account_is_linked).to be(false)
        expect(session[:stripe_connect_data]).to be_present
      end

      def expect_replacement_connected
        post :stripe

        expect(flash[:notice]).to eq "You have successfully connected your Stripe account!"
        expect(user.reload.stripe_connect_account.charge_processor_merchant_id).to eq(auth_uid)
        expect(user.stripe_account).to be_nil
        expect(managed_account.reload).not_to be_active
        expect(session[:stripe_connect_data]).to be_nil
      end

      {
        "a positive unpaid balance" => { state: "unpaid", amount_cents: 10_00 },
        "a negative unpaid balance" => { state: "unpaid", amount_cents: -5_00 },
        "a zero-net unpaid balance" => { state: "unpaid", amount_cents: 0 },
        "a processing balance" => { state: "processing", amount_cents: 10_00 },
      }.each do |label, attributes|
        it "refuses to connect while the managed account has #{label}" do
          balance = create(:balance, user:, merchant_account: managed_account, **attributes)

          expect_replacement_refused

          expect(balance.reload).to have_attributes(attributes)
          expect(balance.merchant_account).to eq(managed_account)
        end
      end

      %w[creating processing].each do |state|
        it "refuses to connect while a #{state} payout is against the managed account" do
          create(:payment, user:, processor: PayoutProcessorType::STRIPE, state:, stripe_connect_account_id: managed_account.charge_processor_merchant_id)

          expect_replacement_refused
        end
      end

      it "refuses to revive a retired Connect account while the managed account has unpaid funds" do
        connect_account = create(:merchant_account_stripe_connect, user:, charge_processor_merchant_id: auth_uid)
        connect_account.delete_charge_processor_account!
        create(:balance, user:, merchant_account: managed_account, amount_cents: 10_00)

        post :stripe

        expect(flash[:alert]).to eq OauthCompletionsController::UNSETTLED_BALANCE_ALERT
        expect(connect_account.reload).to be_deleted
        expect(connect_account.charge_processor_deleted_at).to be_present
        expect(user.reload.stripe_connect_account).to be_nil
        expect(managed_account.reload).to be_active
      end

      it "connects once the funds are paid out" do
        create(:balance, user:, merchant_account: managed_account, state: "paid", amount_cents: 10_00)
        create(:payment_completed, user:, processor: PayoutProcessorType::STRIPE, stripe_connect_account_id: managed_account.charge_processor_merchant_id,
                                   stripe_transfer_id: "tr_history", balances: managed_account.balances.to_a)

        expect_replacement_connected
      end

      it "connects when the managed account has no balances or payouts" do
        expect_replacement_connected
      end

      it "ignores unpaid balances held by Gumroad and by other sellers" do
        create(:balance, user:, state: "unpaid", amount_cents: 10_00)
        create(:balance, user: create(:user), state: "unpaid", amount_cents: 10_00)

        expect_replacement_connected
      end

      it "connects after a refused attempt once the balance is settled" do
        balance = create(:balance, user:, merchant_account: managed_account, amount_cents: 10_00)
        post :stripe
        expect(flash[:alert]).to eq OauthCompletionsController::UNSETTLED_BALANCE_ALERT

        balance.mark_processing!
        balance.mark_paid!
        flash.clear

        expect_replacement_connected
      end

      context "when the Stripe account is already actively linked" do
        let!(:connect_account) { create(:merchant_account_stripe_connect, user:, charge_processor_merchant_id: auth_uid) }

        before { session[:stripe_connect_data]["signup"] = true }

        def persisted_fields(merchant_account)
          merchant_account.reload.attributes.slice("deleted_at", "charge_processor_deleted_at", "charge_processor_alive_at", "json_data", "updated_at")
        end

        it "signs in and leaves a predecessor with unsettled obligations untouched" do
          create(:balance, user:, merchant_account: managed_account, amount_cents: 10_00)
          managed_before = persisted_fields(managed_account)
          connect_before = persisted_fields(connect_account)

          expect { post :stripe }.not_to change { MerchantAccount.count }

          expect(flash[:notice]).to eq "You have successfully signed in with your Stripe account!"
          expect(flash[:alert]).to be_nil
          expect(persisted_fields(managed_account)).to eq(managed_before)
          expect(managed_account).to be_active
          expect(persisted_fields(connect_account)).to eq(connect_before)
          expect(user.reload.stripe_account).to eq(managed_account)
        end

        it "signs in and leaves a settled predecessor untouched too" do
          managed_before = persisted_fields(managed_account)

          post :stripe

          expect(flash[:notice]).to eq "You have successfully signed in with your Stripe account!"
          expect(persisted_fields(managed_account)).to eq(managed_before)
          expect(managed_account).to be_active
        end
      end

      it "treats a replayed callback after a successful connection as already linked" do
        post :stripe
        connect_account = user.reload.stripe_connect_account
        set_session_data

        expect { post :stripe }.not_to change { MerchantAccount.count }

        expect(flash[:notice]).to eq "You have successfully connected your Stripe account!"
        expect(user.reload.stripe_connect_account).to eq(connect_account)
      end
    end

    context "when a team admin connects a Stripe account for a seller" do
      let(:seller) { create(:user) }
      let(:team_admin) { create(:user) }

      before do
        create(:team_membership, user: team_admin, seller:, role: TeamMembership::ROLE_ADMIN)
        cookies.encrypted[:current_seller_id] = seller.id
        sign_in team_admin
        allow(Stripe::Account).to receive(:retrieve).with(auth_uid).and_return(
          Stripe::Account.construct_from(id: auth_uid, default_currency: "usd", country: "US")
        )
      end

      it "links the Stripe account to the seller in context" do
        expect do
          post :stripe
        end.to change { seller.reload.comments.count }.by(1)

        expect(seller.reload.stripe_connect_account).to be_present
        expect(seller.stripe_connect_account.charge_processor_merchant_id).to eq(auth_uid)
        expect(seller.check_merchant_account_is_linked).to be(true)
        expect(team_admin.reload.stripe_connect_account).to be_nil
        expect(seller.comments.last).to have_attributes(
          author_id: team_admin.id,
          content: "Stripe account connected by team admin #{team_admin.email}"
        )
      end
    end

    context "when there are errors" do
      it "handles already connected Stripe accounts" do
        post :stripe
        expect(user.reload.stripe_connect_account).to be_present

        user2 = create(:user)
        sign_in user2

        set_session_data
        post :stripe

        expect(user2.stripe_connect_account).to be_nil
        expect(flash[:alert]).to eq "This Stripe account has already been linked to a Gumroad account."
        expect(response).to redirect_to settings_payments_url
      end

      it "allows connecting after original account is deleted" do
        post :stripe
        user.stripe_connect_account.delete_charge_processor_account!

        user2 = create(:user)
        sign_in user2

        set_session_data
        post :stripe

        expect(user2.reload.stripe_connect_account).to be_present
        expect(flash[:notice]).to eq "You have successfully connected your Stripe account!"
        expect(response).to redirect_to settings_payments_url
      end

      it "handles merchant account creation failures" do
        allow_any_instance_of(MerchantAccount).to receive(:save).and_return false

        post :stripe

        expect(user.stripe_connect_account).to be_nil
        expect(flash[:alert]).to eq "There was an error connecting your Stripe account with Gumroad."
        expect(response).to redirect_to settings_payments_url
      end

      it "handles invalid session data" do
        session[:stripe_connect_data] = nil

        post :stripe

        expect(flash[:alert]).to eq "Invalid OAuth session"
        expect(response).to redirect_to settings_payments_url
      end
    end

    context "when not authenticated" do
      it "requires authentication" do
        sign_out user

        post :stripe

        expect(response).to redirect_to "/login?next=%2Foauth_completions%2Fstripe"
      end
    end

    it "cleans up session data after completion" do
      post :stripe

      expect(session[:stripe_connect_data]).to be_nil
    end
  end
end
