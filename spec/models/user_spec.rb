# frozen_string_literal: true

require "spec_helper"
require "shared_examples/versionable_concern"

describe User, :vcr do
  it_behaves_like "Versionable concern", :user, {
    email: %w(old@example.com),
    payment_address: %w(old-paypal@example.com paypal@example.com)
  }

  describe "associations" do
    before :each do
      @user = create(:user)
    end

    it "has many links" do
      product = create(:product, user: @user)
      expect(@user.reload.links).to match_array [product]
    end

    it "has many purchases as a purchaser" do
      purchase = create(:purchase, purchaser: @user)
      expect(@user.reload.purchases).to match_array [purchase]
    end

    describe "affiliate associations" do
      let!(:global_affiliate) { @user.global_affiliate }
      let!(:direct_affiliate) { create(:direct_affiliate, affiliate_user: @user) }
      let(:affiliated_products) { create_list(:product, 2) }

      it "has many affiliates as a seller" do
        direct_affiliate = create(:direct_affiliate, seller: @user)
        expect(@user.reload.direct_affiliates).to match_array [direct_affiliate]
      end

      it "has one (live) global affiliate" do
        global_affiliate.mark_deleted!
        live_global_affiliate = GlobalAffiliate.new(affiliate_user: @user, affiliate_basis_points: GlobalAffiliate::AFFILIATE_BASIS_POINTS)
        live_global_affiliate.save(validate: false) # bypass uniqueness validation
        expect(@user.reload.global_affiliate).to eq live_global_affiliate
      end

      it "has many direct affiliate accounts" do
        expect(@user.reload.direct_affiliate_accounts).to match_array [direct_affiliate]
      end

      it "has many affiliate accounts" do
        expect(@user.reload.affiliate_accounts).to match_array [direct_affiliate, global_affiliate]
      end

      it "has many affiliate sales" do
        direct_purchase = create(:purchase, affiliate: direct_affiliate)
        global_purchase = create(:purchase, affiliate: global_affiliate)
        create(:purchase, affiliate: create(:direct_affiliate))

        expect(@user.affiliate_sales).to match_array [direct_purchase, global_purchase]
      end

      it "has many affiliated products" do
        direct_affiliate.products = affiliated_products
        global_affiliate.products << affiliated_products.second

        expect(@user.affiliated_products).to match_array affiliated_products
      end

      it "has many affiliated creators" do
        direct_affiliate.products = affiliated_products
        global_affiliate.products << affiliated_products.second

        expect(@user.affiliated_creators).to match_array affiliated_products.map(&:user)
      end
    end

    describe "collaborator associations" do
      it { is_expected.to have_many(:collaborators).with_foreign_key(:seller_id) }

      describe "#collaborating_products" do
        it "only contains those from collaborations the user have accepted" do
          user = create(:user)

          product1 = create(:product)
          product2 = create(:product)
          product3 = create(:product)

          accepted_collaboration = create(
            :collaborator,
            affiliate_user: user,
            seller: product1.user,
            products: [product1]
          )
          # This is a pending collaboration.
          create(
            :collaborator,
            :with_pending_invitation,
            affiliate_user: user,
            seller: product2.user,
            products: [product2]
          )
          # This is a deleted collaboration.
          create(
            :collaborator,
            affiliate_user: user,
            seller: product3.user,
            products: [product3],
            deleted_at: 1.day.ago
          )

          expect(user.accepted_alive_collaborations).to contain_exactly(accepted_collaboration)
          expect(user.collaborating_products).to contain_exactly(product1)
        end
      end
    end

    it "has_many StripeApplePayDomains" do
      record = StripeApplePayDomain.create(user: @user, domain: "sample.gumroad.com", stripe_id: "sample_stripe_id")
      expect(@user.stripe_apple_pay_domains).to match_array [record]
    end

    it "has many blocked customer objects" do
      blocked_customer_object1 = create(:blocked_customer_object, seller: @user)
      blocked_customer_object2 = create(:blocked_customer_object, object_type: "charge_processor_fingerprint", object_value: "test1234", buyer_email: "john@example.com", seller: @user, blocked_at: DateTime.current)

      expect(@user.blocked_customer_objects).to match_array([blocked_customer_object1, blocked_customer_object2])
    end

    it "has_one yearly stat" do
      yearly_stat = create(:yearly_stat, user: @user)
      expect(@user.yearly_stat).to eq yearly_stat
    end

    it "has_many utm_links" do
      utm_link = create(:utm_link, seller: @user)
      expect(@user.utm_links).to eq [utm_link]
    end

    it { is_expected.to have_many(:seller_communities).class_name("Community").with_foreign_key(:seller_id).dependent(:destroy) }
    it { is_expected.to have_many(:community_chat_messages).dependent(:destroy) }
    it { is_expected.to have_many(:last_read_community_chat_messages).dependent(:destroy) }
    it { is_expected.to have_many(:community_notification_settings).dependent(:destroy) }
    it { is_expected.to have_many(:seller_community_chat_recaps).class_name("CommunityChatRecap").with_foreign_key(:seller_id).dependent(:destroy) }
  end

  describe "scopes" do
    describe ".payment_reminder_risk_state" do
      it "selects creators that are not reviewed, flagged for TOS, or compliant" do
        not_reviewed = create(:user, user_risk_state: "not_reviewed")
        create(:user, user_risk_state: "on_probation")
        create(:user, user_risk_state: "flagged_for_fraud")
        create(:user, user_risk_state: "suspended_for_fraud")
        flagged_for_tos_violation = create(:user, user_risk_state: "flagged_for_tos_violation")
        create(:user, user_risk_state: "suspended_for_tos_violation")
        compliant = create(:user, user_risk_state: "compliant")

        expect(User.payment_reminder_risk_state).to match_array([not_reviewed, flagged_for_tos_violation, compliant])
      end
    end

    describe ".not_suspended" do
      it "selects creators that are not suspended" do
        not_reviewed = create(:user, user_risk_state: "not_reviewed")
        on_probation = create(:user, user_risk_state: "on_probation")
        flagged_for_fraud = create(:user, user_risk_state: "flagged_for_fraud")
        create(:user, user_risk_state: "suspended_for_fraud")
        flagged_for_tos_violation = create(:user, user_risk_state: "flagged_for_tos_violation")
        create(:user, user_risk_state: "suspended_for_tos_violation")
        compliant = create(:user, user_risk_state: "compliant")

        expect(User.not_suspended).to match_array([not_reviewed, on_probation, flagged_for_fraud, flagged_for_tos_violation, compliant])
      end
    end

    describe ".holding_balance_more_than" do
      before do
        @sam = create(:user)
        create(:balance, user: @sam, amount_cents: 10)
        create(:balance, user: @sam, amount_cents: 11, date: 1.day.ago)
        create(:balance, user: @sam, amount_cents: 100, date: 2.days.ago)
        create(:balance, user: @sam, amount_cents: -79, date: 3.days.ago, state: "paid")

        jill = create(:user)
        create(:balance, user: jill, amount_cents: 7)
        create(:balance, user: jill, amount_cents: 10, date: 1.day.ago)
        create(:balance, user: jill, amount_cents: 103, date: 2.days.ago)
        create(:balance, user: jill, amount_cents: 1, date: 3.days.ago, state: "paid")

        @jake = create(:user)
        create(:balance, user: @jake, amount_cents: 8)
        create(:balance, user: @jake, amount_cents: 9, date: 1.day.ago)
        create(:balance, user: @jake, amount_cents: 105, date: 2.days.ago)
        create(:balance, user: @jake, amount_cents: -53, date: 3.days.ago, state: "paid")
      end

      it "returns users who have unpaid balances more than the specified amount" do
        expect(described_class.holding_balance_more_than(120)).to match_array([@sam, @jake])
      end
    end

    describe ".holding_balance" do
      before do
        @sam = create(:user)
        create(:balance, user: @sam, amount_cents: 1)
        create(:balance, user: @sam, amount_cents: -79, date: 3.days.ago, state: "paid")

        jill = create(:user)
        create(:balance, user: jill, amount_cents: -1, date: 2.days.ago)
        create(:balance, user: jill, amount_cents: 142, date: 3.days.ago, state: "paid")

        @jake = create(:user)
        create(:balance, user: @jake, amount_cents: 12, date: 1.day.ago)
        create(:balance, user: @jake, amount_cents: -53, date: 3.days.ago, state: "paid")
      end

      it "returns users who have unpaid balances more than 0" do
        expect(described_class.holding_balance).to match_array([@sam, @jake])
      end
    end

    describe ".holding_non_zero_balance" do
      before do
        @sam = create(:user)
        create(:balance, user: @sam, amount_cents: 10)
        create(:balance, user: @sam, amount_cents: 11, date: 1.day.ago)
        create(:balance, user: @sam, amount_cents: -100, date: 2.days.ago)
        create(:balance, user: @sam, amount_cents: 79, date: 3.days.ago, state: "paid")

        jill = create(:user)
        create(:balance, user: jill, amount_cents: 20)
        create(:balance, user: jill, amount_cents: 121, date: 1.day.ago)
        create(:balance, user: jill, amount_cents: -141, date: 2.days.ago)
        create(:balance, user: jill, amount_cents: 1, date: 3.days.ago, state: "paid")

        @jake = create(:user)
        create(:balance, user: @jake, amount_cents: 20)
        create(:balance, user: @jake, amount_cents: 12, date: 1.day.ago)
        create(:balance, user: @jake, amount_cents: 21, date: 2.days.ago)
        create(:balance, user: @jake, amount_cents: -53, date: 3.days.ago, state: "paid")
      end

      it "returns users who have non-zero unpaid balances" do
        expect(described_class.holding_non_zero_balance).to match_array([@sam, @jake])
      end
    end
  end

  describe "has_cdn_url" do
    before do
      stub_const("CDN_URL_MAP", { "https://gumroad-specs.s3.amazonaws.com" => "https://public-files.gumroad.com", "https://s3.amazonaws.com/gumroad/" => "https://public-files.gumroad.com/res/gumroad/" })
    end

    describe "#subscribe_preview_url" do
      before do
        @user_with_preview = create(:user, :with_subscribe_preview)
      end

      it "returns CDN URL" do
        key = @user_with_preview.subscribe_preview.key
        expect(@user_with_preview.subscribe_preview_url).to eq("https://public-files.gumroad.com/#{key}")
      end
    end

    describe "#resized_avatar_url" do
      before do
        @user = create(:user, :with_avatar)
      end

      it "returns CDN URL" do
        variant = @user.avatar.variant(resize_to_limit: [256, 256]).processed.key
        expect(@user.resized_avatar_url(size: 256)).to match("https://public-files.gumroad.com/#{variant}")
      end
    end

    describe "#avatar_url" do
      before do
        @user = create(:user, :with_avatar)
      end

      it "returns CDN URL" do
        expect(@user.avatar_url).to match("https://public-files.gumroad.com/#{@user.avatar_variant.key}")
      end
    end

    describe "#financial_annual_report_url_for" do
      context "when no annual reports attached" do
        let(:user) { create(:user) }

        it "returns nil" do
          expect(user.financial_annual_report_url_for(year: 2022)).to eq(nil)
        end
      end

      context "when annual report does not exist for year param" do
        let(:user) { create(:user, :with_annual_report) }

        it "returns nil" do
          expect(user.financial_annual_report_url_for(year: 2011)).to eq(nil)
        end
      end

      context "when annual report exists" do
        let(:user) { create(:user, :with_annual_report) }

        it "returns report URL for the current year by default" do
          expect(user.financial_annual_report_url_for).to match("https://public-files.gumroad.com/")
        end

        context "for a previous year" do
          let(:year) { 2019 }

          it "returns report URL for the selected year" do
            blob = ActiveStorage::Blob.create_and_upload!(
              io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "followers_import.csv"), "text/csv"),
              filename: "Financial Annual Report #{year}.csv",
              metadata: { year: }
            )
            blob.analyze
            user.annual_reports.attach(blob)

            expect(user.financial_annual_report_url_for(year:)).to eq("https://public-files.gumroad.com/#{blob.key}")
          end
        end
      end
    end
  end

  describe "#display_name" do
    context "when name is present" do
      before do
        @user = create(:user, name: "Test name")
      end

      it "returns name" do
        expect(@user.display_name).to eq "Test name"
      end
    end

    context "when name is blank" do
      before do
        @user = create(:user, name: "", username: nil)
      end

      context "when 'prefer_email_over_default_username' is set to true" do
        subject(:display_name) { @user.display_name(prefer_email_over_default_username: true) }

        context "when a custom username is not set" do
          it "returns email" do
            expect(@user.username).to eq(@user.external_id)
            expect(display_name).to eq(@user.email)
          end
        end

        context "when a custom username is set" do
          before do
            @user.update!(username: "johndoe")
          end

          it "returns custom username" do
            expect(display_name).to eq("johndoe")
          end
        end
      end

      context "when 'prefer_email_over_default_username' is set to false" do
        subject(:display_name) { @user.display_name }

        context "when a custom username is not set" do
          it "returns username" do
            expect(display_name).to eq(@user.username)
          end
        end

        context "when a custom username is set" do
          before do
            @user.update!(username: "johndoe")
          end

          it "returns username" do
            expect(display_name).to eq("johndoe")
          end
        end
      end
    end
  end

  describe "#support_or_form_email" do
    let(:support_email) { "support-email@example.com" }
    let(:email) { "seller-email@example.com" }

    context "when support_email is set" do
      it "returns the support_email value" do
        user = create(:user, email:, support_email:)

        expect(user.support_or_form_email).to eq(support_email)
      end
    end

    context "when support_email is absent" do
      it "returns the email value" do
        user = create(:user, email:)

        expect(user.support_or_form_email).to eq(email)
      end
    end
  end

  describe "#has_valid_payout_info?" do
    let(:user) { create(:user) }

    it "returns true if the user has valid PayPal account info" do
      allow(PaypalPayoutProcessor).to receive(:has_valid_payout_info?).and_return(true)
      expect(user.has_valid_payout_info?).to eq true
    end

    it "returns true if the user has valid Stripe account info" do
      allow(StripePayoutProcessor).to receive(:has_valid_payout_info?).and_return(true)
      expect(user.has_valid_payout_info?).to eq true
    end

    it "returns false if the user has neither PayPal nor Stripe account info" do
      expect(user.has_valid_payout_info?).to eq false
    end
  end

  describe "merchant_account" do
    let(:user) { create(:user) }

    describe "user has no merchant accounts" do
      it "returns nil" do
        expect(user.merchant_account("charge-processor-id")).to eq(nil)
      end
    end

    describe "user has one merchant account" do
      let(:merchant_account_1) { create(:merchant_account, user:, charge_processor_id: "charge-processor-id-1") }

      before do
        merchant_account_1
      end

      it "returns the merchant account if matching charge processor id" do
        expect(user.merchant_account("charge-processor-id-1")).to eq(merchant_account_1)
      end

      it "returns nil if stripe merchant account is for cross-border payouts only and can not accept charges" do
        create(:merchant_account, user:, country: "TH")
        expect(user.merchant_account("stripe")).to be nil
      end

      it "returns the merchant account if it can accept charges" do
        merchant_account = create(:merchant_account, user:, country: "HK")
        expect(user.merchant_account("stripe")).to eq(merchant_account)
      end

      it "returns nil if not matching charge processor id" do
        expect(user.merchant_account("charge-processor-id-2")).to eq(nil)
      end
    end

    describe "user has multiple merchant accounts" do
      let(:merchant_account_1) { create(:merchant_account, user:, charge_processor_id: "charge-processor-id-1") }
      let(:merchant_account_2) { create(:merchant_account, user:, charge_processor_id: "charge-processor-id-2") }

      before do
        merchant_account_1
        merchant_account_2
      end

      it "returns the merchant account if matching charge processor id" do
        expect(user.merchant_account("charge-processor-id-1")).to eq(merchant_account_1)
        expect(user.merchant_account("charge-processor-id-2")).to eq(merchant_account_2)
      end

      it "returns nil if not matching charge processor id" do
        expect(user.merchant_account("charge-processor-id-3")).to eq(nil)
      end
    end

    describe "merchant migration enabled" do
      before do
        @creator = create(:user)
        create(:user_compliance_info, user: @creator)
        Feature.activate_user(:merchant_migration, @creator)
        @stripe_account = create(:merchant_account_stripe, user: @creator)
        @stripe_connect_account = create(:merchant_account_stripe_connect, user: @creator)
      end

      it "returns the Stripe Connect account if present and merchant migration is enabled" do
        expect(@creator.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq(@stripe_connect_account)

        Feature.deactivate_user(:merchant_migration, @creator)
        @creator.check_merchant_account_is_linked = true
        @creator.save!

        expect(@creator.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq(@stripe_connect_account)
      end

      it "returns the custom stripe merchant account if no Stripe Connect account present" do
        @stripe_connect_account.mark_deleted!
        expect(@creator.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq(@stripe_account)
      end

      it "returns the custom stripe merchant account if merchant migration is not enabled" do
        Feature.deactivate_user(:merchant_migration, @creator)
        expect(@creator.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq(@stripe_account)
      end

      it "returns nil if neither Stripe Connect nor custom stripe merchant account present" do
        @stripe_connect_account.mark_deleted!
        @stripe_account.mark_deleted!
        expect(@creator.merchant_account(StripeChargeProcessor.charge_processor_id)).to be nil
      end
    end
  end

  describe "#profile_url" do
    let(:seller) { create(:named_seller) }

    it "returns the subdomain of the user by default" do
      expect(seller.profile_url).to eq("http://seller.test.gumroad.com:31337")
    end

    context "when given a custom domain" do
      it "returns the custom domain" do
        expect(seller.profile_url(custom_domain_url: "https://example.com")).to eq("https://example.com")
      end
    end

    context "when recommended_by is specified" do
      it "adds a query parameter" do
        expect(seller.profile_url(recommended_by: "discover")).to eq("http://seller.test.gumroad.com:31337?recommended_by=discover")
        expect(seller.profile_url(custom_domain_url: "https://example.com", recommended_by: "discover")).to eq("https://example.com?recommended_by=discover")
      end
    end
  end

  describe "#subdomain_with_protocol" do
    it "returns subdomain_with_protocol of the user after converting underscores to hyphens" do
      @creator = create(:user)
      # We don't support underscores in username now, but we need to generate subdomain_with_protocol for
      # old creators who have underscores in their username.
      @creator.update_column(:username, "test_user_1")
      stub_const("ROOT_DOMAIN", "test-root.gumroad.com")
      expect(@creator.subdomain_with_protocol).to eq "http://test-user-1.test-root.gumroad.com"
    end
  end

  describe "#subdomain" do
    it "returns subdomain of the user after converting underscores to hyphens" do
      @creator = create(:user)
      # We don't support underscores in username now, but we need to generate subdomain_with_protocol for
      # old creators who have underscores in their username.
      @creator.update_column(:username, "test_user_1")
      stub_const("ROOT_DOMAIN", "test-root.gumroad.com")
      expect(@creator.subdomain).to eq "test-user-1.test-root.gumroad.com"
    end
  end

  describe ".find_by_hostname" do
    before do
      @creator_without_username = create(:user, username: nil)
      @creator_with_subdomain = create(:user, username: "john")
      @creator_with_custom_domain = create(:user, username: "jane")
      create(:custom_domain, domain: "example.com", user: @creator_with_custom_domain)

      @root_hostname = URI("#{PROTOCOL}://#{ROOT_DOMAIN}").host
    end

    it "returns nil if blank hostname provided" do
      expect(User.find_by_hostname("")).to eq(nil)
      expect(User.find_by_hostname(nil)).to eq(nil)
    end

    it "finds user by subdomain" do
      expect(User.find_by_hostname("john.#{@root_hostname}")).to eq(@creator_with_subdomain)
    end

    it "finds user by custom domain" do
      expect(User.find_by_hostname("example.com")).to eq(@creator_with_custom_domain)
    end
  end

  describe "#two_factor_authentication_enabled" do
    before do
      @user = create(:user, skip_enabling_two_factor_authentication: false)
    end

    it "sets two_factor_authentication_enabled to true by default" do
      expect(@user.two_factor_authentication_enabled).to eq true
    end
  end

  describe "#set_refund_fee_notice_shown" do
    it "sets refund_fee_notice_shown to true by default" do
      expect(create(:user).refund_fee_notice_shown?).to eq true
    end
  end

  describe "#set_refund_policy_enabled" do
    it "sets refund_policy_enabled to true by default" do
      expect(create(:user).refund_policy_enabled?).to eq true
    end

    context "when seller_refund_policy_disabled_for_all feature flag is set to true" do
      before do
        Feature.activate(:seller_refund_policy_disabled_for_all)
      end

      it "sets refund_policy_enabled to false" do
        user = create(:user)
        expect(user.refund_policy_enabled?).to eq true
        expect(user.account_level_refund_policy_enabled?).to eq false
        Feature.deactivate(:seller_refund_policy_disabled_for_all)
        expect(user.refund_policy_enabled?).to eq true
        expect(user.account_level_refund_policy_enabled?).to eq true
      end
    end

    context "when seller_refund_policy_new_users_enabled feature flag is set to true" do
      before do
        Feature.deactivate(:seller_refund_policy_new_users_enabled)
      end

      it "sets refund_policy_enabled to false" do
        expect(create(:user).refund_policy_enabled?).to eq false
      end
    end
  end

  describe "#account_level_refund_policy_enabled?" do
    let(:user) { create(:user) }

    it { expect(user.account_level_refund_policy_enabled?).to be true }

    context "with account_level_refund_policy_delayed_for_sellers feature flag" do
      before { Feature.activate_user(:account_level_refund_policy_delayed_for_sellers, user) }

      context "with time" do
        it "returns false before LAST_ALLOWED_TIME_FOR_PRODUCT_LEVEL_REFUND_POLICY" do
          travel_to(User::LAST_ALLOWED_TIME_FOR_PRODUCT_LEVEL_REFUND_POLICY) do
            expect(user.account_level_refund_policy_enabled?).to be false
          end
        end

        it "returns true after LAST_ALLOWED_TIME_FOR_PRODUCT_LEVEL_REFUND_POLICY" do
          travel_to(User::LAST_ALLOWED_TIME_FOR_PRODUCT_LEVEL_REFUND_POLICY + 1.second) do
            expect(user.account_level_refund_policy_enabled?).to be true
          end
        end
      end
    end

    context "with seller_refund_policy_disabled_for_all" do
      before { Feature.activate(:seller_refund_policy_disabled_for_all) }
      it { expect(user.account_level_refund_policy_enabled?).to be false }
    end
  end

  describe "#paypal_payout_email" do
    let(:user) { create(:user, payment_address: "payme@example.com") }

    it "returns the payment_address if it is present" do
      expect(user.paypal_payout_email).to eq "payme@example.com"

      create(:merchant_account_paypal, user:, charge_processor_merchant_id: "B66YJBBNCRW6L")
      expect(user.paypal_payout_email).to eq "payme@example.com"
    end

    it "returns the email associated with connected PayPal account if payment_address is not present" do
      expect(user.paypal_payout_email).to eq "payme@example.com"

      create(:merchant_account_paypal, user:, charge_processor_merchant_id: "B66YJBBNCRW6L")
      user.update!(payment_address: "")
      expect(user.paypal_payout_email).to eq "sb-byx2u2205460@business.example.com"
    end

    it "returns nil if neither the payment_address nor connected PayPal account are present" do
      user.update!(payment_address: "")
      expect(user.paypal_payout_email).to eq nil
    end

    it "returns nil if payment_address is blank and connected PayPal account details are not available" do
      user.update!(payment_address: "")
      create(:merchant_account_paypal, user:, charge_processor_merchant_id: "B66YJBBNCRW6L")
      allow_any_instance_of(MerchantAccount).to receive(:paypal_account_details).and_return(nil)

      expect(user.paypal_payout_email).to eq nil
    end
  end

  describe "#build_user_compliance_info" do
    before do
      @user = build(:user)
    end

    it "sets json_data of user_compliance_info to an empty json" do
      expect(@user.build_user_compliance_info.attributes["json_data"]).to eq({})
    end
  end

  describe "#deactivate!" do
    before do
      @user = create(:user)

      @user.fetch_or_build_user_compliance_info.dup_and_save! do |new_compliance_info|
        new_compliance_info.country = "United States"
      end

      @product = create(:product, user: @user)
      @installment = create(:installment, seller: @user)
      @bank_account = create(:ach_account_stripe_succeed, user: @user)
    end

    context "when user can be deactivated" do
      it "deactivates the user" do
        delete_at = Time.current

        travel_to(delete_at) do
          return_value = @user.reload.deactivate!
          expect(return_value).to be_truthy
        end

        expect(@user.reload.read_attribute(:username)).to be_nil
        expect(@user.deleted_at.to_i).to eq(delete_at.to_i)
        expect(@product.reload.deleted_at.to_i).to eq(delete_at.to_i)
        expect(@installment.reload.deleted_at.to_i).to eq(delete_at.to_i)
        expect(@user.user_compliance_infos.pluck(:deleted_at).map(&:to_i)).to eq([delete_at.to_i, delete_at.to_i])
        expect(@bank_account.reload.deleted_at.to_i).to eq(delete_at.to_i)
      end

      it "invalidates all the active sessions" do
        travel_to(DateTime.current) do
          expect do
            @user.deactivate!
          end.to change { @user.reload.last_active_sessions_invalidated_at }.from(nil).to(DateTime.current)
        end
      end

      context "when user has a saved credit card" do
        before do
          @credit_card = create(:credit_card, users: [@user])
        end

        it "clears the saved credit card information" do
          expect do
            @user.deactivate!
          end.to change { @user.reload.credit_card }.from(@credit_card).to(nil)
        end
      end

      context "when user has a custom domain" do
        before do
          @custom_domain = create(:custom_domain, user: @user)
        end

        it "marks the custom domain as deleted" do
          expect do
            @user.deactivate!
          end.to change { @custom_domain.reload.deleted_at }.from(nil).to(be_present)
        end

        it "handles deactivation when custom domain is already deleted" do
          @custom_domain.mark_deleted!
          expect { @user.deactivate! }.not_to raise_error
        end
      end

      context "when the user has active subscriptions" do
        let!(:subscription1) { create(:subscription, link: create(:membership_product), user: @user, free_trial_ends_at: 30.days.from_now) }
        let!(:subscription2) { create(:subscription, link: create(:membership_product), user: @user, free_trial_ends_at: 30.days.from_now) }

        it "cancels the active subscriptions" do
          expect do
            @user.deactivate!
          end.to change { @user.subscriptions.active_without_pending_cancel.count }.from(2).to(0)

          [subscription1, subscription2].each do |subscription|
            subscription.reload
            expect(subscription.cancelled_at).to be_present
            expect(subscription.cancelled_by_buyer).to be_truthy
          end
        end
      end
    end

    context "when user cannot be deactivated" do
      shared_examples "user is not deactivated" do
        before do
          allow(@user).to receive(:deactivate!).and_raise(User::UnpaidBalanceError).and_return(false)
          create(:subscription, link: create(:membership_product), user: @user, free_trial_ends_at: 30.days.from_now)
        end

        it "does not deactivate the user" do
          return_value = nil

          expect do
            return_value = @user.deactivate!
          end.to not_change { @user.reload.last_active_sessions_invalidated_at }
            .and not_change { @user.subscriptions.active_without_pending_cancel.count }

          @user.reload

          expect(return_value).to be_falsey
          expect(@user.read_attribute(:username)).to_not be_nil
          expect(@user.deleted_at).to be_nil
          expect(@product.reload.deleted_at).to be_nil
          expect(@installment.reload.deleted_at).to be_nil
          expect(@user.user_compliance_infos.reload.last.deleted_at).to be_nil
          expect(@bank_account.reload.deleted_at).to be_nil
        end

        context "when user has a saved credit card" do
          before do
            @credit_card = create(:credit_card, users: [@user])
          end

          it "does not clear the saved credit card information" do
            expect do
              @user.deactivate!
            end.to_not change { @user.reload.credit_card }
          end
        end
      end

      context "when user has unpaid balances" do
        before do
          create(:balance, user: @user)
        end

        include_examples "user is not deactivated"
      end

      context "when user has negative balances and the feature delete_account_forfeit_balance is active" do
        before do
          Feature.activate_user :delete_account_forfeit_balance, @user
          create(:balance, user: @user, amount_cents: -50)
        end

        include_examples "user is not deactivated"
      end

      context "when update! fails" do
        before do
          allow(@user).to receive(:update!).and_return(false)
        end

        include_examples "user is not deactivated"
      end
    end

    it "invalidates all the active sessions" do
      travel_to(DateTime.current) do
        expect do
          @user.deactivate!
        end.to change { @user.reload.last_active_sessions_invalidated_at }.from(nil).to(DateTime.current)
      end
    end
  end

  describe "validation" do
    before :each do
      @user = build(:user)
    end

    def sample_string_of_length(n)
      (1..n).map { ("a".."z").to_a.sample }.join
    end

    describe "google_analytics_id" do
      [
        { id: nil, valid: true },
        { id: "G-1234567", valid: true },
        { id: "G-2910WADW", valid: true },
        { id: "1234143WW", valid: false },
        { id: "G-<script>alert('hello')</script>-12", valid: false },
      ].each do |data|
        it "expects #{data[:id]} to be #{data[:valid] ? 'valid' : 'invalid'}" do
          user = build(:user, google_analytics_id: data[:id])
          expect(user.valid?).to eq(data[:valid])
        end
      end
    end

    describe "name" do
      it "is valid if it's blank" do
        @user.name = nil
        expect(@user).to be_valid
      end

      it "is valid if it's normal length" do
        @user.name = sample_string_of_length(25)
        expect(@user).to be_valid
      end

      it "is invalid if too long" do
        @user.name = sample_string_of_length(256)
        expect(@user).to be_invalid
      end
    end

    describe "username" do
      it "is valid if it's nil" do
        @user.username = nil
        expect(@user).to be_valid
      end

      it "is gets nilified if it's empty" do
        @user.username = ""
        expect(@user.username).to be_nil

        @user.username = " "
        expect(@user.username).to be_nil
      end

      it "is invalid if username is not unique" do
        @user.username = "gumroad"
        create(:user, username: @user.username)
        expect(@user).to be_invalid
      end

      describe "length" do
        it "is valid if it's 3 or more characters but less than 21 characters" do
          @user.username = sample_string_of_length(rand(3..19))
          expect(@user).to be_valid
        end

        it "is invalid if greater than 20 characters" do
          @user.username = sample_string_of_length(21)
          expect(@user).to be_invalid
        end

        it "is invalid ok if it's less than 3 characters" do
          @user.username = sample_string_of_length(2)
          expect(@user).to be_invalid
        end
      end

      describe "format" do
        it "doesn't allow underscore in usernames" do
          @user.username = "a_aa"
          expect(@user).to be_invalid
        end

        it "doesn't allow hyphens in usernames" do
          @user.username = "a-a"
          expect(@user).to be_invalid
        end

        it "doesn't allow usernames with only numbers" do
          @user.username = "1234"
          expect(@user).to be_invalid
        end

        it "is valid with numbers" do
          @user.username = "abc123"
          expect(@user).to be_valid
        end

        it "is invalid if japanese" do
          @user.username = "日本の"
          expect(@user).to be_invalid
        end

        it "is invalid if caps" do
          @user.username = "LOUDNOISES"
          expect(@user).to be_invalid
        end

        it "is invalid with only numbers" do
          @user.username = "12345"
          expect(@user).to be_invalid
        end

        it "is invalid if it has spaces" do
          @user.username = "a a"
          expect(@user).to be_invalid
        end
      end

      it "is invalid if it's blacklisted" do
        @user.username = DENYLIST.sample
        expect(@user).to be_invalid
      end

      describe "validation condition" do
        before do
          @user2 = create(:user)
          @user2.username = "old_style_username"
          @user2.save(validate: false)
        end

        context "when username is of old style and it isn't changed" do
          it "allows saving the user object" do
            @user2.name = "Sample name 123"

            expect(@user2.save).to eq true
          end
        end

        context "when username is changed" do
          it "enforces new username format" do
            @user2.username = "test_123"
            @user2.save

            expect(@user2.errors.full_messages.to_sentence).to include("Username has to contain at least one letter and may only contain lower case letters and numbers.")
          end
        end
      end
    end

    describe "email" do
      it "is invalid if email is required and not present" do
        @user.email = nil
        allow(@user).to receive(:email_required?).and_return(true)
        expect(@user).to be_invalid
      end

      it "is invalid if email is not in email format" do
        @user.email = "invalid"
        expect(@user).to be_invalid
      end

      it "is invalid if email address starts with a ." do
        @user.email = ".blah@blah.com"
        expect(@user).to be_invalid
      end

      it "is invalid if email address has whitespace in it" do
        @user.email = "bla\th@blah.com"
        expect(@user).to be_invalid
      end

      it "is valid if email address is correct" do
        @user.email = "blah@blah.com"
        expect(@user).to be_valid
      end

      it "is valid if email address has a dash" do
        @user.email = "blah-blah@blah.com"
        expect(@user).to be_valid
      end

      it "is valid if email address has an underscore" do
        @user.email = "blah_blah@blah.com"
        expect(@user).to be_valid
      end

      it "is valid if email address domain is IP" do
        @user.email = "blah@[192.0.0.1]"
        expect(@user).to be_valid
      end

      it "is valid if email has 255 characters" do
        @user.email = "a" * 249 + "@b.com"
        expect(@user).to be_valid
      end

      it "is invalid if email has more than 255 characters" do
        @user.email = "a" * 250 + "@b.com"
        expect(@user).to be_invalid
      end
    end

    describe "kindle_email" do
      it "is valid if kindle_email is blank" do
        @user.kindle_email = nil
        expect(@user).to be_valid
        @user.kindle_email = ""
        expect(@user).to be_valid
      end

      it "is invalid if kindle_email is not an email address" do
        @user.kindle_email = "invalid"
        expect(@user).to be_invalid
      end

      it "is invalid if kindle_email address starts with a ." do
        @user.kindle_email = ".blah@kindle.com"
        expect(@user).to be_invalid
      end

      it "is invalid if kindle_email address has whitespace in it" do
        @user.kindle_email = "bla\th@kindle.com"
        expect(@user).to be_invalid
      end

      it "is valid if kindle_email is correct email address but does not end in @kindle.com" do
        @user.kindle_email = "blah@blah.com"
        expect(@user).to be_invalid
      end

      it "is valid if kindle_email is correct" do
        @user.kindle_email = "blah@kindle.com"
        expect(@user).to be_valid
      end

      it "is valid if kindle_email has a dash" do
        @user.kindle_email = "blah-blah@kindle.com"
        expect(@user).to be_valid
      end

      it "is valid if kindle_email has an underscore" do
        @user.kindle_email = "blah_blah@kindle.com"
        expect(@user).to be_valid
      end

      it "is valid if kindle_email uses different cases" do
        @user.kindle_email = "ExAmple123@KINDLE.com"
        expect(@user).to be_valid
      end

      it "is valid if kindle_email does not have more than 255 characters" do
        @user.kindle_email = "a" * 244 + "@kindle.com"
        expect(@user).to be_valid
      end

      it "is invalid if kindle_email has more than 255 characters" do
        @user.kindle_email = "a" * 245 + "@kindle.com"
        expect(@user).to be_invalid
      end
    end

    describe "password" do
      describe "presence" do
        it "is invalid if it is not present and password is required" do
          @user.password = nil
          allow(@user).to receive(:password_required?).and_return(true)
          expect(@user).to be_invalid
        end

        it "is valid if it is not present and password is not required" do
          allow(@user).to receive(:password_required?).and_return(false)
          @user.password = nil
          expect(@user).to be_valid
        end
      end

      describe "confirmation" do
        before :each do
          @user.password = "password"
        end

        it "is invalid if confirmation does not match and password is required" do
          @user.password_confirmation = @user.password + "typo"
          allow(@user).to receive(:password_required?).and_return(true)
          expect(@user).to be_invalid
        end

        it "is valid if confirmation does not match and password is not required" do
          @user.password_confirmation = @user.password + "typo"
          allow(@user).to receive(:password_required?).and_return(false)
          expect(@user).to be_valid
        end
      end

      describe "length" do
        it "is valid if it's 6 or more characters but less than 128 characters" do
          @user.password = sample_string_of_length(rand(6..127))
          expect(@user).to be_valid
        end

        it "is invalid if greater than 128 characters" do
          @user.password = sample_string_of_length(129)
          expect(@user).to be_invalid
        end

        it "is invalid if it's less than 4 characters" do
          @user.password = sample_string_of_length(3)
          expect(@user).to be_invalid
        end
      end
    end

    describe "locale" do
      it "is valid if it's null" do
        @user.locale = nil
        expect(@user).to be_valid
      end

      it "is valid if it's available" do
        @user.locale = "en"
        expect(@user).to be_valid
      end
    end

    describe "currency type" do
      it "is valid if currency type is in valid currencies" do
        @user.currency_type = "usd"
        expect(@user).to be_valid
      end

      it "is invalid if currency type is not in valid currencies" do
        @user.currency_type = "lol"
        expect(@user).to be_invalid
      end
    end

    describe "#subscribe_preview_url" do
      context "when user doesn't have a subscribe preview" do
        it "returns nil" do
          expect(@user.subscribe_preview_url).to eq(nil)
        end
      end

      context "when user has a subscribe preview" do
        before do
          @user_with_preview = create(:user, :with_subscribe_preview)
        end

        it "returns URL to user's subscribe preview" do
          key = @user_with_preview.subscribe_preview.key
          expect(@user_with_preview.subscribe_preview_url).to match("https://gumroad-specs.s3.amazonaws.com/#{key}")
        end
      end
    end

    describe "#resized_avatar_url" do
      context "when user doesn't have an avatar" do
        it "returns URL to default avatar" do
          expect(@user.resized_avatar_url(size: 256)).to eq(ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"))
        end
      end

      context "when user has an avatar" do
        before do
          @user_with_avatar = create(:user, :with_avatar)
        end

        it "returns URL to user's avatar" do
          variant = @user_with_avatar.avatar.variant(resize_to_limit: [256, 256]).processed.key
          expect(@user_with_avatar.resized_avatar_url(size: 256)).to match("https://gumroad-specs.s3.amazonaws.com/#{variant}")
        end
      end
    end

    describe "avatar_url" do
      it "allows avatar to be nil" do
        expect(@user.avatar.attached?).to be(false)
        expect(@user).to be_valid
      end

      context "when user doesn't have an avatar" do
        it "returns URL to default avatar" do
          expect(@user.avatar_url).to eq(ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"))
        end
      end

      context "when user has an avatar" do
        before do
          @user_with_avatar = create(:user, :with_avatar)
        end

        it "returns URL to user's avatar" do
          expect(@user_with_avatar.avatar_url).to match("https://gumroad-specs.s3.amazonaws.com/#{@user_with_avatar.avatar_variant.key}")
        end
      end

      it "validates the uploaded avatar file's extension" do
        user = create(:named_user, :with_avatar)

        expect(user).to be_valid
      end

      it "fails the validation when uploaded profile picture is too heavy" do
        stub_const("User::Validations::MAXIMUM_AVATAR_FILE_SIZE", 2.megabytes)
        blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("error_file.jpeg", "image/jpeg"), filename: "error_file.jpeg")
        @user.avatar.attach(blob)

        @user.validate
        expect(@user.errors[:base]).to eq ["Please upload a profile picture with a size smaller than 2 MB"]
      end

      it "fails the validation when uploaded profile picture is of unsupported filetype" do
        blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("thing.mov", "video/quicktime"), filename: "thing.mov")
        blob.analyze
        @user.avatar.attach(blob)

        @user.validate
        expect(@user.errors[:base]).to eq ["Please upload a profile picture with one of the following extensions: png, jpg, jpeg."]
      end

      it "fails validation when the uploaded profile picture is smaller than 200x200px" do
        blob = ActiveStorage::Blob.create_and_upload!(io: File.open("#{Rails.root}/spec/support/fixtures/test-small.png"), filename: "test-small.png")
        @user.avatar.attach(blob)

        @user.validate
        expect(@user.errors[:base]).to eq ["Please upload a profile picture that is at least 200x200px"]
      end

      it "doesn't fail validation when an existing profile picture is smaller than 200x200px" do
        @user.avatar.attach(io: File.open("#{Rails.root}/spec/support/fixtures/test-small.png"), filename: "test-small.png")

        expect(@user.validate).to eq(true)
        expect(@user.errors[:base]).to be_empty
      end

      it "returns original file url for files with conversion issues" do
        blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
        blob.analyze
        @user.avatar.attach(blob)

        expect(@user).to receive(:avatar_variant).and_raise(MiniMagick::Error)

        expect(@user.avatar_url).to match(@user.avatar.url)
      end
    end

    describe "account_created_email_domain_is_not_blocked validation" do
      context "when the email domain is blocked" do
        before do
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email_domain], "example.com", nil)
        end

        it "fails the validation" do
          @user.email = "john@example.com"
          expect(@user).to be_invalid

          @user.validate
          expect(@user.errors[:base]).to eq ["Something went wrong."]
        end

        after do
          BlockedObject.find_active_object("example.com").unblock!
        end
      end

      context "when the email domain is not blocked" do
        it "validates the user successfully" do
          expect(BlockedObject.find_active_object("example.com")).to be_nil
          @user.account_created_ip = "example.com"

          expect(@user).to be_valid
        end
      end

      context "when the email is not valid" do
        it "returns is invalid error" do
          @user.email = "john\tdoe@example.com"
          @user.validate
          expect(@user.errors[:email]).to eq ["is invalid"]
        end
      end
    end

    describe "account_created_ip" do
      context "when the IP is blocked" do
        before do
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "127.0.0.1", nil, expires_in: 1.hour)
        end

        it "fails the validation" do
          @user.account_created_ip = "127.0.0.1"
          expect(@user).to be_invalid

          @user.validate
          expect(@user.errors[:base]).to eq ["Something went wrong."]
        end

        after do
          BlockedObject.find_active_object("127.0.0.1").unblock!
        end
      end

      context "when the IP is not blocked" do
        it "validates the user successfully" do
          @user.account_created_ip = "127.0.0.1"

          expect(@user).to be_valid
        end
      end

      context "when the IP is not set" do
        it "validates the user successfully" do
          @user.account_created_ip = nil

          expect(@user).to be_valid
        end
      end
    end

    describe "facebook_meta_tag" do
      it "allows facebook_meta_tag to be nil" do
        @user.facebook_meta_tag = nil
        expect(@user).to be_valid
      end

      it "validates facebook_meta_tag length is less than or equal to 100" do
        @user.facebook_meta_tag = '<meta name="facebook-domain-verification" content="y5fgkbh7x91y5tnt6yt3sttk" />'
        expect(@user.facebook_meta_tag.length).to be <= 100
        expect(@user).to be_valid
      end

      it "validates the facebook_meta_tag has the correct format" do
        @user.facebook_meta_tag = '<meta name="facebook-domain-verification" content="y5fgkbh7x91y5tnt6yt3sttk" />'
        expect(@user).to be_valid
      end

      it "fails the validation when facebook_meta_tag is invalid" do
        @user.facebook_meta_tag = '<script>var x = 1</script><meta name="facebook-domain-verification" content="y5fgkbh7x91y5tnt6yt3sttk" />'
        @user.save
        expect(@user).to be_invalid
        expect(@user.errors[:base]).to eq ["Please enter a valid meta tag"]

        @user.facebook_meta_tag = '<meta name="facebook-domain-verification" content=""><script>malicious</script>" />'
        @user.save
        expect(@user).to be_invalid
        expect(@user.errors[:base]).to eq ["Please enter a valid meta tag"]
      end
    end

    describe "#support_email_domain_is_not_reserved" do
      it "allows support_email to be nil" do
        @user.support_email = nil
        expect(@user).to be_valid
      end

      it "fails the validation when domain is reserved" do
        @user.support_email = "something@gumroad.com"
        expect(@user).to be_invalid
        expect(@user.errors[:base]).to eq ["Sorry, that support email is reserved. Please use another email."]
      end
    end

    describe "custom_fee_per_thousand" do
      it "allows nil and an integer between 0 and 1000" do
        user = build(:user, custom_fee_per_thousand: nil)
        expect(user).to be_valid

        user.custom_fee_per_thousand = 100.5
        expect(user).to be_invalid
        expect(user.errors[:custom_fee_per_thousand]).to eq ["must be an integer"]

        user.custom_fee_per_thousand = -1
        expect(user).to be_invalid
        expect(user.errors[:custom_fee_per_thousand]).to eq ["must be greater than or equal to 0"]

        user.custom_fee_per_thousand = 1001
        expect(user).to be_invalid
        expect(user.errors[:custom_fee_per_thousand]).to eq ["must be less than or equal to 1000"]

        user.custom_fee_per_thousand = "abc"
        expect(user).to be_invalid
        expect(user.errors[:custom_fee_per_thousand]).to eq ["is not a number"]

        [0, 50, 100, 500, 750, 1000].each do |value|
          user.custom_fee_per_thousand = value
          expect(user).to be_valid
        end
      end
    end
  end

  describe "user roles" do
    it "is considered an affiliate if it is present in the affiliates table" do
      @user = create(:user)
      create(:direct_affiliate, affiliate_user_id: @user.id)

      expect(@user.is_affiliate?).to eq true
    end

    it "is not considered an affiliate if it is not present in the affiliates table" do
      @user = create(:user)

      expect(@user.is_affiliate?).to eq false
    end
  end

  describe "#account_active?" do
    it "returns true for a live user" do
      user = build(:user)

      expect(user.account_active?).to eq true
    end

    it "returns false for a deleted user" do
      user = build(:user, deleted_at: 1.minute.ago)

      expect(user.account_active?).to eq false
    end

    it "returns false for a suspended user" do
      user = create(:user)
      admin = create(:admin_user)
      user.flag_for_fraud!(author_id: admin.id)
      user.suspend_for_fraud!(author_id: admin.id)

      expect(user.account_active?).to eq false
    end
  end

  describe "#user_info" do
    subject(:user_info) { user.user_info(creator) }

    let(:user) { create(:named_user) }
    let(:creator) { create(:named_user) }

    describe "returned keys" do
      it "returns the right top-level keys" do
        expect(user_info.keys).to contain_exactly(*%i[email full_name profile_picture_url shipping_information card admin])
      end

      it "returns the right keys for :shipping_information" do
        expect(user_info[:shipping_information].keys).to contain_exactly(*%i[street_address zip_code state country city])
      end
    end

    it "returns the right values" do
      expect(user_info)
        .to match(
          email: user.form_email,
          full_name: user.name,
          profile_picture_url: user.avatar_url,
          shipping_information: {
            street_address: user.street_address,
            zip_code: user.zip_code,
            state: user.state,
            country: user.country,
            city: user.city
          },
          card: user.credit_card_info(creator),
          admin: user.is_team_member?,
        )
    end
  end

  describe "email" do
    it "does not allow same email address" do
      user = create(:user)
      expect(build(:user, email: user.email).save).to be(false)
    end

    it "does not have unconfirmed_email if all emails have been confirmed" do
      user = create(:user)
      email = "user1234@gumroad.com"
      user.update_attribute(:email, email)

      expect do
        user.confirm
      end.to change { user.unconfirmed_email }.from(email).to(nil)
    end
  end

  describe "append http" do
    it "appends an http to notification_endpoint" do
      user = create(:user)
      user.notification_endpoint = "www.google.com"
      user.save
      user.reload.notification_endpoint = "http://www.google.com"
    end
  end

  describe "valid_password?" do
    it "can check a user's password" do
      user = build(:user, password: "password")
      expect(user).to be_valid_password("password")
      expect(user).to_not be_valid_password("INVALD")
    end
  end

  describe "#clear_products_cache" do
    before do
      @user = create(:user)
      @product_1 = create(:product, user: @user)
      @product_2 = create(:product, user: @user, custom_permalink: "blah")
    end

    describe "callback triggering behavior" do
      it "is called automatically after update if any of `User::LINK_PROPERTIES` are changed" do
        expect(@user).to receive(:clear_products_cache)

        @user.facebook_pixel_id = "123"
        @user.save!
      end

      it "isn't called if an attribute not included in `User::LINK_PROPERTIES` is changed" do
        expect(@user).not_to receive(:clear_products_cache)

        @user.email = generate(:email)
        @user.save!
      end
    end

    it "queues product caching invalidation worker for all user products" do
      expect(InvalidateProductCacheWorker).to receive(:perform_bulk).with([[@product_1.id], [@product_2.id]])
      @user.clear_products_cache
    end
  end

  describe "#credit_card_info" do
    let(:user) { create(:user) }
    let(:link) { create(:product) }
    let(:credit_card) { create(:credit_card) }

    it "appends zero to date if expiry month is smaller than 10" do
      allow(user).to receive(:credit_card).and_return(credit_card)
      allow(credit_card).to receive(:expiry_month).and_return(9)
      user.credit_card_info(link.user)[:date].first == "0"
    end

    it "doesn't append zero to date if expiry month is not smaller than 10" do
      allow(user).to receive(:credit_card).and_return(credit_card)
      allow(credit_card).to receive(:expiry_month).and_return(10)
      user.credit_card_info(link.user)[:date].first == "1"
    end

    it "returns test credit card if user is the seller" do
      allow(link).to receive(:user).and_return(user)
      expect(user.credit_card_info(link.user)[:credit]).to eq "test"
    end

    it "returns saved credit card if user has saved a credit card" do
      allow(user).to receive(:credit_card).and_return(credit_card)
      expect(user.credit_card_info(link.user)[:credit]).to eq "saved"
    end

    it "returns new credit card if user is not the seller and hasn't saved a credit card" do
      allow(user).to receive(:credit_card).and_return(nil)
      expect(user.credit_card_info(link.user)[:credit]).to eq "new"
    end
  end

  describe "user risk state machine" do
    before do
      @user = create(:user, payment_address: "sameuser@gmail.com", last_sign_in_ip: "10.2.2.2")
      @product_1 = create(:product, user: @user)
      @product_2 = create(:product, user: @user)

      @admin_user = create(:user)
    end

    it "does not suspend the user if the user is verified" do
      @user.update_attribute(:verified, true)
      expect(@user.suspend_for_fraud(author_id: @admin_user.id)).to be(false)
    end

    it "does not flag the user if the user is verified" do
      @user.update_attribute(:verified, true)
      expect(@user.flag_for_fraud(author_id: @admin_user.id)).to be(false)
      expect(@user.flag_for_tos_violation(author_id: @admin_user.id, product_id: @product_1.id)).to be(false)
    end

    it "suspends the user if the user is not verified, and was previously flagged for fraud" do
      @user.flag_for_fraud!(author_id: @admin_user.id)
      expect(@user.suspend_for_fraud!(author_id: @admin_user.id)).to be(true)
    end

    it "is expected to call invalidate_active_sessions! if user is suspended_for_fraud" do
      expect(@user).to receive(:invalidate_active_sessions!)

      @user.flag_for_fraud!(author_id: @admin_user.id)
      @user.suspend_for_fraud!(author_id: @admin_user.id)
    end

    it "is expected to call invalidate_active_sessions! if user is suspended_for_tos_violation" do
      expect(@user).to receive(:invalidate_active_sessions!)

      @user.flag_for_tos_violation(author_id: @admin_user.id, product_id: @product_1.id)
      @user.suspend_for_tos_violation(author_id: @admin_user.id)
    end

    it "blocks seller ip" do
      expect(@user).to receive(:block_seller_ip!)
      @user.flag_for_fraud(author_id: @admin_user.id)
      @user.suspend_for_fraud(author_id: @admin_user.id)
    end

    context "when user has a custom domain" do
      before do
        @custom_domain = create(:custom_domain, user: @user)
      end

      it "marks custom domain as deleted when suspended for fraud" do
        @user.flag_for_fraud!(author_id: @admin_user.id)

        expect do
          @user.suspend_for_fraud!(author_id: @admin_user.id)
        end.to change { @custom_domain.reload.deleted_at }.from(nil).to(be_present)
      end

      it "marks custom domain as deleted when suspended for TOS violation" do
        @user.flag_for_tos_violation!(author_id: @admin_user.id, product_id: @product_1.id)

        expect do
          @user.suspend_for_tos_violation!(author_id: @admin_user.id)
        end.to change { @custom_domain.reload.deleted_at }.from(nil).to(be_present)
      end

      it "handles suspension when custom domain is already deleted" do
        @custom_domain.mark_deleted!
        @user.flag_for_fraud!(author_id: @admin_user.id)

        expect { @user.suspend_for_fraud!(author_id: @admin_user.id) }.not_to raise_error
      end

      it "handles suspension when user has no custom domain" do
        @custom_domain.destroy!
        @user.flag_for_fraud!(author_id: @admin_user.id)

        expect { @user.suspend_for_fraud!(author_id: @admin_user.id) }.not_to raise_error
      end
    end

    it "adds a comment when flagging for TOS violation" do
      expect do
        @user.flag_for_tos_violation!(author_id: @admin_user.id, product_id: @product_1.id)
      end.to change { @product_1.comments.reload.count }.by(1)

      expect(@product_1.comments.last.author_id).to eq(@admin_user.id)
    end

    it "does not add a comment for bulk flagging for TOS violation" do
      expect do
        @user.flag_for_tos_violation!(author_id: @admin_user.id, bulk: true)
      end.to_not change { @product_1.comments.reload.count }
    end

    it "logs the timestamp to mongo on flagging" do
      @user.update_attribute(:tos_violation_reason, "bad content")
      @user.flag_for_tos_violation!(author_id: @admin_user.id, product_id: @product_1.id)

      expect(SaveToMongoWorker).to have_enqueued_sidekiq_job(anything, anything)
    end

    it "logs the timestamp to mongo on suspension" do
      @user.flag_for_fraud!(author_id: @admin_user.id)

      expect(SaveToMongoWorker).to have_enqueued_sidekiq_job(anything, anything)
    end

    describe "seller with multiple accounts" do
      before do
        @user_2 = create(:user, payment_address: "sameuser@gmail.com")
        @product_3 = create(:product, user: @user_2)
        @product_4 = create(:product, user: @user_2)
      end

      it "disables all the sellers links if the user is suspended" do
        @user_2.mark_compliant(author_id: @admin_user.id)
        @user_2.flag_for_tos_violation(author_id: @admin_user.id, product_id: @product_3.id)
        @user_2.suspend_for_tos_violation(author_id: @admin_user.id)
        expect(@product_3.reload.banned_at).to_not be(nil)
        expect(@product_4.reload.banned_at).to_not be(nil)

        @user.flag_for_fraud(author_id: @admin_user.id)
        @user.suspend_for_fraud(author_id: @admin_user.id)
        expect(@product_1.reload.banned_at).to_not be(nil)
        expect(@product_2.reload.banned_at).to_not be(nil)
      end

      it "reenables old links if the user is moved to probation" do
        @user_2.mark_compliant(author_id: @admin_user.id)
        @user_2.flag_for_tos_violation(author_id: @admin_user.id, product_id: @product_3.id)
        @user_2.suspend_for_tos_violation(author_id: @admin_user.id)
        expect(@product_3.reload.banned_at).to_not be(nil)
        expect(@product_4.reload.banned_at).to_not be(nil)

        @user.flag_for_fraud(author_id: @admin_user.id)
        @user.suspend_for_fraud(author_id: @admin_user.id)
        expect(@product_1.reload.banned_at).to_not be(nil)
        expect(@product_2.reload.banned_at).to_not be(nil)
        @user.put_on_probation(author_id: @admin_user.id)
        expect(@user.on_probation?).to be(true)
        expect(@product_1.reload.banned_at).to be(nil)
      end

      it "suspends all the others sellers accounts if suspended for fraud" do
        expect(@user).to receive(:suspend_sellers_other_accounts)
        @user.flag_for_fraud(author_id: @admin_user.id)
        @user.suspend_for_fraud(author_id: @admin_user.id)
      end

      it "does not suspend all the others sellers accounts if suspended for tos violation" do
        @user.flag_for_tos_violation(author_id: @admin_user.id, product_id: @product_1.id)
        @user.suspend_for_tos_violation(author_id: @admin_user.id)
        expect(@user_2.reload.suspended?).to be(false)
      end

      it "re-enables all the sellers related accounts if the seller is marked compliant" do
        @user_2.flag_for_fraud(author_id: @admin_user.id)
        @user_2.suspend_for_fraud(author_id: @admin_user.id)
        @user.flag_for_fraud(author_id: @admin_user.id)
        @user.suspend_for_fraud(author_id: @admin_user.id)
        expect(@user_2.reload.suspended?).to be(true)

        @user.mark_compliant(author_id: @admin_user.id)
        expect(@user_2.reload.suspended?).to be(false)
      end

      it "re-enables all the sellers links if the seller is marked compliant" do
        @user.flag_for_fraud!(author_id: @admin_user.id)
        @user.suspend_for_fraud(author_id: @admin_user.id)
        expect(@product_1.reload.banned_at).to_not be(nil)
        expect(@product_2.reload.banned_at).to_not be(nil)

        @user.mark_compliant(author_id: @admin_user.id)
        expect(@product_1.reload.banned_at).to be(nil)
        expect(@product_2.reload.banned_at).to be(nil)
      end
    end

    context "when suspended user's risk_state is updated" do
      before do
        @user.flag_for_fraud(author_id: @admin_user.id)
        @user.suspend_for_fraud(author_id: @admin_user.id)
        CreateStripeApplePayDomainWorker.jobs.clear
      end

      it "adds user's subdomain to stripe_apple_pay_domains when marked compliant" do
        @user.mark_compliant(author_id: @admin_user.id)
        expect(CreateStripeApplePayDomainWorker).to have_enqueued_sidekiq_job(@user.id)
      end
    end
  end

  describe "purchasing_power_parity_limit" do
    let (:user) { create(:user) }

    describe "attempting to set limit between 1-100" do
      it "does not throw" do
        expect { user.update!(purchasing_power_parity_limit: 40) }.to_not raise_error
      end
    end

    describe "attempting to set limit below 1" do
      it "throws an error" do
        expect { user.update!(purchasing_power_parity_limit: 0) }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    describe "attempting to set limit above 100" do
      it "throws an error" do
        expect { user.update!(purchasing_power_parity_limit: 101) }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  describe "min_ppp_factor" do
    describe "no limit set" do
      let(:user) { create(:user) }
      it "returns 0" do
        expect(user.min_ppp_factor).to eq(0)
      end
    end

    describe "limit set" do
      let(:user) { create(:user, purchasing_power_parity_limit: 40) }
      it "returns the inverse limit as a decimal percentage" do
        expect(user.min_ppp_factor).to eq(0.6)
      end
    end
  end

  describe "max_product_price" do
    describe "not verified" do
      let(:user) { create(:user) }
      it "returns the default maximum product price" do
        expect(user.max_product_price).to eq(User::MAX_PRICE_USD_CENTS_UNLESS_VERIFIED)
      end
    end
    describe "verified" do
      let(:user) { create(:user, verified: true) }

      it "returns nil, as the max product price is unlimited" do
        expect(user.max_product_price).to be_nil
      end
    end
  end

  describe "json_data" do
    before do
      @user = create(:user)
    end

    it "is valid with an empty hash" do
      @user.json_data = {}
      expect(@user).to be_valid
    end

    it "understands nil to be an empty hash" do
      @user.json_data = nil
      expect(@user).to be_valid
    end

    it "accepts a key, value pair" do
      @user.json_data[:fizz] = "buzz"
      expect(@user).to be_valid
    end

    it "is still valid when a key is set to an empty value" do
      @user.json_data[:some_key] = nil
      expect(@user).to be_valid
    end

    it "is never anything but a hash" do
      @user.json_data = "some string"
      expect { @user.valid? }.to raise_error("json_data must be a hash")
      @user.json_data = [1, 2, 3, 4]
      expect { @user.valid? }.to raise_error("json_data must be a hash")
    end
  end

  describe "Australia tax period" do
    before do
      @user = create(:user)
    end

    it "supports total sales in Australia tax period" do
      expect(@user).to respond_to(:au_backtax_sales_cents)
      @user.au_backtax_sales_cents = 100_00
      @user.save!
      expect(@user.reload.au_backtax_sales_cents).to eq(100_00)
    end

    it "supports total owed in Australia tax period" do
      expect(@user).to respond_to(:au_backtax_owed_cents)
      @user.au_backtax_owed_cents = 909
      @user.save!
      expect(@user.reload.au_backtax_owed_cents).to eq(909)
    end
  end

  describe "#save_gumroad_day_timezone" do
    let!(:seller) { create(:user) }

    it "does nothing and returns if waive_gumroad_fee_on_new_sales? is false" do
      expect(seller.waive_gumroad_fee_on_new_sales?).to be false
      expect(seller.timezone).to eq("Pacific Time (US & Canada)")
      expect(seller.gumroad_day_timezone).to be nil

      seller.save_gumroad_day_timezone

      expect(seller.reload.gumroad_day_timezone).to be nil
    end

    it "saves the seller's current timezone as gumroad_day_timezone" do
      Feature.activate_user(:waive_gumroad_fee_on_new_sales, seller)
      expect(seller.waive_gumroad_fee_on_new_sales?).to be true

      expect(seller.timezone).to eq("Pacific Time (US & Canada)")
      expect(seller.gumroad_day_timezone).to be nil

      seller.save_gumroad_day_timezone

      expect(seller.reload.gumroad_day_timezone).to eq("Pacific Time (US & Canada)")
    end

    it "does not overwrite the gumroad_day_timezone if it's already set" do
      Feature.activate_user(:waive_gumroad_fee_on_new_sales, seller)
      expect(seller.waive_gumroad_fee_on_new_sales?).to be true

      expect(seller.timezone).to eq("Pacific Time (US & Canada)")
      expect(seller.gumroad_day_timezone).to be nil

      seller.save_gumroad_day_timezone

      expect(seller.reload.gumroad_day_timezone).to eq("Pacific Time (US & Canada)")

      seller.update!(timezone: "Eastern Time (US & Canada)")
      expect(seller.reload.timezone).to eq "Eastern Time (US & Canada)"

      seller.save_gumroad_day_timezone
      expect(seller.reload.gumroad_day_timezone).to eq("Pacific Time (US & Canada)")
    end
  end

  describe "#gumroad_day_saved_fee_cents" do
    it "returns 0 if no new paid sales made by seller on Gumroad Day" do
      seller_with_no_sales = create(:user)
      expect(seller_with_no_sales.gumroad_day_saved_fee_cents).to eq(0)

      seller_with_no_paid_sales = create(:user, gumroad_day_timezone: "Pacific Time (US & Canada)")
      create(:free_purchase,
             link: create(:product, user: seller_with_no_paid_sales),
             created_at: DateTime.new(2024, 4, 4, 12, 0, 0, "-07:00"))
      expect(seller_with_no_paid_sales.gumroad_day_saved_fee_cents).to eq(0)
    end

    it "returns 10% of the new sales volume made by seller on Gumroad Day" do
      seller = create(:user, gumroad_day_timezone: "Pacific Time (US & Canada)")

      membership_product = create(:subscription_product, user: seller)

      # Sales made before Gumroad Day
      create(:purchase,
             price_cents: 100_00,
             link: create(:product, user: seller),
             created_at: DateTime.new(2024, 4, 3, 23, 0, 0, "-07:00"))

      # Gumroad Day sales
      create(:purchase,
             price_cents: 100_00,
             link: create(:product, user: seller),
             created_at: DateTime.new(2024, 4, 4, 1, 0, 0, "-07:00"))
      create(:purchase,
             price_cents: 206_20,
             link: create(:product, user: seller),
             created_at: DateTime.new(2024, 4, 4, 12, 0, 0, "-07:00"))
      create(:membership_purchase,
             price_cents: 100_00,
             subscription: create(:subscription, link: membership_product),
             link: membership_product,
             is_original_subscription_purchase: true,
             created_at: DateTime.new(2024, 4, 4, 1, 0, 0, "-07:00"))
      create(:membership_purchase, # Recurring charge not counted towards saved fee
             price_cents: 100_00,
             subscription: Subscription.last,
             link: membership_product,
             is_original_subscription_purchase: false,
             created_at: DateTime.new(2024, 4, 4, 23, 0, 0, "-07:00"))

      # Sales made after Gumroad Day
      create(:purchase,
             price_cents: 100_00,
             link: create(:product, user: seller),
             created_at: DateTime.new(2024, 4, 5, 1, 0, 0, "-07:00"))

      expect(seller.gumroad_day_saved_fee_cents).to eq(40_62)
    end
  end

  describe "#gumroad_day_saved_fee_amount" do
    it "returns nil if gumroad_day_saved_fee_cents is 0" do
      seller_with_no_sales = create(:user)
      expect(seller_with_no_sales.gumroad_day_saved_fee_cents).to eq(0)
      expect(seller_with_no_sales.gumroad_day_saved_fee_amount).to be nil

      seller_with_no_paid_sales = create(:user, gumroad_day_timezone: "Pacific Time (US & Canada)")
      create(:free_purchase,
             link: create(:product, user: seller_with_no_paid_sales),
             created_at: DateTime.new(2024, 4, 4, 12, 0, 0, "-07:00"))
      expect(seller_with_no_paid_sales.gumroad_day_saved_fee_cents).to eq(0)
      expect(seller_with_no_paid_sales.gumroad_day_saved_fee_amount).to be nil
    end

    it "returns formatted amount for gumroad_day_saved_fee_cents" do
      allow_any_instance_of(User).to receive(:gumroad_day_saved_fee_cents).and_return(4062)

      seller = create(:user, gumroad_day_timezone: "Pacific Time (US & Canada)")
      expect(seller.gumroad_day_saved_fee_cents).to eq(4062)
      expect(seller.gumroad_day_saved_fee_amount).to eq("$40.62")
    end
  end

  describe "name_or_username" do
    let(:user) { create(:user, name: "Katsuya Noguchi", username: "katsuya") }

    it "returns name if name and username is present" do
      expect(user.name_or_username).to eq user.name
    end

    it "returns name if name is present but username is not" do
      user.username = nil
      expect(user.name_or_username).to eq user.name
    end

    it "returns username if username is present but name is not" do
      user.name = nil
      expect(user.name_or_username).to eq user.username
    end
  end

  describe "has_workflows" do
    before do
      @user = create(:user)
      @product = create(:product, user: @user)
    end

    it "returns true if user has seller workflows" do
      create(:workflow, seller: @user, published_at: 1.day.ago)
      expect(@user.has_workflows?).to be(true)
    end

    it "returns true if user has product workflows" do
      create(:workflow, seller: @user, link: @product, published_at: 1.day.ago)
      expect(@user.has_workflows?).to be(true)
    end

    it "returns false if user has no workflows" do
      expect(@user.has_workflows?).to be(false)
    end
  end

  describe "#pay_with_paypal_enabled?" do
    let(:user) { create(:user) }

    context "when a merchant account is connected" do
      before do
        user.check_merchant_account_is_linked = true
        user.save

        @merchant_account = create(:merchant_account_paypal, user:)
      end

      it "returns true" do
        expect(user.pay_with_paypal_enabled?).to be(true)
      end

      it "returns false if disabled via feature flag" do
        user.update!(disable_paypal_sales: true)

        expect(user.pay_with_paypal_enabled?).to be(false)

        user.update!(disable_paypal_sales: false)

        expect(user.pay_with_paypal_enabled?).to be(true)
      end
    end

    context "when a merchant account is not connected" do
      it "returns true for non-complaint user" do
        expect(user.alive_user_compliance_info).to be_nil
        expect(user.pay_with_paypal_enabled?).to be(true)
      end

      it "returns true for user in un-supported Paypal Connect country" do
        create(:user_compliance_info, user:, country: "India")
        expect(user.pay_with_paypal_enabled?).to be(true)
      end

      it "returns false for user in supported country" do
        create(:user_compliance_info, user:)
        expect(user.pay_with_paypal_enabled?).to be(false)
      end

      it "returns false if disabled via feature flag" do
        create(:user_compliance_info, user:, country: "India")

        user.update!(disable_paypal_sales: true)

        expect(user.pay_with_paypal_enabled?).to be(false)

        user.update!(disable_paypal_sales: false)

        expect(user.pay_with_paypal_enabled?).to be(true)
      end
    end
  end

  describe "#pay_with_card_enabled?" do
    let(:user) { create(:user) }

    context "when a merchant account is not connected" do
      it "returns true" do
        expect(user.pay_with_card_enabled?).to be(true)
      end
    end

    context "when a merchant account is connected" do
      before do
        user.check_merchant_account_is_linked = true
        user.save!

        @merchant_account = create(:merchant_account, user:)
      end

      context "when an active merchant account record exists" do
        it "returns true" do
          expect(user.pay_with_card_enabled?).to be(true)
        end
      end

      context "when no active merchant account record exists" do
        before do
          @merchant_account.mark_deleted!
        end

        it "returns false" do
          expect(user.pay_with_card_enabled?).to be(false)
        end
      end
    end
  end

  describe "#requires_credit_card?" do
    let(:user) { create(:user) }

    it "returns true if user has an active subscription" do
      subscription = create(:subscription, user:)
      create(:purchase, subscription:, is_original_subscription_purchase: true, purchaser: user)
      expect(user.reload.requires_credit_card?).to be(true)

      subscription.cancel_effective_immediately!
      expect(user.requires_credit_card?).to be(false)
    end

    it "returns true if user has an active preorder authorization" do
      preorder_purchase = create(:preorder_authorization_purchase, purchaser: user)
      expect(user.reload.requires_credit_card?).to be(true)

      preorder_purchase.mark_preorder_concluded_successfully!
      expect(user.requires_credit_card?).to be(false)
    end

    it "returns false if user has no active subscription or preorder authorization" do
      expect(user.requires_credit_card?).to be(false)
    end

    it "returns false if the user only has free subscriptions" do
      product = create(:product, price_cents: 0)
      subscription = create(:subscription, user:, link: product)
      create(:purchase, subscription:, link: product, is_original_subscription_purchase: true, purchaser: user)
      expect(user.reload.requires_credit_card?).to be(false)

      subscription.cancel_effective_immediately!
      expect(user.requires_credit_card?).to be(false)
    end

    it "returns false if the user only has test subscriptions" do
      subscription = create(:subscription, user:)
      create(:test_purchase, subscription:, is_original_subscription_purchase: true, purchaser: user)
      expect(user.reload.requires_credit_card?).to be(false)
    end
  end

  describe "#alive_product_files_excluding_product" do
    before do
      s3_file_url = ->(suffix) { "https://s3.amazonaws.com/gumroad-specs/attachment/manual-#{suffix}.pdf" }

      @user1 = create(:user)
      @product1 = create(:product, user: @user1)
      @product_file1 = create(:product_file, link: @product1, url: s3_file_url[1])
      @product_file2 = create(:product_file, link: @product1, url: s3_file_url[2])
      @product_file3 = create(:product_file, link: @product1, url: s3_file_url[3])

      @product2 = create(:product, user: @user1)
      @product_file4 = create(:product_file, link: @product2, url: s3_file_url[4])
      @product_file5 = create(:product_file, link: @product2, url: s3_file_url[5])

      @product3 = create(:product, user: @user1)
      @product_file6 = create(:product_file, link: @product3, url: s3_file_url[6])
      @product_file7 = create(:product_file, link: @product3, url: s3_file_url[7])
      @product_file8 = create(:product_file, link: @product3, url: @product_file5.url)
      @product_file9 = create(:product_file, link: @product3, url: s3_file_url[9])
      @product_file10 = create(:product_file, link: @product3, url: s3_file_url[10])

      create(:product_with_files) # Product belonging to another user
    end

    it "only returns alive product files from alive products" do
      @product3.mark_deleted!
      @product_file3.mark_deleted!

      expect(@user1.alive_product_files_excluding_product.to_a).to(
        eq([@product_file1, @product_file2, @product_file4, @product_file5].sort_by(&:created_at))
      )
    end

    it "only returns alive product files from alive products excluding product files with the passed product id" do
      @product1.mark_deleted!
      @product_file9.mark_deleted!

      expect(@user1.alive_product_files_excluding_product(product_id_to_exclude: @product2.id).to_a).to(
        match_array([@product_file6, @product_file7, @product_file10])
      )
    end

    it "doesn't return duplicate product files with same url" do
      [@product_file2, @product_file5, @product_file9, @product_file10].each do |product_file|
        product_file.url = @product_file1.url
        product_file.save!
      end

      expect(@user1.alive_product_files_excluding_product.to_a).to(
        match_array([@product_file1, @product_file3, @product_file4, @product_file6, @product_file7, @product_file8])
      )
    end
  end

  describe "#alive_product_files_preferred_for_product" do
    let(:user) { create(:user) }
    let(:product) { create(:product_with_pdf_file, user:) }
    let(:another_product) { create(:product, user:) }
    let!(:another_user_product) { create(:product_with_video_file) }

    it "returns alive product files that are unique by `url` even if there are no product files associated with the specified product" do
      product.product_files.alive.each(&:mark_deleted!)
      duplicate_file_url = "https://s3.amazonaws.com/gumroad-specs/attachment/pencil.png"
      another_product_file = create(:product_file, link: @other_product, url: duplicate_file_url)
      another_product.product_files << another_product_file
      create(:product_file, link: create(:product, user:), url: duplicate_file_url)

      expect(user.alive_product_files_preferred_for_product(product)).to eq([another_product_file])
    end

    it "returns alive product files associated with the specified product even if it not published" do
      product.update!(purchase_disabled_at: Time.current)
      product_file = product.product_files.alive.first
      another_product_file = create(:product_file, link: @other_product, url: "https://s3.amazonaws.com/gumroad-specs/attachment/pencil.png")
      another_product.product_files << another_product_file

      expect(product.alive?).to eq(false)
      expect(user.alive_product_files_preferred_for_product(product)).to match_array([product_file, another_product_file])
    end

    it "does not include duplicate product files and prefers those product files among the duplicates that belong to the specified product" do
      product_file = product.product_files.alive.first
      duplicate_file_url = "https://s3.amazonaws.com/gumroad-specs/attachment/pencil.png"
      another_duplicate_file_url = "https://s3.amazonaws.com/gumroad-specs/attachment/logo.png"
      _another_product_file1 = create(:product_file, link: another_product, url: duplicate_file_url)
      duplicate_product_file = create(:product_file, link: product, url: duplicate_file_url)
      another_product_file2 = create(:product_file, link: another_product, url: another_duplicate_file_url)
      _yet_another_product_file = create(:product_file, link: create(:product, user:), url: another_duplicate_file_url)

      expect(user.alive_product_files_preferred_for_product(product)).to match_array([product_file, duplicate_product_file, another_product_file2])
    end
  end

  describe "stripped_fields" do
    it "strips facebook_meta_tag" do
      user = create(:user, facebook_meta_tag: '  <meta name="facebook-domain-verification" content="d7h0sdcqc7pkv613s1zc6j0oel" />  ')
      expect(user.facebook_meta_tag).to eq '<meta name="facebook-domain-verification" content="d7h0sdcqc7pkv613s1zc6j0oel" />'
    end

    it "strips google_analytics_id" do
      user = create(:user, google_analytics_id: " G-12345678 ")
      expect(user.google_analytics_id).to eq "G-12345678"
    end

    it "strips name" do
      user = create(:user, name: " Sally Smith ")
      expect(user.name).to eq "Sally Smith"
    end

    it "strips username and still allows it to be reset to nil" do
      user = create(:user, username: " sallysmith ")
      expect(user.username).to eq "sallysmith"
      user.update!(username: nil)
      expect(user.username).to eq user.external_id
      expect(user.read_attribute(:username)).to eq nil
    end

    it "strips email" do
      user = create(:user, email: " user@example.com ")
      expect(user.email).to eq "user@example.com"
      user.email = ""
      user.validate
      expect(user.email).to eq nil
    end

    it "strips support_email" do
      user = create(:user, support_email: " user@example.com ")
      expect(user.support_email).to eq "user@example.com"
      user.update!(support_email: "")
      expect(user.support_email).to eq nil
    end
  end

  describe "#move_purchases_to_new_email" do
    it "runs after 'email' is updated and schedules an update job" do
      user = create(:user)
      create(:purchase, email: "old@gmail.com", purchaser: user)

      user.update!(email: "new@gmail.com")

      expect(user).to receive(:move_purchases_to_new_email).and_call_original

      user.confirm

      expect(UpdatePurchaseEmailToMatchAccountWorker).to have_enqueued_sidekiq_job(user.id)
    end
  end

  describe "#make_affiliate_of_the_matching_approved_affiliate_requests" do
    let(:requester_email) { "requester@example.com" }
    let!(:approved_affiliate_request_one) { create(:affiliate_request, email: requester_email, state: :approved) }
    let(:user) { create(:unconfirmed_user, unconfirmed_email: requester_email) }

    context "when user signs up and confirms using the same email address which was provided while applying to be an affiliate of a creator" do
      context "when this is the first time we are processing the user's pre-signup approved affiliate request" do
        it "makes the user an affiliate of the matching approved affiliate requests" do
          expect_any_instance_of(AffiliateRequest).to receive(:make_requester_an_affiliate!).and_call_original

          expect do
            user.confirm
          end.to change { user.pre_signup_affiliate_request_processed? }.from(false).to(true)
        end
      end

      context "when the user's pre-signup approved affiliate request has been already processed and the user has confirmed their account again after changing their email" do
        before do
          user.update!(pre_signup_affiliate_request_processed: true)
        end

        it "does not process the user's pre-signup approved affiliate request again" do
          expect_any_instance_of(AffiliateRequest).to_not receive(:make_requester_an_affiliate!)

          expect do
            user.confirm
          end.to_not change { user.pre_signup_affiliate_request_processed? }
        end
      end
    end

    context "when there are no approved affiliate requests matching the email of the confirmed user" do
      it "does nothing" do
        expect_any_instance_of(AffiliateRequest).to_not receive(:make_requester_an_affiliate!)

        create(:unconfirmed_user).confirm
      end
    end
  end

  describe "#timezone_id" do
    it "returns matching TZ database name" do
      expect(build(:user, timezone: "Pacific Time (US & Canada)").timezone_id).to eq("America/Los_Angeles")
      expect(build(:user, timezone: "London").timezone_id).to eq("Europe/London")
    end
  end

  describe "#timezone_formatted_offset" do
    it "returns matching UTC offset" do
      expect(build(:user, timezone: "Pacific Time (US & Canada)").timezone_formatted_offset).to eq("-08:00")
      expect(build(:user, timezone: "London").timezone_formatted_offset).to eq("+00:00")
    end
  end

  describe "#supports_card?" do
    before do
      @creator = create(:user)
    end

    context "creator supports native paypal payments" do
      before do
        create(:merchant_account_paypal, user: @creator, charge_processor_merchant_id: "CJS32DZ7NDN5L", currency: "gbp")
      end

      it "returns true if card processor is nil" do
        new_card = CreditCard.new_card_info
        expect(@creator.supports_card?(new_card)).to be true

        test_card = CreditCard.test_card_info
        expect(@creator.supports_card?(test_card)).to be true
      end

      it "returns true if card processor is stripe" do
        stripe_card = create(:credit_card)
        expect(@creator.supports_card?(stripe_card.as_json)).to be true
      end

      it "returns false if card processor is braintree" do
        braintree_paypal_card = create(:credit_card, chargeable: create(:paypal_chargeable))
        expect(@creator.supports_card?(braintree_paypal_card.as_json)).to be false
      end

      it "returns true if card processor is paypal" do
        native_paypal_card = create(:credit_card, chargeable: create(:native_paypal_chargeable))
        expect(@creator.supports_card?(native_paypal_card.as_json)).to be true
      end
    end

    context "creator doesn't support native paypal payments" do
      it "returns true if card processor is nil" do
        new_card = CreditCard.new_card_info
        expect(@creator.supports_card?(new_card)).to be true

        test_card = CreditCard.test_card_info
        expect(@creator.supports_card?(test_card)).to be true
      end

      it "returns true if card processor is stripe" do
        stripe_card = create(:credit_card)
        expect(@creator.supports_card?(stripe_card.as_json)).to be true
      end

      it "returns true if card processor is braintree" do
        braintree_paypal_card = create(:credit_card, chargeable: create(:paypal_chargeable))
        expect(@creator.supports_card?(braintree_paypal_card.as_json)).to be true
      end

      it "returns false if card processor is paypal" do
        native_paypal_card = create(:credit_card, chargeable: create(:native_paypal_chargeable))
        expect(@creator.supports_card?(native_paypal_card.as_json)).to be false
      end
    end
  end

  describe "#merchant_account_currency" do
    it "returns the currency of merchant account for given charge processor" do
      creator = create(:user)
      create(:merchant_account_paypal, user: creator, currency: "gbp")
      create(:merchant_account, user: creator, currency: "usd")

      expect(creator.merchant_account_currency(StripeChargeProcessor.charge_processor_id)).to eq("USD")
      expect(creator.merchant_account_currency(PaypalChargeProcessor.charge_processor_id)).to eq("GBP")
    end
  end

  describe "#paypal_disconnect_allowed?" do
    it "returns true if creator has no pending preorders or active subscribers using paypal direct payments, else false" do
      creator = create(:user)

      allow_any_instance_of(User).to receive(:active_subscribers?).with(charge_processor_id: PaypalChargeProcessor.charge_processor_id).and_return(false)
      allow_any_instance_of(User).to receive(:active_preorders?).with(charge_processor_id: PaypalChargeProcessor.charge_processor_id).and_return(false)
      expect(creator.paypal_disconnect_allowed?).to be(true)

      allow_any_instance_of(User).to receive(:active_subscribers?).with(charge_processor_id: PaypalChargeProcessor.charge_processor_id).and_return(true)
      allow_any_instance_of(User).to receive(:active_preorders?).with(charge_processor_id: PaypalChargeProcessor.charge_processor_id).and_return(false)
      expect(creator.paypal_disconnect_allowed?).to be(false)

      allow_any_instance_of(User).to receive(:active_subscribers?).with(charge_processor_id: PaypalChargeProcessor.charge_processor_id).and_return(false)
      allow_any_instance_of(User).to receive(:active_preorders?).with(charge_processor_id: PaypalChargeProcessor.charge_processor_id).and_return(true)
      expect(creator.paypal_disconnect_allowed?).to be(false)

      allow_any_instance_of(User).to receive(:active_subscribers?).with(charge_processor_id: PaypalChargeProcessor.charge_processor_id).and_return(true)
      allow_any_instance_of(User).to receive(:active_preorders?).with(charge_processor_id: PaypalChargeProcessor.charge_processor_id).and_return(true)
      expect(creator.paypal_disconnect_allowed?).to be(false)
    end
  end

  describe "#stripe_account" do
    it "returns the custom stripe connect account which is managed by gumroad if present" do
      creator = create(:user)

      expect(creator.stripe_account).to be nil

      create(:merchant_account_stripe_connect, user: creator)
      expect(creator.stripe_account).to be nil

      stripe_account = create(:merchant_account_stripe, user: creator)
      expect(creator.stripe_account).to eq stripe_account
    end
  end

  describe "#stripe_connect_account" do
    it "returns creator's own standard stripe connect account if present" do
      creator = create(:user)

      expect(creator.stripe_connect_account).to be nil

      create(:merchant_account_stripe, user: creator)
      expect(creator.stripe_connect_account).to be nil

      stripe_connect_account = create(:merchant_account_stripe_connect, user: creator)
      expect(creator.stripe_connect_account).to eq stripe_connect_account
    end
  end

  describe "#invalidate_active_sessions!" do
    let(:user) { create(:user) }
    let(:oauth_application) { create(:oauth_application, uid: OauthApplication::MOBILE_API_OAUTH_APPLICATION_UID) }
    let!(:active_access_token_one) { create("doorkeeper/access_token", application: oauth_application, resource_owner_id: user.id, scopes: "mobile_api") }
    let!(:active_access_token_two) { create("doorkeeper/access_token", application: oauth_application, resource_owner_id: user.id, scopes: "mobile_api") }
    let!(:active_access_token_of_another_user) { create("doorkeeper/access_token", application: oauth_application, scopes: "mobile_api") }

    it "invalidates all active sessions of the user and revokes active access tokens that are used to authorize the user in the mobile application" do
      travel_to(DateTime.current) do
        expect do
          user.invalidate_active_sessions!
        end.to change { user.reload.last_active_sessions_invalidated_at }.from(nil).to(DateTime.current)
         .and change { active_access_token_one.reload.revoked_at }.from(nil).to(DateTime.current)
         .and change { active_access_token_two.reload.revoked_at }.from(nil).to(DateTime.current)

        expect(active_access_token_of_another_user.reload.revoked_at).to be_nil
      end
    end
  end

  describe "#init_default_notification_settings" do
    it "sets default notification settings for new users" do
      user = User.new

      %i{enable_payment_email enable_payment_push_notification enable_free_downloads_email enable_free_downloads_push_notification enable_recurring_subscription_charge_email enable_recurring_subscription_charge_push_notification}.each do |notification_key|
        expect(user.public_send(notification_key)).to be(false)
      end

      user = create(:user)

      # Enabled by default
      %i{enable_payment_email enable_payment_push_notification enable_free_downloads_email enable_free_downloads_push_notification}.each do |notification_key|
        expect(user.public_send(notification_key)).to be(true)
      end

      # Disabled by default
      %i{enable_recurring_subscription_charge_email enable_recurring_subscription_charge_push_notification}.each do |notification_key|
        expect(user.public_send(notification_key)).to be(false)
      end
    end
  end

  describe "#enable_tipping" do
    it "sets tipping_enabled to true for new users" do
      user = User.new
      expect(user.tipping_enabled).to be(false)

      user = build(:user)
      user.save!
      expect(user.tipping_enabled).to be(true)
    end
  end

  describe "#enable_discover_boost" do
    it "sets discover_boost_enabled to true for new users" do
      user = User.new
      expect(user.discover_boost_enabled).to be(false)

      user = build(:user)
      user.save!
      expect(user.discover_boost_enabled).to be(true)
    end
  end

  describe "after_commit callback to enqueue GenerateSubscribePreviewJob" do
    before do
      allow_any_instance_of(User).to receive(:generate_subscribe_preview).and_call_original
      @user = create(:user, username: "usernamesample")
      @user.build_seller_profile
      @user.subscribe_preview.attach(
        io: File.open(Rails.root.join("spec", "support", "fixtures", "subscribe_preview.png")),
        filename: "subscribe_preview.png",
        content_type: "image/png"
      )
      @user.seller_profile.save!
      @user.save!
      GenerateSubscribePreviewJob.jobs.clear
    end

    it "does not schedule GenerateSubscribePreviewJob when email changes" do
      @user.update!(email: "new.email@example.com")
      expect(GenerateSubscribePreviewJob.jobs.size).to eq(0)
    end

    it "schedules GenerateSubscribePreviewJob when a new user is created" do
      created_user = create(:user, username: "freshuser")
      expect(GenerateSubscribePreviewJob).to have_enqueued_sidekiq_job(created_user.id)
    end

    it "schedules GenerateSubscribePreviewJob when the username changes" do
      @user.update!(username: "newusername")
      expect(GenerateSubscribePreviewJob).to have_enqueued_sidekiq_job(@user.id)
    end

    it "schedules GenerateSubscribePreviewJob when the name changes" do
      @user.update!(name: "Marty McFly")
      expect(GenerateSubscribePreviewJob).to have_enqueued_sidekiq_job(@user.id)
    end

    it "schedules GenerateSubscribePreviewJob when the seller highlight_color changes" do
      @user.seller_profile.update!(highlight_color: "#133337")
      @user.save!
      expect(GenerateSubscribePreviewJob).to have_enqueued_sidekiq_job(@user.id)
    end

    it "schedules GenerateSubscribePreviewJob when the seller background_color changes" do
      @user.seller_profile.update!(background_color: "#133337")
      @user.save!
      expect(GenerateSubscribePreviewJob).to have_enqueued_sidekiq_job(@user.id)
    end

    it "schedules GenerateSubscribePreviewJob when the seller font changes" do
      @user.seller_profile.update!(font: "Inter")
      @user.save!
      expect(GenerateSubscribePreviewJob).to have_enqueued_sidekiq_job(@user.id)
    end

    it "schedules GenerateSubscribePreviewJob when avatar changes" do
      # Avatar updates regenerate the preview.
      @user.avatar.attach(
        io: fixture_file_upload("smilie.png"),
        filename: "smilie.png",
      )
      expect(GenerateSubscribePreviewJob.jobs.size).to eq(1)
      expect(GenerateSubscribePreviewJob).to have_enqueued_sidekiq_job(@user.id)

      GenerateSubscribePreviewJob.jobs.clear

      # Updates to other attached fields do not regenerate the preview.
      @user.subscribe_preview.attach(
        io: fixture_file_upload("smilie.png"),
        filename: "new_subscribe_preview.png",
      )
      expect(GenerateSubscribePreviewJob.jobs.size).to eq(0)

      # Avatar removal regenerates the preview.
      # Should ideally use `#purge` but the test environment AWS S3 credentials
      # do not have access to remove items.
      @user.avatar = nil
      @user.save!
      expect(GenerateSubscribePreviewJob.jobs.size).to eq(1)
      expect(GenerateSubscribePreviewJob).to have_enqueued_sidekiq_job(@user.id)
    end
  end

  describe "after_save callback to enqueue StripeApplePayDomain jobs" do
    before :each do
      @user = create(:user, username: "usernamesample")
    end

    it "schedules StripeApplePayDomain jobs when username is changed" do
      CreateStripeApplePayDomainWorker.jobs.clear
      @user.username = "newusername"
      @user.save!
      expect(CreateStripeApplePayDomainWorker).to have_enqueued_sidekiq_job(@user.id)
      expect(DeleteStripeApplePayDomainWorker).to have_enqueued_sidekiq_job(@user.id, Subdomain.from_username("usernamesample"))
    end

    it "schedules StripeApplePayDomain jobs when new user is created" do
      expect(CreateStripeApplePayDomainWorker).to have_enqueued_sidekiq_job(@user.id)
      expect(DeleteStripeApplePayDomainWorker.jobs.size).to eq(0)
    end

    it "does not schedule StripeApplePayDomain jobs when username is unchanged" do
      CreateStripeApplePayDomainWorker.jobs.clear
      @user.name = "newname"
      @user.save!
      expect(CreateStripeApplePayDomainWorker.jobs.size).to eq(0)
      expect(DeleteStripeApplePayDomainWorker.jobs.size).to eq(0)
    end
  end

  describe "after_create #create_global_affiliate!" do
    it "creates a global affiliate record after user creation" do
      user = build(:user)
      expect do
        user.save
      end.to change { GlobalAffiliate.where(affiliate_user_id: user.id).count }.by(1)
    end
  end

  describe "after_create #create_refund_policy!" do
    it "creates a refund policy after user creation" do
      user = build(:user)
      expect { user.save }.to change(SellerRefundPolicy, :count).by(1)
    end
  end

  describe "#generate_username" do
    it "enqueues a job to generate a unique username" do
      user = create(:user, email: "johnsmith@gumroad.com", username: nil)
      expect(GenerateUsernameJob).to have_enqueued_sidekiq_job(user.id)
    end
  end

  describe "#auto_transcode_videos?" do
    before do
      @user = create(:user)
    end

    context "when tier pricing is enabled" do
      before do
        allow_any_instance_of(User).to receive(:tier_pricing_enabled?).and_return(true)
      end

      context "when the seller has $100K revenue" do
        before do
          @user.update!(tier_state: 100_000)
        end

        it "returns true" do
          expect(@user.auto_transcode_videos?).to eq true
        end
      end

      context "when the seller less than $100K revenue" do
        before do
          @user.update!(tier_state: 1_000)
        end

        it "returns false" do
          expect(@user.auto_transcode_videos?).to eq false
        end
      end
    end

    context "when tier pricing is disabled" do
      before do
        allow_any_instance_of(User).to receive(:tier_pricing_enabled?).and_return(false)
      end

      context "when the seller has $100K revenue" do
        before do
          allow_any_instance_of(User).to receive(:sales_cents_total).and_return(100_000)
        end

        it "returns true" do
          expect(@user.auto_transcode_videos?).to eq true
        end
      end

      context "when the seller less than $100K revenue" do
        before do
          allow(@user).to receive(:sales_cents_total).and_return(1_000)
        end

        it "returns false" do
          expect(@user.auto_transcode_videos?).to eq false
        end
      end
    end
  end

  describe "#admin_page_url" do
    it "returns the admin users page url" do
      user = create(:user)
      expect(user.admin_page_url).to eq("#{PROTOCOL}://#{DOMAIN}/admin/users/#{user.id}")
    end
  end

  describe "#compliance_info_resettable?" do
    it "returns true if the user doesn't have an active Stripe account" do
      user = create(:user_with_compliance_info)
      expect(user.compliance_info_resettable?).to eq true
    end

    it "returns true if the user doesn't have any purchases or balances associated with an active Stripe account" do
      user = create(:user_with_compliance_info)
      create(:merchant_account, user:)
      expect(user.compliance_info_resettable?).to eq true
    end

    it "returns false if the user has a balance associated with an active Stripe account" do
      user = create(:user_with_compliance_info)
      merchant_account = create(:merchant_account, user:)
      create(:balance, user:, merchant_account:)
      expect(user.compliance_info_resettable?).to eq false
    end

    it "returns false if the user has a purchase associated with an active Stripe account" do
      user = create(:user_with_compliance_info)
      product = create(:product, user:)
      merchant_account = create(:merchant_account, user:)
      create(:purchase, seller: user, merchant_account:, link: product)
      expect(user.compliance_info_resettable?).to eq false
    end
  end

  describe "#has_unconfirmed_email?" do
    it "returns true if the user has an unconfirmed email" do
      user = create(:user, unconfirmed_email: Faker::Internet.email)
      expect(user.has_unconfirmed_email?).to eq true
    end

    it "returns true if the user.confirmed? is false" do
      user = create(:user, confirmed_at: nil)
      expect(user.has_unconfirmed_email?).to eq true
    end

    it "return false if the user has a confirmed email" do
      user = create(:user)
      expect(user.has_unconfirmed_email?).to eq false
    end
  end

  describe "#collaborator_for?" do
    let(:user) { create(:user) }
    let(:product) { create(:product) }

    it "returns true if the user is currently a collaborator on another seller's products, false otherwise" do
      create(:collaborator, affiliate_user: user, products: [product])
      expect(user.collaborator_for?(product)).to eq true
      expect(user.collaborator_for?(create(:product))).to eq false
    end

    it "returns false if the user is no longer a collaborator" do
      create(:collaborator, affiliate_user: user, products: [product], deleted_at: 1.day.ago)
      expect(user.collaborator_for?(product)).to eq false
    end

    it "returns false if the user is not a collaborator" do
      create(:collaborator, affiliate_user: user)
      expect(user.collaborator_for?(product)).to eq false
    end
  end

  describe "#alive_cart" do
    let(:user) { create(:user) }

    it "returns an alive cart" do
      cart = create(:cart, user:)
      expect(user.alive_cart).to eq cart
    end

    it "does not return a deleted cart" do
      create(:cart, user:, deleted_at: Time.current)
      expect(user.alive_cart).to be_nil
    end
  end

  describe "#update_audience_members_affiliates" do
    it "changing email updates members records" do
      user = create(:user, email: "original@example.com")

      # add member who is both a follower and an affiliate
      seller_1 = create(:user)
      affiliate_1 = create(:direct_affiliate, seller: seller_1, affiliate_user: user)
      affiliate_1.products << create(:product, user: seller_1)
      create(:active_follower, user: seller_1, email: user.email)
      expect(seller_1.audience_members.find_by(email: user.email, follower: true, affiliate: true)).to be_present

      # add member who is just an affiliate
      seller_2 = create(:user)
      affiliate_2 = create(:direct_affiliate, seller: seller_2, affiliate_user: user)
      affiliate_2.products << create(:product, user: seller_2)
      expect(seller_2.audience_members.find_by(email: user.email, affiliate: true)).to be_present

      # add member who is just an affiliate, to test what happens when their audience wasn't refreshed yet
      seller_3 = create(:user)
      affiliate_3 = create(:direct_affiliate, seller: seller_3, affiliate_user: user)
      affiliate_3.products << create(:product, user: seller_3)
      seller_3.audience_members.find_by(email: user.email, affiliate: true).delete

      user.update!(email: "new@example.com")
      user.confirm

      member_1 = seller_1.audience_members.find_by(email: "original@example.com")
      expect(member_1.follower).to eq(true) # no change
      expect(member_1.affiliate).to eq(false) # removes affiliate from this record

      member_2 = seller_1.audience_members.find_by(email: "new@example.com")
      expect(member_2.affiliate).to eq(true) # moves affiliate to its own member record

      expect(seller_2.audience_members.find_by(email: "original@example.com")).to be_blank # record was removed because it wasn't an affiliate or anything else anymore
      expect(seller_2.audience_members.find_by(email: "new@example.com")).to be_present

      expect(seller_3.audience_members.find_by(email: "original@example.com")).to be_blank # the missing member was ignored
      expect(seller_3.audience_members.find_by(email: "new@example.com")).to be_blank # no change
    end
  end

  describe "#purchasing_power_parity_excluded_product_external_ids" do
    before do
      @user = create(:user)
      @product = create(:product, user: @user)
      create(:product, user: @user)
    end

    it "returns the excluded product external_ids" do
      expect(@user.purchasing_power_parity_excluded_product_external_ids).to eq([])

      @product.update!(purchasing_power_parity_disabled: true)

      expect(@user.purchasing_power_parity_excluded_product_external_ids).to eq([@product.external_id])
    end
  end

  describe "#update_purchasing_power_parity_excluded_products!" do
    before do
      @user = create(:user)
      @product_1 = create(:product, user: @user)
      @product_2 = create(:product, user: @user, purchasing_power_parity_disabled: true)
    end

    it "sets purchasing_power_parity_disabled to true for the passed products and false for excluded products" do
      @user.update_purchasing_power_parity_excluded_products!([@product_1.external_id])

      expect(@user.reload.purchasing_power_parity_excluded_product_external_ids).to eq([@product_1.external_id])
      expect(@product_2.reload.purchasing_power_parity_disabled).to eq(false)
    end
  end

  describe "#eligible_for_service_products?" do
    let(:user) { create(:user) }

    context "user is at least 30 days old" do
      before do
        user.update!(created_at: 31.days.ago)
      end

      it "returns true" do
        expect(user.eligible_for_service_products?).to eq(true)
      end
    end

    context "user is less than 30 days old" do
      it "returns false" do
        expect(user.eligible_for_service_products?).to eq(false)
      end
    end
  end

  describe "#trigger_iffy_ingest" do
    let!(:user) { create(:user, name: "Original Name", bio: "Original Bio") }

    before do
      allow_any_instance_of(Iffy::Profile::IngestService).to receive(:perform).and_return(true)
    end

    it "does not trigger an iffy ingest job if neither name nor bio have changed" do
      expect do
        user.update!(email: "newemail@example.com")
      end.not_to change { Iffy::Profile::IngestJob.jobs.size }
    end

    it "triggers an iffy ingest job if the name has changed" do
      expect do
        user.update!(name: "New Name")
      end.to change { Iffy::Profile::IngestJob.jobs.size }.by(1)
    end

    it "triggers an iffy ingest job if the bio has changed" do
      expect do
        user.update!(bio: "New Bio")
      end.to change { Iffy::Profile::IngestJob.jobs.size }.by(1)
    end

    it "triggers an iffy ingest job if the username has changed" do
      expect do
        user.update!(username: "username1")
      end.to change { Iffy::Profile::IngestJob.jobs.size }.by(1)
    end
  end

  describe "#eligible_for_instant_payouts?" do
    let(:user) { create(:compliant_user) }
    let!(:compliance_info) { create(:user_compliance_info, user:) }
    let!(:payments) { create_list(:payment_completed, 4, user:) }

    before do
      allow(user).to receive(:payouts_paused?).and_return(false)
    end

    it "returns true when all conditions are met" do
      expect(user.eligible_for_instant_payouts?).to eq(true)
    end

    it "returns false when user is not compliant" do
      [:not_reviewed,
       :on_probation,
       :flagged_for_fraud,
       :flagged_for_tos_violation,
       :suspended_for_fraud,
       :suspended_for_tos_violation].each do |non_compliant_risk_state|
        user.update!(user_risk_state: non_compliant_risk_state)
        expect(user.reload.eligible_for_instant_payouts?).to eq(false)
      end
    end

    it "returns false when payouts are paused" do
      allow(user).to receive(:payouts_paused?).and_return(true)
      expect(user.eligible_for_instant_payouts?).to eq(false)
    end

    it "returns false when user does not have 4 completed payments" do
      user.payments.last.destroy
      expect(user.eligible_for_instant_payouts?).to eq(false)
    end

    it "returns false when user is not from the US" do
      user.alive_user_compliance_info.mark_deleted!
      create(:user_compliance_info_canada, user:)
      expect(user.eligible_for_instant_payouts?).to eq(false)
    end
  end

  describe "#instant_payouts_supported?" do
    let(:user) { create(:user) }
    let(:bank_account) { create(:ach_account, user:) }

    before do
      allow(user).to receive(:active_bank_account).and_return(bank_account)
      allow(bank_account).to receive(:supports_instant_payouts?).and_return(true)
      allow(user).to receive(:eligible_for_instant_payouts?).and_return(true)
    end

    it "returns false when user has no active bank account" do
      allow(user).to receive(:active_bank_account).and_return(nil)
      expect(user.instant_payouts_supported?).to eq(false)
    end

    it "returns false when bank account does not support instant payouts" do
      allow(bank_account).to receive(:supports_instant_payouts?).and_return(false)
      expect(user.instant_payouts_supported?).to eq(false)
    end

    it "returns false when user is not eligible for instant payouts" do
      allow(user).to receive(:eligible_for_instant_payouts?).and_return(false)
      expect(user.instant_payouts_supported?).to eq(false)
    end

    it "returns true if user is eligible for instant payouts and their bank account supports them" do
      expect(user.instant_payouts_supported?).to eq(true)
    end
  end

  describe "#payouts_paused?" do
    let(:user) { create(:user) }

    it "returns true when payouts are paused internally" do
      user.payouts_paused_internally = true
      user.payouts_paused_by_user = false
      expect(user.payouts_paused?).to eq(true)
    end

    it "returns true when payouts are paused by user" do
      user.payouts_paused_internally = false
      user.payouts_paused_by_user = true
      expect(user.payouts_paused?).to eq(true)
    end

    it "returns true when payouts are paused both internally and by user" do
      user.payouts_paused_internally = true
      user.payouts_paused_by_user = true
      expect(user.payouts_paused?).to eq(true)
    end

    it "returns false when payouts are not paused" do
      user.payouts_paused_internally = false
      user.payouts_paused_by_user = false
      expect(user.payouts_paused?).to eq(false)
    end
  end

  describe "#minimum_payout_amount_cents" do
    let(:user) { create(:user) }

    it "returns the payout threshold" do
      user.payout_threshold_cents = 2000
      expect(user.minimum_payout_amount_cents).to eq(2000)
    end

    describe "when the user is in a cross-border payout country" do
      let(:user) { create(:user) }
      let!(:compliance_info) { create(:user_compliance_info_korea, user:) }

      it "returns the higher of payout threshold and country minimum" do
        expect(user.minimum_payout_amount_cents).to eq(3474)
        user.payout_threshold_cents = 4000
        expect(user.minimum_payout_amount_cents).to eq(4000)
      end
    end
  end

  describe "#made_a_successful_sale_with_a_stripe_connect_or_paypal_connect_account?" do
    let(:user) { create(:user) }
    let!(:stripe_connect_account) { create(:merchant_account_stripe_connect, user:) }

    context "when the user has made a successful sale with a Stripe Connect account" do
      before do
        create(:purchase, seller: user, link: create(:product, user:), merchant_account: stripe_connect_account)
      end

      context "when the Stripe Connect account is alive" do
        it "returns true" do
          expect(user.made_a_successful_sale_with_a_stripe_connect_or_paypal_connect_account?).to eq(true)
        end
      end

      context "when the Stripe Connect account has been deleted" do
        before do
          stripe_connect_account.mark_deleted!
        end

        it "returns true" do
          expect(user.made_a_successful_sale_with_a_stripe_connect_or_paypal_connect_account?).to eq(true)
        end
      end
    end

    context "when the user has not made a successful sale with a Stripe Connect account" do
      before do
        create(:failed_purchase, seller: user, link: create(:product, user:), merchant_account: stripe_connect_account)
      end

      it "returns false" do
        expect(user.made_a_successful_sale_with_a_stripe_connect_or_paypal_connect_account?).to eq(false)
      end
    end

    context "when the user has no Stripe Connect account" do
      it "returns false" do
        stripe_connect_account.destroy!

        expect(user.made_a_successful_sale_with_a_stripe_connect_or_paypal_connect_account?).to eq(false)
      end
    end

    context "when the user has made a successful sale with a PayPal Connect account" do
      let!(:paypal_connect_account) { create(:merchant_account_paypal, user:) }

      before do
        create(:purchase, seller: user, link: create(:product, user:), merchant_account: paypal_connect_account)
      end

      context "when the PayPal Connect account is alive" do
        it "returns true" do
          expect(user.made_a_successful_sale_with_a_stripe_connect_or_paypal_connect_account?).to eq(true)
        end
      end

      context "when the PayPal Connect account has been deleted" do
        before do
          paypal_connect_account.mark_deleted!
        end

        it "returns true" do
          expect(user.made_a_successful_sale_with_a_stripe_connect_or_paypal_connect_account?).to eq(true)
        end
      end
    end

    context "when the user has not made a successful sale with a PayPal Connect account" do
      let!(:paypal_connect_account) { create(:merchant_account_paypal, user:) }

      before do
        create(:failed_purchase, seller: user, link: create(:product, user:), merchant_account: paypal_connect_account)
      end

      it "returns false" do
        expect(user.made_a_successful_sale_with_a_stripe_connect_or_paypal_connect_account?).to eq(false)
      end
    end

    context "when the user has no PayPal Connect account" do
      let!(:paypal_connect_account) { create(:merchant_account_paypal, user:) }

      it "returns false" do
        paypal_connect_account.destroy!

        expect(user.made_a_successful_sale_with_a_stripe_connect_or_paypal_connect_account?).to eq(false)
      end
    end
  end

  describe "#eligible_for_abandoned_cart_workflows?" do
    let(:user) { create(:user) }

    context "when user has a Stripe Connect account" do
      let!(:stripe_connect_account) { create(:merchant_account_stripe_connect, user:) }

      it "returns false if the Stripe Connect account has been deleted and there were no linked successful sales" do
        stripe_connect_account.mark_deleted!

        expect(user.eligible_for_abandoned_cart_workflows?).to eq(false)
      end

      it "returns true if the Stripe Connect account has been deleted and there was at least one successful sale with that Stripe Connect account" do
        create(:purchase, seller: user, link: create(:product, user:), merchant_account: stripe_connect_account)
        stripe_connect_account.mark_deleted!

        expect(user.eligible_for_abandoned_cart_workflows?).to eq(true)
      end
    end

    context "when user has a PayPal Connect account" do
      let!(:paypal_connect_account) { create(:merchant_account_paypal, user:) }

      it "returns false if the PayPal Connect account has been deleted and there were no linked successful sales" do
        paypal_connect_account.mark_deleted!

        expect(user.eligible_for_abandoned_cart_workflows?).to eq(false)
      end

      it "returns true if the PayPal Connect account has been deleted and there was at least one successful sale with that PayPal Connect account" do
        create(:purchase, seller: user, link: create(:product, user:), merchant_account: paypal_connect_account)
        paypal_connect_account.mark_deleted!

        expect(user.eligible_for_abandoned_cart_workflows?).to eq(true)
      end
    end

    it "returns true when user has completed payments" do
      create(:payment_completed, user:)
      expect(user.eligible_for_abandoned_cart_workflows?).to eq(true)
    end

    it "returns false when user has no Stripe Connect account and no completed payments" do
      expect(user.eligible_for_abandoned_cart_workflows?).to eq(false)
    end
  end

  describe "#eligible_to_send_emails?" do
    let(:user) { create(:user) }

    context "when user is a team member" do
      it "returns true" do
        user.update!(is_team_member: true)
        expect(user.eligible_to_send_emails?).to eq(true)
      end
    end

    context "when user is not a team member" do
      it "returns true when user has a completed payment and has made minimum required sales" do
        create(:payment_completed, user:)
        allow(user).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
        expect(user.eligible_to_send_emails?).to eq(true)
      end

      context "when user has a Stripe Connect account" do
        let!(:stripe_connect_account) { create(:merchant_account_stripe_connect, user:) }

        before do
          allow(user).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
        end

        it "returns false if the Stripe Connect account has been deleted and there were no linked successful sales" do
          stripe_connect_account.mark_deleted!

          expect(user.eligible_to_send_emails?).to eq(false)
        end

        it "returns true if the Stripe Connect account has been deleted and there was at least one successful sale with that Stripe Connect account" do
          create(:purchase, seller: user, link: create(:product, user:), merchant_account: stripe_connect_account)
          stripe_connect_account.mark_deleted!

          expect(user.eligible_to_send_emails?).to eq(true)
        end
      end

      context "when user has a PayPal Connect account" do
        let!(:paypal_connect_account) { create(:merchant_account_paypal, user:) }

        before do
          allow(user).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
        end

        it "returns false if the PayPal Connect account has been deleted and there were no linked successful sales" do
          paypal_connect_account.mark_deleted!

          expect(user.eligible_to_send_emails?).to eq(false)
        end

        it "returns true if the PayPal Connect account has been deleted and there was at least one successful sale with that PayPal Connect account" do
          create(:purchase, seller: user, link: create(:product, user:), merchant_account: paypal_connect_account)
          paypal_connect_account.mark_deleted!

          expect(user.eligible_to_send_emails?).to eq(true)
        end
      end

      it "returns false when user is suspended" do
        admin_user = create(:admin_user)
        user.flag_for_fraud(author_id: admin_user.id)
        user.suspend_for_fraud(author_id: admin_user.id)
        expect(user.eligible_to_send_emails?).to eq(false)
      end

      it "returns false when user has no completed payment" do
        allow(user).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
        expect(user.eligible_to_send_emails?).to eq(false)
      end

      it "returns false when user has not made minimum required sales" do
        create(:payment_completed, user:)
        allow(user).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE - 1)
        expect(user.eligible_to_send_emails?).to eq(false)
      end
    end
  end

  describe "#has_all_eligible_refund_policies_as_no_refunds?" do
    let(:seller) { create(:named_seller) }
    let(:product1) { create(:product, user: seller) }
    let(:product2) { create(:product, user: seller) }
    let!(:refund_policy1) { create(:product_refund_policy, seller:, product: product1) }
    let!(:refund_policy2) { create(:product_refund_policy, seller:, product: product2) }

    context "when all refund policies are no-refunds" do
      before do
        allow_any_instance_of(ProductRefundPolicy).to receive(:published_and_no_refunds?).and_return(true)
      end

      it "returns true" do
        expect(seller.has_all_eligible_refund_policies_as_no_refunds?).to be true
      end
    end

    context "when some refund policies are not no-refunds" do
      it "returns false" do
        expect(seller.has_all_eligible_refund_policies_as_no_refunds?).to be false
      end
    end

    context "when user has no refund policies" do
      before do
        refund_policy1.destroy!
        refund_policy2.destroy!
      end

      it "returns false" do
        expect(seller.has_all_eligible_refund_policies_as_no_refunds?).to be false
      end
    end
  end

  describe "#accessible_communities_ids" do
    let!(:user) { create(:user) }
    let!(:product) { create(:product, user:) }
    let!(:other_product) { create(:product) }

    context "when user is a seller" do
      let!(:community) { create(:community, seller: user, resource: product) }

      it "includes communities owned by the seller" do
        Feature.activate_user(:communities, user)
        product.update!(community_chat_enabled: true)
        expect(user.accessible_communities_ids).to eq([community.id])
      end

      it "excludes communities where the resource is deleted" do
        Feature.activate_user(:communities, user)
        product.update!(community_chat_enabled: true)
        product.mark_deleted!
        expect(user.accessible_communities_ids).to eq([])
      end

      it "excludes communities when feature flag is disabled" do
        Feature.deactivate_user(:communities, user)
        product.update!(community_chat_enabled: true)
        expect(user.accessible_communities_ids).to eq([])
      end

      it "excludes communities when community chat is disabled" do
        Feature.activate_user(:communities, user)
        product.update!(community_chat_enabled: false)
        expect(user.accessible_communities_ids).to eq([])
      end
    end

    context "when user is a buyer" do
      let!(:other_community) { create(:community, seller: other_product.user, resource: other_product) }
      let!(:purchase) { create(:purchase, purchaser: user, link: other_product) }

      it "includes communities of purchased products" do
        Feature.activate_user(:communities, other_product.user)
        other_product.update!(community_chat_enabled: true)
        expect(user.accessible_communities_ids).to eq([other_community.id])
      end

      it "excludes communities where the resource is deleted" do
        Feature.activate_user(:communities, other_product.user)
        other_product.update!(community_chat_enabled: true)
        other_product.mark_deleted!
        expect(user.accessible_communities_ids).to eq([])
      end

      it "excludes communities when feature flag is disabled" do
        Feature.deactivate_user(:communities, other_product.user)
        other_product.update!(community_chat_enabled: true)
        expect(user.accessible_communities_ids).to eq([])
      end

      it "excludes communities when community chat is disabled" do
        Feature.activate_user(:communities, other_product.user)
        other_product.update!(community_chat_enabled: false)
        expect(user.accessible_communities_ids).to eq([])
      end

      context "when purchase is made with email" do
        let!(:purchase) { create(:purchase, purchaser: nil, email: user.email, link: other_product) }

        it "includes communities of purchased products" do
          Feature.activate_user(:communities, other_product.user)
          other_product.update!(community_chat_enabled: true)
          expect(user.accessible_communities_ids).to eq([other_community.id])
        end
      end
    end

    context "when user is both seller and buyer" do
      let!(:community) { create(:community, seller: user, resource: product) }
      let!(:other_community) { create(:community, seller: other_product.user, resource: other_product) }
      let!(:purchase) { create(:purchase, purchaser: user, link: other_product) }

      it "includes both seller and buyer communities" do
        Feature.activate_user(:communities, user)
        Feature.activate_user(:communities, other_product.user)
        product.update!(community_chat_enabled: true)
        other_product.update!(community_chat_enabled: true)
        expect(user.accessible_communities_ids.uniq).to match_array([community.id, other_community.id])
      end

      it "excludes communities where feature flag is disabled" do
        Feature.deactivate_user(:communities, user)
        Feature.deactivate_user(:communities, other_product.user)
        product.update!(community_chat_enabled: true)
        other_product.update!(community_chat_enabled: true)
        expect(user.accessible_communities_ids).to eq([])
      end

      it "excludes communities where community chat is disabled" do
        Feature.activate_user(:communities, user)
        Feature.activate_user(:communities, other_product.user)
        product.update!(community_chat_enabled: false)
        other_product.update!(community_chat_enabled: false)
        expect(user.accessible_communities_ids).to eq([])
      end
    end
  end

  describe "#purchased_small_bets?" do
    let(:user) { create(:user) }
    let(:small_bets_product) { create(:product) }

    before do
      allow(GlobalConfig).to receive(:get)
        .with("SMALL_BETS_PRODUCT_ID", 2866567)
        .and_return(small_bets_product.id)
    end

    it "returns true if the user has purchased the small bets product" do
      expect(user.purchased_small_bets?).to eq(false)

      create(:purchase, purchaser: user, link: small_bets_product)

      expect(user.purchased_small_bets?).to eq(true)
    end
  end

  describe "#eligible_for_ai_product_generation?" do
    let(:user) { create(:user) }

    before do
      Feature.activate_user(:ai_product_generation, user)
      user.confirm
      allow(user).to receive(:sales_cents_total).and_return(15_000)
    end

    it "returns true when user has completed payments" do
      create(:payment_completed, user:)
      expect(user.eligible_for_ai_product_generation?).to eq(true)
    end

    it "returns true when user made successful sale with Stripe Connect account" do
      stripe_connect_account = create(:merchant_account_stripe_connect, user:)
      create(:purchase, seller: user, link: create(:product, user:), merchant_account: stripe_connect_account)
      expect(user.eligible_for_ai_product_generation?).to eq(true)
    end

    it "returns true when user made successful sale with PayPal Connect account" do
      paypal_connect_account = create(:merchant_account_paypal, user:)
      create(:purchase, seller: user, link: create(:product, user:), merchant_account: paypal_connect_account)
      expect(user.eligible_for_ai_product_generation?).to eq(true)
    end

    it "returns false when user has no completed payments or successful sales" do
      expect(user.eligible_for_ai_product_generation?).to eq(false)
    end

    it "returns false when feature flag is inactive" do
      Feature.deactivate_user(:ai_product_generation, user)
      create(:payment_completed, user:)
      expect(user.eligible_for_ai_product_generation?).to eq(false)
    end

    it "returns false when user is not confirmed" do
      user.update!(confirmed_at: nil)
      create(:payment_completed, user:)
      expect(user.eligible_for_ai_product_generation?).to eq(false)
    end

    it "returns false when user is suspended" do
      user.update!(user_risk_state: :suspended_for_fraud)
      create(:payment_completed, user:)
      expect(user.eligible_for_ai_product_generation?).to eq(false)
    end

    it "returns false when user has insufficient sales" do
      allow(user).to receive(:sales_cents_total).and_return(5_000)
      create(:payment_completed, user:)
      expect(user.eligible_for_ai_product_generation?).to eq(false)
    end

    it "returns true regardless of other conditions in development environment" do
      allow(Rails.env).to receive(:development?).and_return(true)
      user.update!(confirmed_at: nil)
      user.update!(user_risk_state: :suspended_for_fraud)
      allow(user).to receive(:sales_cents_total).and_return(0)

      expect(user.eligible_for_ai_product_generation?).to eq(true)
    end
  end
end
