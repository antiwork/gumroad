# frozen_string_literal: true

require "spec_helper"

describe SettingsPresenter do
  let(:product) do
    create(:product, purchasing_power_parity_disabled: true, user: create(:named_seller, purchasing_power_parity_limit: 60))
  end
  let(:seller) { product.user }
  let(:user) { seller }
  let(:pundit_user) { SellerContext.new(user:, seller:) }
  let(:presenter) { described_class.new(pundit_user:) }

  describe "#pages" do
    context "with owner as logged in user" do
      it "returns correct pages" do
        expect(presenter.pages).to eq(
          %w(main profile team payments password third_party_analytics advanced)
        )
      end

      context "when there is at least one alive OAuth app" do
        before do
          create("doorkeeper/access_token", resource_owner_id: seller.id, scopes: "creator_api")
        end

        it "includes authorized_applications page" do
          expect(presenter.pages).to include("authorized_applications")
        end
      end
    end

    context "with user as admin for owner" do
      let(:user) { create(:user) }

      before do
        create(:team_membership, user:, seller:, role: TeamMembership::ROLE_ADMIN)
      end

      it "returns correct pages" do
        expect(presenter.pages).to eq(
          %w(main profile team payments third_party_analytics advanced)
        )
      end
    end

    [TeamMembership::ROLE_ACCOUNTANT, TeamMembership::ROLE_MARKETING, TeamMembership::ROLE_SUPPORT].each do |role|
      context "with user as #{role} for owner" do
        let(:user) { create(:user) }

        before do
          create(:team_membership, user:, seller:, role:)
        end

        it "returns correct pages" do
          expect(presenter.pages).to eq(
            %w(profile team)
          )
        end
      end
    end
  end

  describe "#main_props" do
    before { Feature.activate(:product_level_support_emails) }

    it "returns correct props" do
      expect(presenter.main_props).to eq(
        settings_pages: presenter.pages,
        is_form_disabled: false,
        invalidate_active_sessions: true,
        ios_app_store_url: IOS_APP_STORE_URL,
        android_app_store_url: ANDROID_APP_STORE_URL,
        timezones: ActiveSupport::TimeZone.all.map { |tz| { name: tz.name, offset: tz.formatted_offset } },
        currencies: CURRENCY_CHOICES.map { |k, v| { name: v[:display_format], code: k } },
        user: {
          email: seller.form_email,
          support_email: seller.support_email,
          locale: seller.locale,
          timezone: seller.timezone,
          currency_type: seller.currency_type,
          has_unconfirmed_email: false,
          compliance_country: nil,
          purchasing_power_parity_enabled: false,
          purchasing_power_parity_limit: 60,
          purchasing_power_parity_payment_verification_disabled: false,
          products: [{ id: product.external_id, name: product.name }],
          purchasing_power_parity_excluded_product_ids: [product.external_id],
          enable_payment_email: true,
          enable_payment_push_notification: true,
          enable_recurring_subscription_charge_email: false,
          enable_recurring_subscription_charge_push_notification: false,
          enable_free_downloads_email: true,
          enable_free_downloads_push_notification: true,
          announcement_notification_enabled: true,
          disable_comments_email: false,
          disable_reviews_email: false,
          show_nsfw_products: false,
          disable_affiliate_requests: false,
          product_level_support_emails: [],
          seller_refund_policy: {
            enabled: true,
            allowed_refund_periods_in_days: [
              {
                key: 0,
                value: "No refunds allowed"
              },
              {
                key: 7,
                value: "7-day money back guarantee"
              },
              {
                key: 14,
                value: "14-day money back guarantee"
              },
              {
                key: 30,
                value: "30-day money back guarantee"
              },
              {
                key: 183,
                value: "6-month money back guarantee"
              }
            ],
            max_refund_period_in_days: 30,
            fine_print: nil,
            fine_print_enabled: false
          }
        }
      )
    end

    context "when support emails exist" do
      before { product.update!(support_email: "support@example.com") }

      it "includes product_level_support_emails in main_props" do
        expect(presenter.main_props[:user][:product_level_support_emails]).to contain_exactly(
          {
            email: "support@example.com",
            product_ids: [product.external_id]
          }
        )
      end
    end

    context "when product_level_support_emails feature is disabled" do
      before { Feature.deactivate(:product_level_support_emails) }
      before { product.update!(support_email: "support@example.com") }

      it "returns nil for product_level_support_emails" do
        expect(presenter.main_props[:user][:product_level_support_emails]).to be_nil
      end
    end

    context "when user has unconfirmed email" do
      before do
        seller.update!(unconfirmed_email: "john@example.com")
      end

      it "returns `user.has_unconfirmed_email` as true" do
        expect(presenter.main_props[:user][:has_unconfirmed_email]).to be(true)
      end
    end

    context "when comments are disabled" do
      before do
        seller.update!(disable_comments_email: true)
      end

      it "returns `user.disable_comments_email` as true" do
        expect(presenter.main_props[:user][:disable_comments_email]).to be(true)
      end
    end
  end

  describe "#application_props" do
    let(:app) do create(:oauth_application, name: "Test", redirect_uri: "https://example.com/test",
                                            uid: "uid-1234", secret: "secret-123") end

    it "returns the correct data" do
      expect(presenter.application_props(app)).to eq(
        {
          settings_pages: presenter.pages,
          application: {
            id: app.external_id,
            name: "Test",
            redirect_uri: "https://example.com/test",
            icon_url: app.icon_url,
            uid: "uid-1234",
            secret: "secret-123",
          }
        })
    end
  end

  describe "#advanced_props" do
    let!(:custom_domain) { create(:custom_domain, user: seller, domain: "example.com") }

    context "when custom domain is unverified" do
      before do
        allow(CustomDomainVerificationService).to receive(:new).and_return(double(process: true))
        seller.update!(notification_endpoint: "https://example.org")
      end

      it "returns correct props" do
        expect(presenter.advanced_props).to eq({
                                                 settings_pages: presenter.pages,
                                                 user_id: ObfuscateIds.encrypt(seller.id),
                                                 notification_endpoint: "https://example.org",
                                                 blocked_customer_emails: "",
                                                 custom_domain_name: "example.com",
                                                 custom_domain_verification_status: { message: "example.com domain is correctly configured!", success: true },
                                                 applications: [],
                                                 allow_deactivation: true,
                                                 formatted_balance_to_forfeit_on_account_deletion: nil,
                                               })
      end
    end

    context "when custom domain is verified" do
      before do
        custom_domain.mark_verified!
        create(:blocked_customer_object, seller:, object_value: "test1@example.com", blocked_at: Time.current)
        create(:blocked_customer_object, seller:, object_value: "test2@example.net", blocked_at: Time.current)
      end

      it "returns correct props" do
        expect(presenter.advanced_props).to eq({
                                                 settings_pages: presenter.pages,
                                                 user_id: ObfuscateIds.encrypt(seller.id),
                                                 notification_endpoint: "",
                                                 blocked_customer_emails: "test1@example.com\ntest2@example.net",
                                                 custom_domain_name: "example.com",
                                                 custom_domain_verification_status: nil,
                                                 applications: [],
                                                 allow_deactivation: true,
                                                 formatted_balance_to_forfeit_on_account_deletion: nil,
                                               })
      end
    end

    context "when user has unpaid balances" do
      before do
        @balance = create(:balance, user: seller, state: :unpaid, amount_cents: 25_00)
        Feature.activate_user(:delete_account_forfeit_balance, seller)
      end

      it "returns correct props" do
        expect(presenter.advanced_props).to eq({
                                                 settings_pages: presenter.pages,
                                                 user_id: ObfuscateIds.encrypt(seller.id),
                                                 notification_endpoint: "",
                                                 blocked_customer_emails: "",
                                                 custom_domain_name: "example.com",
                                                 custom_domain_verification_status: { message: "Domain verification failed. Please make sure you have correctly configured the DNS record for example.com.", success: false },
                                                 applications: [],
                                                 allow_deactivation: true,
                                                 formatted_balance_to_forfeit_on_account_deletion: Money.new(2500, :usd).format(no_cents_if_whole: true),
                                               })
      end
    end
  end

  describe "#third_party_analytics_props" do
    let!(:third_party_analytic) { create(:third_party_analytic, user: seller) }

    it "returns the correct props" do
      expect(presenter.third_party_analytics_props).to eq ({
        disable_third_party_analytics: false,
        google_analytics_id: "",
        facebook_pixel_id: "",
        skip_free_sale_analytics: false,
        facebook_meta_tag: "",
        enable_verify_domain_third_party_services: false,
        snippets: [{
          id: third_party_analytic.external_id,
          name: third_party_analytic.name,
          location: third_party_analytic.location,
          code: third_party_analytic.analytics_code,
          product: third_party_analytic.link.unique_permalink,
        }]
      })
    end

    context "when attributes are set" do
      let(:seller_options) do
        {
          disable_third_party_analytics: true,
          google_analytics_id: "G-123456789-1",
          facebook_pixel_id: "1234567899",
          skip_free_sale_analytics: true,
          facebook_meta_tag: '<meta name="facebook-domain-verification" content="y5fgkbh7x91y5tnt6yt3sttk" />',
          enable_verify_domain_third_party_services: true,
        }
      end

      let(:snippets) do
        [{
          id: third_party_analytic.external_id,
          name: third_party_analytic.name,
          location: third_party_analytic.location,
          code: third_party_analytic.analytics_code,
          product: third_party_analytic.link.unique_permalink,
        }]
      end

      before do
        seller.update!(seller_options)
      end

      it "returns correct values for props" do
        expect(presenter.third_party_analytics_props).to eq(
          seller_options.merge(snippets:)
        )
      end
    end
  end

  describe "#password_props" do
    let(:settings_pages) { %w(main profile team payments password third_party_analytics advanced) }

    context "when seller is registered using a social provider" do
      before do
        seller.update!(provider: "facebook")
      end

      it "returns the correct props" do
        expect(presenter.password_props).to eq(require_old_password: false, settings_pages:)
      end
    end

    context "when seller is registered using email" do
      it "returns the correct props" do
        expect(presenter.password_props).to eq(require_old_password: true, settings_pages:)
      end
    end
  end

  describe "#authorized_applications_props" do
    context "when some applications have no access grants" do
      let(:oauth_application1) { create(:oauth_application, owner: seller) }
      let!(:oauth_application2) { create(:oauth_application, owner: seller) }

      before do
        oauth_application1.get_or_generate_access_token
        @access_grant = Doorkeeper::AccessGrant.create!(application_id: oauth_application1.id, resource_owner_id: seller.id, redirect_uri: oauth_application1.redirect_uri,
                                                        expires_in: 1.day.from_now, scopes: Doorkeeper.configuration.public_scopes.join(" "))
      end

      it "returns props with only applications which have access grants" do
        expect(presenter.authorized_applications_props).to eq({
                                                                authorized_applications: [{
                                                                  name: oauth_application1.name,
                                                                  icon_url: oauth_application1.icon_url,
                                                                  is_own_app: true,
                                                                  first_authorized_at: @access_grant.created_at.iso8601,
                                                                  scopes: oauth_application1.scopes,
                                                                  id: oauth_application1.external_id,
                                                                }],
                                                                settings_pages: %w(main profile team payments authorized_applications password third_party_analytics advanced),
                                                              })
      end
    end

    context "when seller is not the owner of the application" do
      let(:oauth_application1) { create(:oauth_application) }

      before do
        create("doorkeeper/access_token", resource_owner_id: seller.id, application: oauth_application1, scopes: Doorkeeper.configuration.public_scopes.join(" "))
        @access_grant = Doorkeeper::AccessGrant.create!(application_id: oauth_application1.id, resource_owner_id: seller.id, redirect_uri: oauth_application1.redirect_uri,
                                                        expires_in: 1.day.from_now, scopes: Doorkeeper.configuration.public_scopes.join(" "))
      end
      it "returns props with is_own_app set to false" do
        expect(presenter.authorized_applications_props).to eq({
                                                                authorized_applications: [{
                                                                  name: oauth_application1.name,
                                                                  icon_url: oauth_application1.icon_url,
                                                                  is_own_app: false,
                                                                  first_authorized_at: @access_grant.created_at.iso8601,
                                                                  scopes: oauth_application1.scopes,
                                                                  id: oauth_application1.external_id,
                                                                }],
                                                                settings_pages: %w(main profile team payments authorized_applications password third_party_analytics advanced),
                                                              })
      end
    end

    it "returns authorized applications ordered by first_authorized_at" do
      oauth_application1 = create(:oauth_application, owner: seller)
      oauth_application2 = create(:oauth_application, owner: seller)
      oauth_application1.get_or_generate_access_token
      oauth_application2.get_or_generate_access_token

      access_grant1 = Doorkeeper::AccessGrant.create!(application_id: oauth_application1.id, resource_owner_id: seller.id, redirect_uri: oauth_application1.redirect_uri,
                                                      expires_in: 1.day.from_now, scopes: Doorkeeper.configuration.public_scopes.join(" "))

      access_grant2 = Doorkeeper::AccessGrant.create!(application_id: oauth_application2.id, resource_owner_id: seller.id, redirect_uri: oauth_application2.redirect_uri,
                                                      expires_in: 1.day.from_now, scopes: Doorkeeper.configuration.public_scopes.join(" "))


      access_grant1.update!(created_at: 1.day.ago)
      access_grant2.update!(created_at: 2.days.ago)

      expect(presenter.authorized_applications_props).to eq({
                                                              authorized_applications: [{
                                                                name: oauth_application2.name,
                                                                icon_url: oauth_application2.icon_url,
                                                                is_own_app: true,
                                                                first_authorized_at: access_grant2.created_at.iso8601,
                                                                scopes: oauth_application2.scopes,
                                                                id: oauth_application2.external_id,
                                                              }, {
                                                                name: oauth_application1.name,
                                                                icon_url: oauth_application1.icon_url,
                                                                is_own_app: true,
                                                                first_authorized_at: access_grant1.created_at.iso8601,
                                                                scopes: oauth_application1.scopes,
                                                                id: oauth_application1.external_id,
                                                              }],
                                                              settings_pages: %w(main profile team payments authorized_applications password third_party_analytics advanced),
                                                            })
    end
  end

  describe "#payments_props" do
    before do
      seller.update(payment_address: "")

      @base_props = {
        settings_pages: presenter.pages,
        is_form_disabled: false,
        should_show_country_modal: true,
        aus_backtax_details: {
          show_au_backtax_prompt: false,
          total_amount_to_au: "$0.00",
          au_backtax_amount: "$0.00",
          opt_in_date: nil,
          credit_creation_date: Date.today.next_month.beginning_of_month.strftime("%B %-d, %Y"),
          opted_in_to_au_backtax: false,
          legal_entity_name: "",
          are_au_backtaxes_paid: false,
          au_backtaxes_paid_date: nil,
        },
        stripe_connect: {
          has_connected_stripe: false,
          stripe_connect_account_id: nil,
          stripe_disconnect_allowed: true,
          supported_countries_help_text: "This feature is available in <a href='https://stripe.com/en-in/global'>all countries where Stripe operates</a>, except India, Indonesia, Malaysia, Mexico, Philippines, and Thailand.",
        },
        countries: Compliance::Countries.for_select.to_h,
        ip_country_code: nil,
        bank_account_details: {
          show_bank_account: false,
          show_paypal: true,
          card_data_handling_mode: "stripejs.0",
          is_a_card: false,
          card: nil,
          routing_number: nil,
          account_number_visual: nil,
          bank_account: nil,
        },
        paypal_address: seller.payment_address,
        show_verification_section: false,
        paypal_connect: {
          show_paypal_connect: false,
          allow_paypal_connect: false,
          unsupported_countries: PaypalMerchantAccountManager::COUNTRY_CODES_NOT_SUPPORTED_BY_PCP.map { |code| ISO3166::Country[code].common_name },
          email: nil,
          charge_processor_merchant_id: nil,
          charge_processor_verified: false,
          needs_email_confirmation: false,
          paypal_disconnect_allowed: true,
        },
        fee_info: {
          card_fee_info_text: "All sales will incur fees based on how customers find your product:\n\n• Direct sales: 10% + 50¢ Gumroad fee + 2.9% + 30¢ credit card fee.\n• Discover sales: 30% flat\n",
          paypal_fee_info_text: "All sales will incur fees based on how customers find your product:\n\n• Direct sales: 10% + 50¢ Gumroad fee + 2.9% + 30¢ PayPal fee.\n• Discover sales: 30% flat\n",
          connect_account_fee_info_text: "All sales will incur fees based on how customers find your product:\n\n• Direct sales: 10% + 50¢\n• Discover sales: 30% flat\n",
        },
        user: {
          country_supports_native_payouts: false,
          country_supports_iban: false,
          country_code: nil,
          payout_currency: nil,
          is_from_europe: false,
          need_full_ssn: false,
          individual_tax_id_needed_countries: [Compliance::Countries::USA.alpha2,
                                               Compliance::Countries::CAN.alpha2,
                                               Compliance::Countries::HKG.alpha2,
                                               Compliance::Countries::SGP.alpha2,
                                               Compliance::Countries::ARE.alpha2,
                                               Compliance::Countries::MEX.alpha2,
                                               Compliance::Countries::BGD.alpha2,
                                               Compliance::Countries::MOZ.alpha2,
                                               Compliance::Countries::URY.alpha2,
                                               Compliance::Countries::ARG.alpha2,
                                               Compliance::Countries::PER.alpha2,
                                               Compliance::Countries::CRI.alpha2,
                                               Compliance::Countries::CHL.alpha2,
                                               Compliance::Countries::COL.alpha2,
                                               Compliance::Countries::GTM.alpha2,
                                               Compliance::Countries::DOM.alpha2,
                                               Compliance::Countries::BOL.alpha2,
                                               Compliance::Countries::KAZ.alpha2,
                                               Compliance::Countries::PRY.alpha2,
                                               Compliance::Countries::PAK.alpha2],
          individual_tax_id_entered: false,
          business_tax_id_entered: false,
          requires_credit_card: false,
          can_connect_stripe: false,
          is_charged_paypal_payout_fee: true,
          joined_at: seller.created_at.iso8601,
        },
        compliance_info: {
          is_business: false,
          business_name: nil,
          business_name_kanji: nil,
          business_name_kana: nil,
          business_type: nil,
          business_street_address: nil,
          business_building_number: nil,
          business_street_address_kanji: nil,
          business_street_address_kana: nil,
          business_city: nil,
          business_state: nil,
          business_country: nil,
          business_zip_code: nil,
          business_phone: nil,
          job_title: nil,
          first_name: nil,
          last_name: nil,
          first_name_kanji: nil,
          last_name_kanji: nil,
          first_name_kana: nil,
          last_name_kana: nil,
          street_address: nil,
          building_number: nil,
          street_address_kanji: nil,
          street_address_kana: nil,
          city: nil,
          state: nil,
          country: nil,
          zip_code: nil,
          phone: nil,
          nationality: nil,
          dob_month: 0,
          dob_day: 0,
          dob_year: 0,
        },
        min_dob_year: Date.today.year - UserComplianceInfo::MINIMUM_DATE_OF_BIRTH_AGE,
        uae_business_types: UserComplianceInfo::BusinessTypes::BUSINESS_TYPES_UAE.map { |code, name| { code:, name: } },
        india_business_types: UserComplianceInfo::BusinessTypes::BUSINESS_TYPES_INDIA.map { |code, name| { code:, name: } },
        canada_business_types: UserComplianceInfo::BusinessTypes::BUSINESS_TYPES_CANADA.map { |code, name| { code:, name: } },
        states: {
          us: Compliance::Countries.subdivisions_for_select(Compliance::Countries::USA.alpha2).map { |code, name| { code:, name: } },
          ca: Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2).map { |code, name| { code:, name: } },
          au: Compliance::Countries.subdivisions_for_select(Compliance::Countries::AUS.alpha2).map { |code, name| { code:, name: } },
          mx: Compliance::Countries.subdivisions_for_select(Compliance::Countries::MEX.alpha2).map { |code, name| { code:, name: } },
          ae: Compliance::Countries.subdivisions_for_select(Compliance::Countries::ARE.alpha2).map { |code, name| { code:, name: } },
          ir: Compliance::Countries.subdivisions_for_select(Compliance::Countries::IRL.alpha2).map { |code, name| { code:, name: } },
          br: Compliance::Countries.subdivisions_for_select(Compliance::Countries::BRA.alpha2).map { |code, name| { code:, name: } },
        },
        saved_card: nil,
        formatted_balance_to_forfeit_on_country_change: nil,
        formatted_balance_to_forfeit_on_payout_method_change: nil,
        payouts_paused_internally: false,
        payouts_paused_by: nil,
        payouts_paused_for_reason: nil,
        payouts_paused_by_user: false,
        payout_threshold_cents: 1000,
        minimum_payout_threshold_cents: 1000,
        payout_frequency: User::PayoutSchedule::WEEKLY,
        payout_frequency_daily_supported: false,
      }
    end

    it "returns correct props for a seller who has no compliance info or payout method" do
      expect(presenter.payments_props).to eq(@base_props)
    end

    it "shows the AU backtax prompt when the feature is on and the creator owes more than $100 and the creator has received an email" do
      Feature.activate_user(:au_backtaxes, seller)
      seller.update!(au_backtax_owed_cents: 100_01)
      create(:australia_backtax_email_info, user: seller)

      expect(presenter.payments_props).to eq(@base_props.merge!({
                                                                  aus_backtax_details: @base_props[:aus_backtax_details].merge({
                                                                                                                                 show_au_backtax_prompt: true,
                                                                                                                                 au_backtax_amount: "$100.01"
                                                                                                                               }),
                                                                }))
    end

    it "does not show the AU backtax prompt when the creator owes less than $100" do
      Feature.activate_user(:au_backtaxes, seller)
      seller.update!(au_backtax_owed_cents: 99_00)
      create(:australia_backtax_email_info, user: seller)

      expect(presenter.payments_props).to eq(@base_props.merge!({
                                                                  aus_backtax_details: @base_props[:aus_backtax_details].merge({
                                                                                                                                 show_au_backtax_prompt: false,
                                                                                                                                 au_backtax_amount: "$99.00"
                                                                                                                               }),
                                                                }))
    end

    context "when seller is from the US" do
      before do
        @user_compliance_info = create(:user_compliance_info, user: seller)

        @user_details = @base_props[:user].merge({
                                                   country_supports_native_payouts: true,
                                                   country_code: "US",
                                                   payout_currency: "usd",
                                                   individual_tax_id_needed_countries: [Compliance::Countries::USA.alpha2,
                                                                                        Compliance::Countries::CAN.alpha2,
                                                                                        Compliance::Countries::HKG.alpha2,
                                                                                        Compliance::Countries::SGP.alpha2,
                                                                                        Compliance::Countries::ARE.alpha2,
                                                                                        Compliance::Countries::MEX.alpha2,
                                                                                        Compliance::Countries::BGD.alpha2,
                                                                                        Compliance::Countries::MOZ.alpha2,
                                                                                        Compliance::Countries::URY.alpha2,
                                                                                        Compliance::Countries::ARG.alpha2,
                                                                                        Compliance::Countries::PER.alpha2,
                                                                                        Compliance::Countries::CRI.alpha2,
                                                                                        Compliance::Countries::CHL.alpha2,
                                                                                        Compliance::Countries::COL.alpha2,
                                                                                        Compliance::Countries::GTM.alpha2,
                                                                                        Compliance::Countries::DOM.alpha2,
                                                                                        Compliance::Countries::BOL.alpha2,
                                                                                        Compliance::Countries::KAZ.alpha2,
                                                                                        Compliance::Countries::PRY.alpha2,
                                                                                        Compliance::Countries::PAK.alpha2],
                                                   individual_tax_id_entered: true,
                                                 })

        @compliance_info_details = @base_props[:compliance_info].merge({
                                                                         first_name: @user_compliance_info.first_name,
                                                                         last_name: @user_compliance_info.last_name,
                                                                         street_address: @user_compliance_info.street_address,
                                                                         city: @user_compliance_info.city,
                                                                         state: @user_compliance_info.state,
                                                                         country: @user_compliance_info.country_code,
                                                                         business_country: @user_compliance_info.country_code,
                                                                         zip_code: @user_compliance_info.zip_code,
                                                                         phone: @user_compliance_info.phone,
                                                                         nationality: @user_compliance_info.nationality,
                                                                         dob_day: @user_compliance_info.birthday.day,
                                                                         dob_month: @user_compliance_info.birthday.month,
                                                                         dob_year: @user_compliance_info.birthday.year
                                                                       })

        @base_us_props = @base_props.merge({
                                             should_show_country_modal: false,
                                             user: @user_details,
                                             compliance_info: @compliance_info_details,
                                             bank_account_details: @base_props[:bank_account_details].merge({
                                                                                                              show_bank_account: true,
                                                                                                              show_paypal: false,
                                                                                                            }),
                                             paypal_connect: @base_props[:paypal_connect].merge({
                                                                                                  show_paypal_connect: true,
                                                                                                  allow_paypal_connect: false,
                                                                                                }),
                                             aus_backtax_details: @base_props[:aus_backtax_details].merge({
                                                                                                            legal_entity_name: @user_compliance_info.first_and_last_name,
                                                                                                          }),
                                           })
      end

      it "returns correct props when seller does not have a payout method" do
        expect(presenter.payments_props).to eq(@base_us_props)
      end

      it "returns correct props when seller is eligible for PayPal Connect" do
        expect(presenter.payments_props).to eq(@base_us_props)
        expect(presenter.payments_props[:paypal_connect][:allow_paypal_connect]).to be false

        seller.mark_compliant!(author_name: "Iffy")
        allow_any_instance_of(User).to receive(:sales_cents_total).and_return(100_00)
        create(:payment_completed, user: seller)

        expect(presenter.payments_props).to eq(@base_us_props.merge!({
                                                                       paypal_connect: {
                                                                         show_paypal_connect: true,
                                                                         allow_paypal_connect: true,
                                                                         unsupported_countries: PaypalMerchantAccountManager::COUNTRY_CODES_NOT_SUPPORTED_BY_PCP.map { |code| ISO3166::Country[code].common_name },
                                                                         email: nil,
                                                                         charge_processor_merchant_id: nil,
                                                                         charge_processor_verified: false,
                                                                         needs_email_confirmation: false,
                                                                         paypal_disconnect_allowed: true,
                                                                       },
                                                                     }))
        expect(presenter.payments_props[:paypal_connect][:allow_paypal_connect]).to be true
      end

      it "returns correct props when seller has a bank account and a PayPal Connect account", :vcr do
        active_bank_account = create(:ach_account, user: seller)
        seller.mark_compliant!(author_name: "Iffy")
        allow_any_instance_of(User).to receive(:sales_cents_total).and_return(100_00)
        create(:payment_completed, user: seller)
        paypal_connect_account = create(:merchant_account_paypal, user: seller, charge_processor_merchant_id: "B66YJBBNCRW6L", charge_processor_verified_at: Time.current)

        bank_account_details = @base_us_props[:bank_account_details].merge({
                                                                             show_bank_account: true,
                                                                             show_paypal: false,
                                                                             routing_number: active_bank_account.routing_number,
                                                                             account_number_visual: active_bank_account.account_number_visual,
                                                                             bank_account: {
                                                                               account_holder_full_name: active_bank_account.account_holder_full_name,
                                                                             },
                                                                           })

        paypal_connect_details = @base_us_props[:paypal_connect].merge({
                                                                         show_paypal_connect: true,
                                                                         allow_paypal_connect: true,
                                                                         email: paypal_connect_account.paypal_account_details["primary_email"],
                                                                         charge_processor_merchant_id: paypal_connect_account.charge_processor_merchant_id,
                                                                         charge_processor_verified: true,
                                                                         needs_email_confirmation: false,
                                                                         paypal_disconnect_allowed: true,
                                                                       })

        expect(presenter.payments_props).to eq(@base_us_props.merge!({
                                                                       bank_account_details:,
                                                                       paypal_connect: paypal_connect_details,
                                                                     }))
      end

      it "returns correct props when seller has a Stripe Connect account" do
        stripe_connect_account = create(:merchant_account_stripe_connect, user: seller)

        expect(presenter.payments_props).to eq(@base_us_props.merge!({
                                                                       stripe_connect: {
                                                                         has_connected_stripe: true,
                                                                         stripe_connect_account_id: stripe_connect_account.charge_processor_merchant_id,
                                                                         stripe_disconnect_allowed: true,
                                                                         supported_countries_help_text: "This feature is available in <a href='https://stripe.com/en-in/global'>all countries where Stripe operates</a>, except India, Indonesia, Malaysia, Mexico, Philippines, and Thailand.",
                                                                       },
                                                                     }))
      end

      it "includes Stripe verification requests if applicable" do
        create(:merchant_account, user: seller)
        create(:user_compliance_info_request, user: seller, field_needed: UserComplianceInfoFields::Individual::TAX_ID)
        create(:user_compliance_info_request, user: seller, field_needed: UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID,
                                              verification_error: { code: "verification_failed_keyed_identity" })
        create(:user_compliance_info_request, user: seller, field_needed: UserComplianceInfoFields::Business::STRIPE_COMPANY_DOCUMENT_ID)

        expect(presenter.payments_props).to eq(@base_us_props.merge!({
                                                                       user: @base_us_props[:user].merge({ need_full_ssn: true }),
                                                                       show_verification_section: true,
                                                                     }))
      end
    end

    context "when the seller is from Brazil" do
      before do
        @user_compliance_info = create(:user_compliance_info, user: seller, country: "Brazil")
      end

      it "returns 0% Gumroad fee in the fee info text" do
        expect(presenter.payments_props[:fee_info][:connect_account_fee_info_text]).to eq "All sales will incur a 0% Gumroad fee."
      end
    end

    context "when the seller has custom fee set" do
      before do
        seller.update!(custom_fee_per_thousand: 75)
      end

      it "returns custom Gumroad fee percent in the fee info text" do
        expect(presenter.payments_props[:fee_info][:card_fee_info_text]).to eq "All sales will incur fees based on how customers find your product:\n\n• Direct sales: 7.5% + 50¢ Gumroad fee + 2.9% + 30¢ credit card fee.\n• Discover sales: 30% flat\n"
        expect(presenter.payments_props[:fee_info][:paypal_fee_info_text]).to eq "All sales will incur fees based on how customers find your product:\n\n• Direct sales: 7.5% + 50¢ Gumroad fee + 2.9% + 30¢ PayPal fee.\n• Discover sales: 30% flat\n"
        expect(presenter.payments_props[:fee_info][:connect_account_fee_info_text]).to eq "All sales will incur fees based on how customers find your product:\n\n• Direct sales: 7.5% + 50¢\n• Discover sales: 30% flat\n"
      end
    end

    context "when payouts are paused internally" do
      before do
        seller.update!(payouts_paused_internally: true)
      end

      it "returns true for payouts_paused_internally" do
        expect(presenter.payments_props[:payouts_paused_internally]).to eq(true)
      end
    end

    context "when payouts are paused by user" do
      before do
        seller.update!(payouts_paused_by_user: true)
      end

      it "returns true for payouts_paused_by_user" do
        expect(presenter.payments_props[:payouts_paused_by_user]).to eq(true)
      end
    end

    context "when seller has a payout threshold set" do
      before do
        seller.update!(payout_threshold_cents: 5000)
      end

      it "returns the payout threshold" do
        expect(presenter.payments_props[:payout_threshold_cents]).to eq(5000)
      end
    end

    context "when seller has a quarterly payout frequency" do
      before do
        seller.update!(payout_frequency: User::PayoutSchedule::QUARTERLY)
      end

      it "returns the quarterly payout frequency" do
        expect(presenter.payments_props[:payout_frequency]).to eq(User::PayoutSchedule::QUARTERLY)
      end
    end

    context "when seller can connect Stripe" do
      before do
        seller.update!(can_connect_stripe: true)
      end

      it "returns true for can_connect_stripe" do
        expect(presenter.payments_props[:user][:can_connect_stripe]).to eq(true)
      end
    end

    context "when the seller can receive PayPal payouts" do
      it "returns true for show_paypal if country does not support bank payouts" do
        create(:user_compliance_info, user: seller, country: "Brazil")
        seller.update!(payment_address: nil)

        expect(presenter.payments_props[:bank_account_details][:show_paypal]).to eq(true)
      end

      it "returns true for show_paypal if seller already has a PayPal payment address setup" do
        create(:user_compliance_info, user: seller, country: "United States")
        seller.update!(payment_address: nil)
        expect(presenter.payments_props[:bank_account_details][:show_paypal]).to eq(false)

        seller.update!(payment_address: "payme@example.com")
        expect(presenter.payments_props[:bank_account_details][:show_paypal]).to eq(true)

        seller.update!(payment_address: "")
        expect(presenter.payments_props[:bank_account_details][:show_paypal]).to eq(false)
      end
    end

    context "when seller's payouts are paused" do
      it "returns the payout pause source and reason if present" do
        seller.update!(payouts_paused_internally: true)
        expect(presenter.payments_props[:payouts_paused_internally]).to be(true)
        expect(presenter.payments_props[:payouts_paused_by_user]).to be(false)
        expect(presenter.payments_props[:payouts_paused_by]).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
        expect(presenter.payments_props[:payouts_paused_for_reason]).to eq(nil)

        seller.update!(payouts_paused_internally: true, payouts_paused_by: User.last.id)
        seller.comments.create!(
          author_id: User.last.id,
          content: "Chargeback rate too high.",
          comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED
        )
        expect(presenter.payments_props[:payouts_paused_internally]).to be(true)
        expect(presenter.payments_props[:payouts_paused_by_user]).to be(false)
        expect(presenter.payments_props[:payouts_paused_by]).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
        expect(presenter.payments_props[:payouts_paused_for_reason]).to eq("Chargeback rate too high.")

        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
        expect(presenter.payments_props[:payouts_paused_internally]).to be(true)
        expect(presenter.payments_props[:payouts_paused_by_user]).to be(false)
        expect(presenter.payments_props[:payouts_paused_by]).to eq(User::PAYOUT_PAUSE_SOURCE_STRIPE)
        expect(presenter.payments_props[:payouts_paused_for_reason]).to eq(nil)

        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
        expect(presenter.payments_props[:payouts_paused_by]).to eq(User::PAYOUT_PAUSE_SOURCE_SYSTEM)
        expect(presenter.payments_props[:payouts_paused_internally]).to be(true)
        expect(presenter.payments_props[:payouts_paused_by_user]).to be(false)
        expect(presenter.payments_props[:payouts_paused_for_reason]).to eq(nil)

        seller.update!(payouts_paused_internally: false, payouts_paused_by_user: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_USER)
        expect(presenter.payments_props[:payouts_paused_by]).to eq(User::PAYOUT_PAUSE_SOURCE_USER)
        expect(presenter.payments_props[:payouts_paused_internally]).to be(false)
        expect(presenter.payments_props[:payouts_paused_by_user]).to be(true)
        expect(presenter.payments_props[:payouts_paused_for_reason]).to eq(nil)

        seller.update!(payouts_paused_internally: false, payouts_paused_by_user: false, payouts_paused_by: nil)
        expect(presenter.payments_props[:payouts_paused_internally]).to be(false)
        expect(presenter.payments_props[:payouts_paused_by_user]).to be(false)
        expect(presenter.payments_props[:payouts_paused_by]).to eq(nil)
        expect(presenter.payments_props[:payouts_paused_for_reason]).to eq(nil)
      end
    end
  end
end
