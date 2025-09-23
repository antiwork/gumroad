# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Payments Settings Scenario", type: :system, js: true) do
  describe "PayPal section" do
    let(:user) { create(:user, name: "Gum") }

    before do
      allow_any_instance_of(User).to receive(:paypal_connect_allowed?).and_return(true)
      login_as user
    end

    it "render Payments tab navigation" do
      visit settings_payments_path

      expect(page).to have_tab_button("Payments", open: true)
    end

    it "shows the PayPal Connect section if country is supported" do
      create(:user_compliance_info, user:)

      visit settings_payments_path

      expect(page).to have_link("Connect with Paypal")
    end

    it "does not show the Paypal Connect section if country is not supported" do
      creator = create(:user)
      create(:user_compliance_info, user: creator, country: "India")
      login_as creator

      visit settings_payments_path

      expect(page).not_to have_link("Connect with Paypal")
    end

    it "keeps the PayPal Connect button enabled and does not show the notification when user has payment_address set up" do
      create(:user_compliance_info, user:)
      visit settings_payments_path
      expect(page).not_to have_alert(text: "You must set up credit card purchases above before enabling customers to pay with PayPal.")
      expect(page).not_to have_link(text: "Connect with Paypal", inert: true)
    end

    it "keeps the PayPal Connect button enabled even when user does not have either bank account or payment address set up" do
      creator = create(:user, payment_address: nil)
      create(:user_compliance_info, user: creator)
      login_as creator
      visit settings_payments_path
      expect(page).to have_link(text: "Connect with Paypal", inert: false)
    end

    it "keeps the PayPal Connect button enabled when user has stripe account connected" do
      creator = create(:user, payment_address: nil)
      create(:user_compliance_info, user: creator)
      create(:merchant_account_stripe_connect, user: creator)
      creator.check_merchant_account_is_linked = true
      creator.save!

      expect(creator.has_stripe_account_connected?).to be true
      login_as creator
      visit settings_payments_path
      expect(page).to have_link(text: "Connect with Paypal", inert: false)
    end

    it "keeps the PayPal Connect button enabled when user has bank account connected" do
      creator = create(:user, payment_address: nil)
      create(:user_compliance_info, user: creator)
      create(:ach_account, user: creator)

      login_as creator
      visit settings_payments_path
      expect(page).to have_link(text: "Connect with Paypal", inert: false)
    end

    it "keeps the PayPal Connect button enabled when user has debit card connected" do
      creator = create(:user, payment_address: nil)
      create(:user_compliance_info, user: creator)
      create(:card_bank_account, user: creator)

      login_as creator
      visit settings_payments_path
      expect(page).to have_link(text: "Connect with Paypal", inert: false)
    end

    it "keeps the PayPal Connect button disabled and shows the eligibility requirements when the user is not eligible" do
      create(:user_compliance_info, user:)
      allow_any_instance_of(User).to receive(:paypal_connect_allowed?).and_return(false)

      visit settings_payments_path
      expect(page).to have_link(text: "Connect with Paypal", inert: true)
      expect(page).to have_text("You must meet the following requirements in order to connect a PayPal account:")
      expect(page).to have_text("Your account must be marked as compliant")
      expect(page).to have_text("You must have earned at least $100")
      expect(page).to have_text("You must have received at least one successful payout")
    end

    context "when logged user has role admin" do
      let(:seller) { create(:named_seller) }

      include_context "with switching account to user as admin for seller"

      it "does not Connect with Paypal button link" do
        visit settings_payments_path

        expect(page).not_to have_link("Connect with Paypal")
      end
    end
  end

  describe "VAT section" do
    let(:user) { create(:user, name: "Gum") }

    before do
      login_as user
    end

    context "when user cannot disable vat" do
      before do
        allow_any_instance_of(User).to receive(:can_disable_vat?).and_return(false)
      end

      it "doesn't render section" do
        visit settings_payments_path
        expect(page).not_to have_text("VAT")
      end
    end
  end

  describe("Payout Information Collection", type: :system, js: true) do
    before do
      @user = create(:named_user, payment_address: nil)
      user_compliance_info = @user.fetch_or_build_user_compliance_info
      user_compliance_info.country = "United States"
      user_compliance_info.save!
      login_as @user
    end

    it "allows the (US based) creator to enter their kyc and ach information and it'll save it properly" do
      visit settings_payments_path

      fill_in("First name", with: "barnabas")
      fill_in("Last name", with: "barnabastein")
      fill_in("Address", with: "address_full_match")
      fill_in("City", with: "barnabasville")
      select("California", from: "State")
      fill_in("ZIP code", with: "12345")
      fill_in("Phone number", with: "(502) 254-1982")

      fill_in("Pay to the order of", with: "barnabas ngagy")
      fill_in("Routing number", with: "110000000")
      fill_in("Account number", with: "123456781")
      fill_in("Confirm account number", with: "123456781")

      expect(page).to have_content("Must exactly match the name on your bank account")
      expect(page).to have_content("Payouts will be made in USD.")

      select("1", from: "Day")
      select("1", from: "Month")
      select("1980", from: "Year")
      fill_in("Last 4 digits of SSN", with: "1235")

      click_on("Update settings")
      expect(page).to have_content("You must use a test bank account number. Try 000123456789 or see more options at https://stripe.com/docs/connect/testing#account-numbers.")

      fill_in("Account number", with: "000123456789")
      fill_in("Confirm account number", with: "000123456789")
      click_on("Update settings")
      expect(page).to have_content("Thanks! You're all set.")
      expect(page).to have_content("Routing number")

      compliance_info = @user.alive_user_compliance_info
      expect(compliance_info.first_name).to eq("barnabas")
      expect(compliance_info.last_name).to eq("barnabastein")
      expect(compliance_info.street_address).to eq("address_full_match")
      expect(compliance_info.city).to eq("barnabasville")
      expect(compliance_info.state).to eq("CA")
      expect(compliance_info.zip_code).to eq("12345")
      expect(compliance_info.phone).to eq("+15022541982")
      expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
      expect(compliance_info.individual_tax_id.decrypt("1234")).to eq("1235")
      expect(@user.active_ach_account.routing_number).to eq("110000000")
      expect(@user.active_ach_account.account_number_visual).to eq("******6789")
      expect(@user.stripe_account).to be_present
    end

    it "allows the creator to switch to debit card as payout method" do
      visit settings_payments_path

      choose "Debit Card"

      fill_in("First name", with: "barnabas")
      fill_in("Last name", with: "barnabastein")
      fill_in("Address", with: "123 barnabas st")
      fill_in("City", with: "barnabasville")
      select "California", from: "State"
      fill_in("ZIP code", with: "10110")

      select("1", from: "Day")
      select("1", from: "Month")
      select("1901", from: "Year")
      fill_in("Last 4 digits of SSN", with: "0000")
      fill_in("Phone number", with: "5022-541-982")

      within_fieldset "Card information" do
        within_frame do
          fill_in "Card number", with: "5200828282828210"
          fill_in "MM / YY", with: StripePaymentMethodHelper::EXPIRY_MMYY
          fill_in "CVC", with: "123"
        end
      end

      click_on "Update settings"

      expect(page).to have_content("Thanks! You're all set.")
      compliance_info = @user.reload.alive_user_compliance_info
      expect(compliance_info.first_name).to eq("barnabas")
      expect(compliance_info.last_name).to eq("barnabastein")
      expect(compliance_info.street_address).to eq("123 barnabas st")
      expect(compliance_info.city).to eq("barnabasville")
      expect(compliance_info.state).to eq("CA")
      expect(compliance_info.zip_code).to eq("10110")
      expect(compliance_info.birthday).to eq(Date.new(1901, 1, 1))
      expect(compliance_info.individual_tax_id.decrypt("1234")).to eq("0000")
      bank_account = @user.bank_accounts.alive.last
      expect(bank_account.type).to eq("CardBankAccount")
      expect(bank_account.account_number_last_four).to eq("8210")
    end

    it "allows the creator to update other info when they have a debit card connected" do
      creator = create(:user, payment_address: nil)
      create(:user_compliance_info, user: creator, phone: "+15022541982")
      create(:card_bank_account, user: creator)
      expect(creator.payout_frequency).to eq(User::PayoutSchedule::WEEKLY)

      login_as creator
      visit settings_payments_path
      expect(page).to have_select("Schedule", selected: "Weekly")
      select "Monthly", from: "Schedule"

      click_on "Update settings"

      expect(page).to have_alert(text: "Thanks! You're all set.")
      expect(creator.reload.payout_frequency).to eq(User::PayoutSchedule::MONTHLY)
      refresh
      expect(page).to have_select("Schedule", selected: "Monthly")
    end

    it "allows the creator to connect their Stripe account if they are from Brazil" do
      visit settings_payments_path
      expect(page).not_to have_field("Stripe")

      create(:user_compliance_info, user: @user, country: "Brazil")
      Feature.activate_user(:merchant_migration, @user)
      refresh
      choose "Stripe"
      expect(page).to have_content("This feature is available in all countries where Stripe operates, except India, Indonesia, Malaysia, Mexico, Philippines, and Thailand.")
      expect(page).to have_link("all countries where Stripe operates", href: "https://stripe.com/en-in/global")
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:stripe_connect] = OmniAuth::AuthHash.new JSON.parse(File.open("#{Rails.root}/spec/support/fixtures/stripe_connect_omniauth.json").read)
      click_on "Connect with Stripe"

      expect(page).to have_alert(text: "You have successfully connected your Stripe account!")
      expect(page).to have_button("Disconnect")
    end

    it "allows the creator to connect their Stripe account if they have can_connect_stripe flag enabled" do
      visit settings_payments_path
      expect(page).not_to have_field("Stripe")

      @user.update!(can_connect_stripe: true)
      refresh
      choose "Stripe"
      expect(page).to have_content("This feature is available in all countries where Stripe operates, except India, Indonesia, Malaysia, Mexico, Philippines, and Thailand.")
      expect(page).to have_link("all countries where Stripe operates", href: "https://stripe.com/en-in/global")
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:stripe_connect] = OmniAuth::AuthHash.new JSON.parse(File.open("#{Rails.root}/spec/support/fixtures/stripe_connect_omniauth.json").read)
      click_on "Connect with Stripe"

      expect(page).to have_alert(text: "You have successfully connected your Stripe account!")
      expect(page).to have_button("Disconnect")
    end

    it "allows the creator to disconnect their Stripe account" do
      create(:merchant_account_stripe_connect, user: @user)
      @user.check_merchant_account_is_linked = true
      @user.save!

      expect(@user.has_stripe_account_connected?).to be true

      visit settings_payments_path

      click_on "Disconnect Stripe account"

      expect(page).to have_content("Pay to the order of")

      expect(@user.reload.has_stripe_account_connected?).to be false
      expect(@user.stripe_connect_account).to be nil
    end

    it "does not allow the creator to disconnect their Stripe account if it is in use" do
      create(:merchant_account_stripe_connect, user: @user)
      @user.check_merchant_account_is_linked = true
      @user.save!

      expect(@user.has_stripe_account_connected?).to be true

      allow_any_instance_of(User).to receive(:stripe_disconnect_allowed?).and_return false

      visit settings_payments_path

      expect(page).to have_content("You cannot disconnect your Stripe account because it is being used for active subscription or preorder payments.")

      expect(find_button("Disconnect Stripe account", disabled: true)[:disabled]).to eq "true"
    end

    describe "US-based creator with information set" do
      before do
        create(:ach_account_stripe_succeed, user: @user)
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.first_name = "barnabas"
        new_user_compliance_info.last_name = "barnabastein"
        new_user_compliance_info.street_address = "address_full_match"
        new_user_compliance_info.city = "barnabasville"
        new_user_compliance_info.state = "CA"
        new_user_compliance_info.zip_code = "12345"
        new_user_compliance_info.phone = "+15022541982"
        new_user_compliance_info.birthday = Date.new(1980, 1, 1)
        new_user_compliance_info.individual_tax_id = "1234"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows the creator to edit their personal info without changing their ach account" do
        visit settings_payments_path

        old_ach_account = @user.active_ach_account

        fill_in("Address", with: "address_full_match")
        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.state).to eq("CA")
        expect(compliance_info.zip_code).to eq("12345")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(compliance_info.individual_tax_id.decrypt("1234")).to eq("1234")
        expect(@user.active_ach_account).to eq(old_ach_account)
      end

      it "allows the creator to edit their personal info that is locked at Stripe after account verification, and displays an error" do
        error_message = "You cannot change legal_entity[first_name] via API if an account is verified. Please contact us via https://support.stripe.com/contact if you need to change the information associated with this account."
        param = "legal_entity[first_name]"
        allow(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info).and_raise(Stripe::InvalidRequestError.new(error_message, param))
        old_ach_account = @user.active_ach_account
        @user.merchant_accounts << create(:merchant_account, charge_processor_verified_at: Time.current)

        visit settings_payments_path
        expect(page).to have_alert(visible: false)

        fill_in("First name", with: "barny")
        click_on("Update settings")

        within(:alert, text: "Your account could not be updated.")

        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.state).to eq("CA")
        expect(compliance_info.zip_code).to eq("12345")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(compliance_info.individual_tax_id.decrypt("1234")).to eq("1234")
        expect(@user.active_ach_account).to eq(old_ach_account)
      end

      it "allows the creator to see and edit their ach account" do
        @user.mark_compliant!(author_id: @user.id)
        visit settings_payments_path

        expect(page).to have_field("Routing number", with: "110000000", disabled: true)
        expect(page).to have_field("Account number", with: "******6789", disabled: true)

        click_on("Change account")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Routing number", with: "110000000")
        fill_in("Account number", with: "000111111116")
        fill_in("Confirm account number", with: "000111111116")
        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.state).to eq("CA")
        expect(compliance_info.zip_code).to eq("12345")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(compliance_info.individual_tax_id.decrypt("1234")).to eq("1234")
        expect(@user.active_ach_account.routing_number).to eq("110000000")
        expect(@user.active_ach_account.account_number_visual).to eq("******1116")
      end

      it "does not show PayPal as a payout method as bank payouts are supported" do
        stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)

        visit settings_payments_path

        expect(page).not_to have_field("PayPal")
      end

      it "allows the creator to update the name on their account" do
        @user.mark_compliant!(author_id: @user.id)
        visit settings_payments_path

        fill_in "Pay to the order of", with: "Gumhead Moneybags"
        click_on("Update settings")
        expect(page).to have_alert(text: "Thanks! You're all set.")

        expect(@user.active_bank_account.account_holder_full_name).to eq("Gumhead Moneybags")
      end

      it "displays the Stripe Connect embedded verification banner" do
        user = create(:user, username: nil, payment_address: nil)
        create(:user_compliance_info, user:, birthday: Date.new(1901, 1, 2))
        create(:ach_account_stripe_succeed, user:)
        create(:tos_agreement, user:)

        StripeMerchantAccountManager.create_account(user, passphrase: "1234")

        create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID)
        expect(user.user_compliance_info_requests.requested.
            where(field_needed: UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID).count).to eq(1)

        login_as user
        visit settings_payments_path
        expect(page).to have_selector("iframe[src*='connect-js.stripe.com']")
      end

      it "always shows the verification section with success message when verification is not needed" do
        user = create(:user, username: nil, payment_address: nil)
        create(:user_compliance_info, user:, birthday: Date.new(1901, 1, 2))
        create(:ach_account_stripe_succeed, user:)
        create(:tos_agreement, user:)

        StripeMerchantAccountManager.create_account(user, passphrase: "1234")

        expect(user.user_compliance_info_requests.requested.count).to eq(0)

        login_as user
        visit settings_payments_path

        expect(page).to have_section("Verification")

        expect(page).to have_status(text: "Your account details have been verified!")
      end

      it "does not show the verification section if Stripe account is not active" do
        user = create(:user, username: nil, payment_address: nil)
        create(:user_compliance_info, user:, birthday: Date.new(1901, 1, 2))
        create(:ach_account_stripe_succeed, user:)
        create(:tos_agreement, user:)

        merchant_account = StripeMerchantAccountManager.create_account(user, passphrase: "1234")

        create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::TAX_ID)
        expect(user.user_compliance_info_requests.requested.
          where(field_needed: UserComplianceInfoFields::Individual::TAX_ID).count).to eq(1)

        login_as user
        visit settings_payments_path
        expect(page).to have_selector("iframe[src*='connect-js.stripe.com']")

        merchant_account.mark_deleted!
        visit settings_payments_path
        expect(page).to have_status(text: "Your account details have been verified!")
      end

      context "when the creator has a business account" do
        let(:user) { create(:user, username: nil, payment_address: nil) }

        before do
          create(:user_compliance_info_business, user:, birthday: Date.new(1901, 1, 2))
          create(:ach_account_stripe_succeed, user:)
          create(:tos_agreement, user:)
        end

        let!(:merchant_account) { StripeMerchantAccountManager.create_account(user, passphrase: "1234") }

        before do
          expect(user.merchant_accounts.alive.count).to eq(1)

          create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Business::STRIPE_COMPANY_DOCUMENT_ID)
          expect(user.user_compliance_info_requests.requested.
              where(field_needed: UserComplianceInfoFields::Business::STRIPE_COMPANY_DOCUMENT_ID).count).to eq(1)

          login_as user
        end

        it "renders the account selector" do
          visit settings_payments_path

          within_section("Payout method", section_element: :section) do
            expect(page).to have_text("Account type")
            expect(page).to have_radio_button("Business", checked: true)
          end
        end

        it "allows the creator to switch to individual account" do
          expect(user.alive_user_compliance_info.is_business).to be(true)

          visit settings_payments_path

          within_section("Payout method", section_element: :section) do
            expect(page).to have_text("Account type")
            expect(page).to have_radio_button("Business", checked: true)

            choose "Individual"
            fill_in("Phone number", with: "(502) 254-1982")
          end

          expect do
            expect do
              click_on "Update settings"
              wait_for_ajax
              expect(page).to have_alert(text: "Thanks! You're all set.")
            end.to change { user.reload.user_compliance_infos.count }.by(1)
          end.to change { user.alive_user_compliance_info.is_business }.to be(false)
        end
      end

      it "does not allow saving a P.O. Box address" do
        visit settings_payments_path

        choose "Individual"
        fill_in "Street address", with: "P.O. Box 123, Smith street"
        expect do
          click_on "Update settings"
          expect(page).to have_status(text: "We require a valid physical US address. We cannot accept a P.O. Box as a valid address.")
        end.to_not change { @user.alive_user_compliance_info.reload.street_address }
        fill_in "Street address", with: "123, Smith street"
        expect do
          click_on "Update settings"
          wait_for_ajax
          expect(page).to have_alert(text: "Thanks! You're all set.")
        end.to change { @user.alive_user_compliance_info.reload.street_address }.to("123, Smith street")

        choose "Business"
        fill_in "Legal business name", with: "Acme"
        select "LLC", from: "Type"
        find_field("Address", match: :first).set("PO Box 123 North street")
        find_field("City", match: :first).set("Barnesville")
        find_field("State", match: :first).select("California")
        find_field("ZIP code", match: :first).set("12345")
        fill_in "Business phone number", with: "15052229876"
        fill_in "Business Tax ID (EIN, or SSN for sole proprietors)", with: "123456789"
        expect do
          click_on "Update settings"
          expect(page).to have_status(text: "We require a valid physical US address. We cannot accept a P.O. Box as a valid address.")
        end.to_not change { @user.alive_user_compliance_info.reload.business_street_address }
        find_field("Address", match: :first).set("123 North street")
        expect do
          click_on "Update settings"
          wait_for_ajax
          expect(page).to have_alert(text: "Thanks! You're all set.")
        end.to change { @user.alive_user_compliance_info.reload.business_street_address }.to("123 North street")
        fill_in "Street address", with: "po box 123 smith street"
        expect do
          click_on "Update settings"
          expect(page).to have_status(text: "We require a valid physical US address. We cannot accept a P.O. Box as a valid address.")
        end.to_not change { @user.alive_user_compliance_info.reload.street_address }
      end
    end

    describe "US business with non-US representative" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "United States"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
        expect(@user.active_bank_account).to be nil
        expect(@user.stripe_account).to be nil
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        choose "Business"

        fill_in("Legal business name", with: "US LLC with Brazilian rep")
        select("LLC", from: "Type")
        find_field("Address", match: :first).set("address_full_match")
        find_field("City", match: :first).set("NY")
        find_field("State", match: :first).select("New York")
        find_field("ZIP code", match: :first).set("10110")
        fill_in("Business phone number", with: "5052426789")
        fill_in("Business Tax ID (EIN, or SSN for sole proprietors)", with: "000000000")

        fill_in("First name", with: "Brazilian")
        fill_in("Last name", with: "Creator")
        all('select[id$="creator-country"]').last.select("Brazil")
        all('input[id$="creator-street-address"]').last.set("address_full_match")
        all('input[id$="creator-city"]').last.set("RDJ")
        all('select[id$="creator-state"]').last.select("Rio de Janeiro")
        find_field("Postal code").set("1001001")
        fill_in("Phone number", with: "987654321")
        fill_in("Cadastro de Pessoas Físicas (CPF)", with: "000.000.000-00")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "US LLC Brazilian Rep")
        fill_in("Routing number", with: "110000000")
        fill_in("Account number", with: "000123456789")
        fill_in("Confirm account number", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in USD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Routing number")

        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.is_business).to be true
        expect(compliance_info.business_name).to eq("US LLC with Brazilian rep")
        expect(compliance_info.business_street_address).to eq("address_full_match")
        expect(compliance_info.business_city).to eq("NY")
        expect(compliance_info.business_state).to eq("NY")
        expect(compliance_info.business_country).to eq("United States")
        expect(compliance_info.business_zip_code).to eq("10110")
        expect(compliance_info.business_phone).to eq("+15052426789")
        expect(compliance_info.business_type).to eq("llc")
        expect(compliance_info.business_tax_id.decrypt("1234")).to eq("000000000")
        expect(compliance_info.first_name).to eq("Brazilian")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("RDJ")
        expect(compliance_info.state).to eq("RJ")
        expect(compliance_info.country).to eq("Brazil")
        expect(compliance_info.zip_code).to eq("1001001")
        expect(compliance_info.phone).to eq("+55987654321")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.routing_number).to eq("110000000")
        expect(@user.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.stripe_account.charge_processor_merchant_id).to be_present
      end
    end

    describe "CA corporation requiring company registration verification document" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Canada"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
        expect(@user.active_bank_account).to be nil
        expect(@user.stripe_account).to be nil
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        choose "Business"

        fill_in("Legal business name", with: "CA Pvt Corp")
        select("Private Corporation", from: "Type")
        find_field("Address", match: :first).set("address_full_match")
        find_field("City", match: :first).set("Toronto")
        find_field("Province", match: :first).select("Ontario")
        find_field("Postal code", match: :first).set("M4C 1T2")
        fill_in("Business phone number", with: "5052426789")
        fill_in("Business Number (BN)", with: "111111111")

        fill_in("First name", with: "CA")
        fill_in("Last name", with: "Creator")
        fill_in("Job title", with: "General Manager")
        all('select[id$="creator-country"]').last.select("Canada")
        all('input[id$="creator-street-address"]').last.set("address_full_match")
        all('input[id$="creator-city"]').last.set("Toronto")
        all('select[id$="creator-province"]').last.select("Ontario")
        all('input[id$="creator-zip-code"]').last.set("M4C 1T2")
        fill_in("Phone number", with: "5052429876")
        fill_in("Social Insurance Number", with: "111111111")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "CA Pvt Corp")
        fill_in("Transit #", with: "11000")
        fill_in("Institution #", with: "000")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in CAD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Transit and institution #")

        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.is_business).to be true
        expect(compliance_info.business_name).to eq("CA Pvt Corp")
        expect(compliance_info.business_street_address).to eq("address_full_match")
        expect(compliance_info.business_city).to eq("Toronto")
        expect(compliance_info.business_state).to eq("ON")
        expect(compliance_info.business_country).to eq("Canada")
        expect(compliance_info.business_zip_code).to eq("M4C 1T2")
        expect(compliance_info.business_phone).to eq("+15052426789")
        expect(compliance_info.business_type).to eq("private_corporation")
        expect(compliance_info.business_tax_id.decrypt("1234")).to eq("111111111")
        expect(compliance_info.first_name).to eq("CA")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.job_title).to eq("General Manager")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Toronto")
        expect(compliance_info.state).to eq("ON")
        expect(compliance_info.country).to eq("Canada")
        expect(compliance_info.zip_code).to eq("M4C 1T2")
        expect(compliance_info.phone).to eq("+15052429876")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.routing_number).to eq("11000-000")
        expect(@user.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.stripe_account.charge_processor_merchant_id).to be_present

        create(:user_compliance_info_request, user: @user, field_needed: UserComplianceInfoFields::Business::COMPANY_REGISTRATION_VERIFICATION)

        visit settings_payments_path
        expect(page).to have_selector("iframe[src*='connect-js.stripe.com']")
      end
    end

    it "just shows payment address to a US creator with a payment address setup" do
      @user.update(payment_address: "barny@paypal.com")
      visit settings_payments_path
      expect(page).to have_field("PayPal Email")
    end

    it "allows US creator to switch to ACH" do
      @user.update(payment_address: "barny@paypal.com")
      visit settings_payments_path
      click_on "Switch to direct deposit"
      expect(page).to_not have_field("PayPal Email")
    end

    it "keeps the creator on PayPal payouts if the bank account info is not entered" do
      @user.update!(payment_address: "paypal-gr-integspecs@gumroad.com")

      visit settings_payments_path
      click_on "Switch to direct deposit"
      expect(page).to_not have_field("PayPal Email")
      expect(page).to have_field("Pay to the order of")
      expect(@user.reload.payment_address).to eq("paypal-gr-integspecs@gumroad.com")

      refresh
      expect(page).to have_field("PayPal Email")
      expect(page).to_not have_field("Pay to the order of")

      click_on "Switch to direct deposit"
      expect(page).to_not have_field("PayPal Email")
      fill_in("First name", with: "barnabas")
      fill_in("Last name", with: "barnabastein")
      fill_in("Address", with: "address_full_match")
      fill_in("City", with: "barnabasville")
      select("California", from: "State")
      fill_in("ZIP code", with: "12345")
      fill_in("Phone number", with: "(502) 254-1982")
      fill_in("Pay to the order of", with: "barnabas ngagy")
      fill_in("Routing number", with: "110000000")
      fill_in("Account number", with: "000123456789")
      fill_in("Confirm account number", with: "000123456789")
      select("1", from: "Day")
      select("1", from: "Month")
      select("1980", from: "Year")
      fill_in("Last 4 digits of SSN", with: "1235")
      click_on("Update settings")
      expect(page).to have_content("Thanks! You're all set.")

      refresh
      expect(page).to_not have_field("PayPal Email")
      expect(page).to have_field("Pay to the order of")
      expect(@user.reload.payment_address).to eq("")
      expect(@user.active_bank_account).to_not be nil
    end

    it "does not allow creator to save payout info unless confirmed email is present" do
      @user.unconfirmed_email = @user.email
      @user.email = nil
      @user.save!(validate: false)

      visit settings_payments_path
      fill_in("First name", with: "barnabas")
      fill_in("Last name", with: "barnabastein")
      fill_in("Address", with: "address_full_match")
      fill_in("City", with: "barnabasville")
      select("California", from: "State")
      fill_in("ZIP code", with: "12345")
      fill_in("Phone number", with: "5022541982")
      fill_in("Pay to the order of", with: "barnabas ngagy")
      fill_in("Routing number", with: "110000000")
      fill_in("Account number", with: "000123456789")
      fill_in("Confirm account number", with: "000123456789")
      select("1", from: "Day")
      select("1", from: "Month")
      select("1980", from: "Year")
      fill_in("Last 4 digits of SSN", with: "1235")
      click_on("Update settings")
      expect(page).to have_status(text: "You have to confirm your email address before you can do that.")
      expect(@user.reload.user_compliance_infos.count).to eq(1)
      expect(@user.reload.alive_user_compliance_info.first_name).not_to eq("barnabas")

      @user.confirm
      click_on("Update settings")
      expect(page).to have_alert(text: "Thanks! You're all set.")
      expect(@user.reload.user_compliance_infos.count).to eq(2)
      expect(@user.reload.alive_user_compliance_info.first_name).to eq("barnabas")
    end

    describe "update country" do
      before do
        create(:ach_account_stripe_succeed, user: @user)
        create(:user_compliance_info, user: @user)
        create(:merchant_account, user: @user, charge_processor_merchant_id: "acct_12345", country: "US", currency: "usd")
        @update_country = "United Kingdom"
      end

      it "shows confirmation modal and updates the country if confirmed" do
        visit settings_payments_path
        expect(find(:select, "Country")).to have_selector(:option, "Somalia (not supported)", disabled: true)
        select(@update_country, from: "Country")

        within "dialog" do
          expect(page).to have_content "Confirm country change"
          expect(page).to have_content "You are about to change your country. Please click \"Confirm\" to continue."
          expect(page).to have_button "Cancel"
          expect(page).to have_button "Confirm"
          click_on "Confirm"
        end
        wait_for_ajax
        expect(page).to have_alert(text: "Your country has been updated!")
      end

      context "when creator has balance" do
        it "shows confirmation modal for creator" do
          balance = create(:balance,
                           user: @user,
                           merchant_account_id: @user.stripe_account.id,
                           currency: "usd",
                           amount_cents: 123_45,
                           holding_currency: "usd",
                           holding_amount_cents: 123_45)
          stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)

          visit settings_payments_path
          select(@update_country, from: "Country")

          within "dialog" do
            expect(page).to have_content "Confirm country change"
            expect(page).to have_content "Due to limitations with our payments provider, switching your country to #{@update_country} means that you will have to forfeit your remaining balance of #{@user.formatted_balance_to_forfeit(:country_change)}"
            expect(page).to have_content "Please confirm that you're okay forfeiting your balance by typing \"I understand\" below and clicking Confirm."
            fill_in "I understand", with: "I understand"
            click_on "Confirm"
          end

          wait_for_ajax
          expect(page).to have_alert(text: "Your country has been updated!")
          expect(balance.reload.unpaid?).to be false
          expect(balance.forfeited?).to be true
          expect(@user.reload.credits.last).to be nil
        end
      end
    end

    describe "switch from bank payouts to PayPal" do
      before do
        create(:ach_account_stripe_succeed, user: @user)
        create(:user_compliance_info_uae, user: @user)
        create(:merchant_account, user: @user, charge_processor_merchant_id: "acct_1234", country: "AE", currency: "aed")
      end

      context "creator does not have balance that needs to be forfeited" do
        it "does not show the confirmation modal and updates the payout method" do
          visit settings_payments_path
          choose "PayPal"

          fill_in("First name", with: "barnabas")
          fill_in("Last name", with: "barnabastein")
          fill_in("Address", with: "address_full_match")
          fill_in("City", with: "barnabasville")
          select("Abu Dhabi", from: "Province")
          fill_in("Phone number", with: "98765432")
          fill_in("Postal code", with: "51133")

          select("1", from: "Day")
          select("1", from: "Month")
          select("1980", from: "Year")
          select("India", from: "Nationality")
          fill_in("Emirates ID", with: "000000000000000")

          expect(page).to have_status(text: "PayPal payouts are subject to a 2% processing fee.")
          fill_in("PayPal Email", with: "uaecr@gumroad.com")

          click_on("Update settings")

          wait_for_ajax
          expect(page).to have_alert(text: "Thanks! You're all set.")
          expect(@user.reload.stripe_account).to be nil
          expect(@user.active_bank_account).to be nil
          expect(@user.payment_address).to eq "uaecr@gumroad.com"
        end
      end

      context "when creator has balance that needs to be forfeited" do
        it "shows confirmation modal and updates the payout method if confirmed" do
          balance = create(:balance,
                           user: @user,
                           merchant_account_id: @user.stripe_account.id,
                           currency: "usd",
                           amount_cents: 123_45,
                           holding_currency: "aed",
                           holding_amount_cents: 150_00)
          stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)

          visit settings_payments_path
          choose "PayPal"

          fill_in("First name", with: "barnabas")
          fill_in("Last name", with: "barnabastein")
          fill_in("Address", with: "address_full_match")
          fill_in("City", with: "barnabasville")
          select("Abu Dhabi", from: "Province")
          fill_in("Phone number", with: "98765432")
          fill_in("Postal code", with: "51133")

          select("1", from: "Day")
          select("1", from: "Month")
          select("1980", from: "Year")
          select("India", from: "Nationality")
          fill_in("Emirates ID", with: "000000000000000")

          expect(page).to have_status(text: "PayPal payouts are subject to a 2% processing fee.")
          fill_in("PayPal Email", with: "uaecr@gumroad.com")

          click_on("Update settings")

          within "dialog" do
            expect(page).to have_content "Confirm payout method change"
            expect(page).to have_content "Due to limitations with our payments provider, changing payout method from bank account to PayPal means that you will have to forfeit your existing balance of #{@user.formatted_balance_to_forfeit(:payout_method_change)}"
            expect(page).to have_content "Please confirm that you're okay forfeiting your balance by typing \"I understand\" below and clicking Confirm."
            click_on "Cancel"
          end

          expect(page).not_to have_content "Confirm payout method change"
          click_on("Update settings")

          within "dialog" do
            expect(page).to have_content "Confirm payout method change"
            expect(page).to have_content "Due to limitations with our payments provider, changing payout method from bank account to PayPal means that you will have to forfeit your existing balance of #{@user.formatted_balance_to_forfeit(:payout_method_change)}"
            expect(page).to have_content "Please confirm that you're okay forfeiting your balance by typing \"I understand\" below and clicking Confirm."
            fill_in "I understand", with: "I understand"
            click_on "Confirm"
          end

          wait_for_ajax
          expect(page).to have_alert(text: "Thanks! You're all set.")
          expect(@user.reload.stripe_account).to be nil
          expect(@user.active_bank_account).to be nil
          expect(@user.payment_address).to eq "uaecr@gumroad.com"
          expect(balance.reload.unpaid?).to be false
          expect(balance.reload.forfeited?).to be true
          expect(@user.reload.credits.last).to be nil
        end
      end
    end

    it "does not show a confirmation banner if a user's account details are in good standing" do
      @user.mark_compliant!(author_id: @user.id)

      visit settings_payments_path

      expect(page).not_to have_alert(text: "Please confirm your payout account.", exact: false)
    end

    describe "Brazilian creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Brazil"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "prevents saving incomplete information" do
        visit settings_payments_path

        expect(page).to_not have_alert

        click_on("Update settings")
        expect(page).to_not have_alert(text: "Thanks! You're all set.")
        expect(find_field("PayPal Email")["aria-invalid"]).to eq "true"

        fill_in("PayPal Email", with: "valid@gumroad.com")
        click_on("Update settings")
        expect(page).to_not have_alert(text: "Thanks! You're all set.")
        expect(find_field("First name")["aria-invalid"]).to eq "true"

        fill_in("First name", with: "barnabas")
        click_on("Update settings")
        expect(page).to_not have_alert(text: "Thanks! You're all set.")
        expect(find_field("Last name")["aria-invalid"]).to eq "true"

        fill_in("Last name", with: "barnabastein")
        click_on("Update settings")
        expect(page).to_not have_alert(text: "Thanks! You're all set.")
        expect(find_field("Address")["aria-invalid"]).to eq "true"

        fill_in("Address", with: "address_full_match")
        click_on("Update settings")
        expect(page).to_not have_alert(text: "Thanks! You're all set.")
        expect(find_field("City")["aria-invalid"]).to eq "true"

        fill_in("City", with: "barnabasville")
        click_on("Update settings")
        expect(page).to_not have_alert(text: "Thanks! You're all set.")
        expect(find_field("Postal code")["aria-invalid"]).to eq "true"

        fill_in("Postal code", with: "12345")
        click_on("Update settings")
        expect(page).to_not have_alert(text: "Thanks! You're all set.")
        expect(find_field("Phone number")["aria-invalid"]).to eq "true"
        expect(page).to have_status(text: "Please enter your full phone number, starting with a \"+\" and your country code.")

        fill_in("Phone number", with: "5022541982")
        click_on("Update settings")
        expect(page).to_not have_alert(text: "Thanks! You're all set.")
        expect(find_field("Day")["aria-invalid"]).to eq "true"

        select("1", from: "Day")
        click_on("Update settings")
        expect(page).to_not have_alert(text: "Thanks! You're all set.")
        expect(find_field("Month")["aria-invalid"]).to eq "true"

        select("1", from: "Month")
        click_on("Update settings")
        expect(page).to_not have_alert(text: "Thanks! You're all set.")
        expect(find_field("Year")["aria-invalid"]).to eq "true"

        select("1980", from: "Year")
        click_on("Update settings")
        expect(page).to_not have_alert(text: "Thanks! You're all set.")
      end

      it "allows the (non-US based) creator to enter their kyc and paypal email address and it'll save it properly" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "5022541982")
        fill_in("Postal code", with: "12345")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("PayPal Email", with: "valid@gumroad.com")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("12345")
        expect(compliance_info.phone).to eq("+555022541982")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.payment_address).to eq("valid@gumroad.com")
        expect(@user.reload.active_bank_account).to be nil
      end

      it "allows saving a P.O. Box address" do
        visit settings_payments_path

        fill_in "PayPal Email", with: "creator@example.com"
        fill_in "First name", with: "John"
        fill_in "Last name", with: "Doe"
        fill_in "Address", with: "P.O. Box 123, Tokyo central hall"
        fill_in "City", with: "Tokyo"
        fill_in "Postal code", with: "12345"
        fill_in "Phone number", with: "5022541982"
        select("1", from: "Day")
        select("1", from: "Month")
        select("1990", from: "Year")
        expect do
          click_on "Update settings"
          wait_for_ajax
          expect(page).to have_alert(text: "Thanks! You're all set.")
        end.to change { @user.alive_user_compliance_info.reload.street_address }.to("P.O. Box 123, Tokyo central hall")
      end
    end

    describe "EU creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Germany"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "5022541982")
        fill_in("Postal code", with: "12345")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "DE89370400440532013000")
        fill_in("Confirm IBAN", with: "DE89370400440532013000")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in EUR.")

        click_on("Update settings")
        expect(page).to have_content("Invalid DE postal code")

        fill_in("Postal code", with: "01067")
        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("01067")
        expect(compliance_info.phone).to eq("+495022541982")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("DE89370400440532013000")
      end
    end

    describe "HK creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Hong Kong"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "98761234")
        fill_in("Postal code", with: "12345")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")
        fill_in("Hong Kong ID Number", with: "000000000")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Clearing Code", with: "110")
        fill_in("Branch code", with: "000")
        fill_in("Account #", with: "000123456")
        fill_in("Confirm account #", with: "000123456")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in HKD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Clearing and branch code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("12345")
        expect(compliance_info.phone).to eq("+85298761234")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456")
      end
    end

    describe "CA business" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Canada"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
        expect(@user.active_bank_account).to be nil
        expect(@user.stripe_account).to be nil
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        choose "Business"

        fill_in("Legal business name", with: "CA LLC")
        select("Private Partnership", from: "Type")
        find_field("Address", match: :first).set("address_full_match")
        find_field("City", match: :first).set("Toronto")
        all('select[id$="business-province"]').last.select("Ontario")
        find_field("Postal code", match: :first).set("M4C 1T2")
        fill_in("Business phone number", with: "5052426789")
        fill_in("Business Number (BN)", with: "000000000")

        fill_in("First name", with: "Canadian")
        fill_in("Last name", with: "Manager")
        fill_in("Job title", with: "Sales Manager")
        all('select[id$="creator-country"]').last.select("Canada")
        all('input[id$="creator-street-address"]').last.set("address_full_match")
        all('input[id$="creator-city"]').last.set("Toronto")
        all('select[id$="creator-province"]').last.select("Ontario")
        all('input[id$="creator-zip-code"]').last.set("M4C 1T2")
        fill_in("Phone number", with: "5052426789")
        fill_in("Social Insurance Number", with: "000000000")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "CA LLC")
        fill_in("Transit #", with: "110000")
        fill_in("Institution #", with: "000")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in CAD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Transit and institution #")
        expect(page).to have_field("Job title", with: "Sales Manager")

        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.is_business).to be true
        expect(compliance_info.business_name).to eq("CA LLC")
        expect(compliance_info.business_street_address).to eq("address_full_match")
        expect(compliance_info.business_city).to eq("Toronto")
        expect(compliance_info.business_state).to eq("ON")
        expect(compliance_info.business_country).to eq("Canada")
        expect(compliance_info.business_zip_code).to eq("M4C 1T2")
        expect(compliance_info.business_phone).to eq("+15052426789")
        expect(compliance_info.job_title).to eq("Sales Manager")
        expect(compliance_info.business_type).to eq("private_partnership")
        expect(compliance_info.business_tax_id.decrypt("1234")).to eq("000000000")
        expect(compliance_info.first_name).to eq("Canadian")
        expect(compliance_info.last_name).to eq("Manager")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Toronto")
        expect(compliance_info.state).to eq("ON")
        expect(compliance_info.country).to eq("Canada")
        expect(compliance_info.zip_code).to eq("M4C 1T2")
        expect(compliance_info.phone).to eq("+15052426789")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.routing_number).to eq("11000-000")
        expect(@user.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.stripe_account.charge_processor_merchant_id).to be_present
      end
    end

    describe "SG creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Singapore"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "98761234")
        fill_in("Postal code", with: "546080")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")
        fill_in("NRIC number / FIN", with: "000000000")
        select("India", from: "Nationality")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Bank code", with: "1100")
        fill_in("Branch code", with: "000")
        fill_in("Account #", with: "000123456")
        fill_in("Confirm account #", with: "000123456")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in SGD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank and branch code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("546080")
        expect(compliance_info.phone).to eq("+6598761234")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456")
      end
    end

    describe "TH creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Thailand"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "987654321")
        fill_in("Postal code", with: "10169")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Bank code", with: "999")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in THB.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("10169")
        expect(compliance_info.phone).to eq("+66987654321")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
      end
    end

    describe "BG creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Bulgaria"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "987654321")
        fill_in("Postal code", with: "1138")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "BG80BNBG96611020345678")
        fill_in("Confirm IBAN", with: "BG80BNBG96611020345678")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in BGN.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("1138")
        expect(compliance_info.phone).to eq("+359987654321")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("BG80BNBG96611020345678")
      end
    end

    describe "DK creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Denmark"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "98765432")
        fill_in("Postal code", with: "1050")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "DK5000400440116243")
        fill_in("Confirm IBAN", with: "DK5000400440116243")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in DKK.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("1050")
        expect(compliance_info.phone).to eq("+4598765432")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("DK5000400440116243")
      end
    end

    describe "HU creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Hungary"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "98765432")
        fill_in("Postal code", with: "1014")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "HU42117730161111101800000000")
        fill_in("Confirm IBAN", with: "HU42117730161111101800000000")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in HUF.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("1014")
        expect(compliance_info.phone).to eq("+3698765432")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("HU42117730161111101800000000")
      end
    end

    describe "KR creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Korea, Republic of"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "23123456")
        fill_in("Postal code", with: "10169")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Bank code", with: "SGSEKRSLXXX")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in KRW.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("10169")
        expect(compliance_info.phone).to eq("+8223123456")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
      end
    end

    describe "AE business" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "United Arab Emirates"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        choose "Business"

        fill_in("Legal business name", with: "uae biz")
        select("LLC", from: "Type")
        find_field("Address", match: :first).set("address_full_match")
        find_field("City", match: :first).set("Dubai")
        find_field("Province", match: :first).select("Dubai")
        find_field("Postal code", match: :first).set("51133")
        fill_in("Business phone number", with: "98765432")
        fill_in("Company tax ID", with: "000000000")

        check "Same as business"
        fill_in("First name", with: "uae")
        fill_in("Last name", with: "creator")
        fill_in("Phone number", with: "98765432")
        select("India", from: "Nationality")
        fill_in("Emirates ID", with: "000000000000000")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "uae biz")
        fill_in("IBAN", with: "AE070331234567890123456")
        fill_in("Confirm IBAN", with: "AE070331234567890123456")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in AED.")
        expect(page).not_to have_content("Individual accounts from the UAE are not supported. Please use a business account.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("uae")
        expect(compliance_info.last_name).to eq("creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Dubai")
        expect(compliance_info.zip_code).to eq("51133")
        expect(compliance_info.phone).to eq("+97198765432")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("AE070331234567890123456")
      end

      it "allows the creator to enter their business vat number and updates it on stripe connect account" do
        user = create(:user, username: nil, payment_address: nil)
        create(:user_compliance_info_uae_business, user:, birthday: Date.new(1901, 1, 2))
        create(:uae_bank_account, user:)
        create(:tos_agreement, user:)

        StripeMerchantAccountManager.create_account(user, passphrase: "1234")
        expect(user.merchant_accounts.alive.count).to eq(1)
        expect(user.merchant_accounts.alive.last.charge_processor_merchant_id).to be_present

        create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Business::VAT_NUMBER)

        login_as user
        visit settings_payments_path
        expect(page).to have_selector("iframe[src*='connect-js.stripe.com']")
      end
    end

    describe "AE individual" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "United Arab Emirates"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows entering KYC info and PayPal email" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        select("Abu Dhabi", from: "Province")
        fill_in("Phone number", with: "98765432")
        fill_in("Postal code", with: "51133")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")
        select("India", from: "Nationality")
        fill_in("Emirates ID", with: "000000000000000")

        expect(page).to have_status(text: "PayPal payouts are subject to a 2% processing fee.")
        fill_in("PayPal Email", with: "uaecr@gumroad.com")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("51133")
        expect(compliance_info.phone).to eq("+97198765432")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.payment_address).to eq("uaecr@gumroad.com")
      end

      it "does not show PayPal payout fee note if user is exempt" do
        @user.update!(paypal_payout_fee_waived: true)

        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        select("Abu Dhabi", from: "Province")
        fill_in("Phone number", with: "98765432")
        fill_in("Postal code", with: "51133")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")
        select("India", from: "Nationality")
        fill_in("Emirates ID", with: "000000000000000")

        expect(page).not_to have_status(text: "PayPal payouts are subject to a 2% processing fee.")
        fill_in("PayPal Email", with: "uaecr@gumroad.com")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("51133")
        expect(compliance_info.phone).to eq("+97198765432")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.payment_address).to eq("uaecr@gumroad.com")
      end
    end

    describe "IL creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Israel"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "98765432")
        fill_in("Postal code", with: "9103401")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "IL620108000000099999999")
        fill_in("Confirm IBAN", with: "IL620108000000099999999")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in ILS.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("9103401")
        expect(compliance_info.phone).to eq("+97298765432")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("IL620108000000099999999")
      end
    end

    describe "TT creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Trinidad and Tobago"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "8686230339")
        fill_in("Postal code", with: "150123")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Bank code", with: "999")
        fill_in("Branch code", with: "00001")
        fill_in("Account #", with: "00567890123456789")
        fill_in("Confirm account #", with: "00567890123456789")
        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in TTD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank and branch code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("150123")
        expect(compliance_info.phone).to eq("+18686230339")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("00567890123456789")
      end
    end

    describe "PH creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Philippines"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "285272345")
        fill_in("Postal code", with: "1002")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Bank Identifier Code (BIC)", with: "BCDEFGHI123")
        fill_in("Account #", with: "01567890123456789")
        fill_in("Confirm account #", with: "01567890123456789")
        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in PHP.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank Identifier Code (BIC)")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("1002")
        expect(compliance_info.phone).to eq("+63285272345")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("01567890123456789")
      end
    end

    describe "RO creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Romania"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "bucharest")
        fill_in("Phone number", with: "219876543")
        fill_in("Postal code", with: "010051")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "RO49AAAA1B31007593840000")
        fill_in("Confirm IBAN", with: "RO49AAAA1B31007593840000")
        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in RON.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("bucharest")
        expect(compliance_info.zip_code).to eq("010051")
        expect(compliance_info.phone).to eq("+40219876543")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("RO49AAAA1B31007593840000")
      end
    end

    describe "SE creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Sweden"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "stockholm")
        fill_in("Phone number", with: "98765432")
        fill_in("Postal code", with: "10465")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "SE3550000000054910000003")
        fill_in("Confirm IBAN", with: "SE3550000000054910000003")
        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in SEK.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("stockholm")
        expect(compliance_info.zip_code).to eq("10465")
        expect(compliance_info.phone).to eq("+4698765432")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("SE3550000000054910000003")
      end
    end

    describe "MX creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Mexico"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "mexico city")
        fill_in("Phone number", with: "9876543210")
        fill_in("Postal code", with: "01000")
        select("México", from: "State")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")
        fill_in("Personal RFC", with: "0000000000000")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Account number", with: "000000001234567897")
        fill_in("Confirm account number", with: "000000001234567897")
        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MXN.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("mexico city")
        expect(compliance_info.state).to eq("MEX")
        expect(compliance_info.zip_code).to eq("01000")
        expect(compliance_info.phone).to eq("+529876543210")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(compliance_info.individual_tax_id.decrypt("1234")).to eq("0000000000000")
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000000001234567897")
      end
    end

    describe "CO creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Colombia"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "3234567890")
        fill_in("Postal code", with: "411088")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        select("Checking", from: "Account Type")
        fill_in("Bank Code", with: "060")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")
        fill_in("Cédula de Ciudadanía (CC)", with: "1.123.123.123")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in COP.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("411088")
        expect(compliance_info.phone).to eq("+573234567890")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.reload.active_bank_account.send(:routing_number)).to eq("060")
        expect(@user.reload.active_bank_account.send(:account_type)).to eq("checking")
      end
    end

    describe "AR creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Argentina"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "1148111414")
        fill_in("Postal code", with: "1001")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")
        fill_in("CUIL", with: "00-00000000-0")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Account number", with: "0110000600000000000000")
        fill_in("Confirm account number", with: "0110000600000000000000")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in ARS.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("1001")
        expect(compliance_info.phone).to eq("+541148111414")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("0110000600000000000000")
      end
    end

    describe "PE creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Peru"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "14213365")
        fill_in("Postal code", with: "1001")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")
        fill_in("DNI number", with: "00000000-0")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Account number", with: "99934500012345670024")
        fill_in("Confirm account number", with: "99934500012345670024")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in PEN.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("1001")
        expect(compliance_info.phone).to eq("+5114213365")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("99934500012345670024")
      end
    end

    describe "Norwegian creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Norway"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Norwegian")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Oslo")
        fill_in("Phone number", with: "42133657")
        fill_in("Postal code", with: "0139")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Norwegian Creator")
        fill_in("IBAN", with: "NO9386011117947")
        fill_in("Confirm IBAN", with: "NO9386011117947")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in NOK.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Norwegian")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Oslo")
        expect(compliance_info.zip_code).to eq("0139")
        expect(compliance_info.phone).to eq("+4742133657")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("NO9386011117947")
      end
    end

    describe "IE creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Ireland"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        select("Carlow", from: "County")
        fill_in("Phone number", with: "16798705")
        fill_in("Postal code", with: "D02 NX03")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "IE29AIBK93115212345678")
        fill_in("Confirm IBAN", with: "IE29AIBK93115212345678")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in EUR.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.state).to eq("CW")
        expect(compliance_info.zip_code).to eq("D02 NX03")
        expect(compliance_info.phone).to eq("+35316798705")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("IE29AIBK93115212345678")
      end
    end
    describe "Liechtenstein creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Liechtenstein"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Liechtenstein")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Vaduz")
        fill_in("Phone number", with: "601234567")
        fill_in("Postal code", with: "0139")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Liechtenstein Creator")
        fill_in("IBAN", with: "LI0508800636123378777")
        fill_in("Confirm IBAN", with: "LI0508800636123378777")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in CHF.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Liechtenstein")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Vaduz")
        expect(compliance_info.zip_code).to eq("0139")
        expect(compliance_info.phone).to eq("+423601234567")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.routing_number).to be nil
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("LI0508800636123378777")
      end
    end

    describe "ID creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Indonesia"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "98761234")
        fill_in("Postal code", with: "000000")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Bank code", with: "000")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in IDR.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("000000")
        expect(compliance_info.phone).to eq("+6298761234")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
      end
    end

    describe "CR creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Costa Rica"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "22212425")
        fill_in("Postal code", with: "10101")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "CR04010212367856709123")
        fill_in("Confirm IBAN", with: "CR04010212367856709123")
        fill_in("Tax Identification Number", with: "1234567890")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in CRC.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("10101")
        expect(compliance_info.phone).to eq("+50622212425")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("CR04010212367856709123")
      end
    end

    describe "SA creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Saudi Arabia"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "501234567")
        fill_in("Postal code", with: "10110")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("SWIFT / BIC Code", with: "RIBLSARIXXX")
        fill_in("IBAN", with: "SA4420000001234567891234")
        fill_in("Confirm IBAN", with: "SA4420000001234567891234")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in SAR.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("10110")
        expect(compliance_info.phone).to eq("+966501234567")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("SA4420000001234567891234")
        expect(@user.reload.active_bank_account.send(:routing_number)).to eq("RIBLSARIXXX")
      end
    end

    describe "CL creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Chile"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "944448531")
        fill_in("Postal code", with: "8320054")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Bank code", with: "999")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")
        select("Checking", from: "Bank account type")
        fill_in("Rol Único Tributario (RUT)", with: "000000000")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in CLP.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("8320054")
        expect(compliance_info.phone).to eq("+56944448531")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.reload.active_bank_account.account_type).to eq("checking")
      end

      it "allows to enter savings bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "944448531")
        fill_in("Postal code", with: "8320054")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Bank code", with: "999")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")
        select("Savings", from: "Bank account type")
        fill_in("Rol Único Tributario (RUT)", with: "000000000")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in CLP.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("8320054")
        expect(compliance_info.phone).to eq("+56944448531")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.reload.active_bank_account.account_type).to eq("savings")
      end
    end

    describe "ZA creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "South Africa"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "213456789")
        fill_in("Postal code", with: "10110")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("SWIFT / BIC Code", with: "FIRNZAJJ")
        fill_in("Account #", with: "000001234")
        fill_in("Confirm account #", with: "000001234")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in ZAR.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("10110")
        expect(compliance_info.phone).to eq("+27213456789")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000001234")
      end
    end

    describe "KE creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Kenya"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "117654321")
        fill_in("Postal code", with: "10110")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("SWIFT / BIC Code", with: "BARCKENXMDR")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in KES.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("10110")
        expect(compliance_info.phone).to eq("+254117654321")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
      end
    end

    describe "EG creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Egypt"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "9876543210")
        fill_in("Postal code", with: "10110")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("SWIFT / BIC Code", with: "NBEGEGCX331")
        fill_in("IBAN", with: "EG800002000156789012345180002")
        fill_in("Confirm IBAN", with: "EG800002000156789012345180002")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in EGP.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("10110")
        expect(compliance_info.phone).to eq("+209876543210")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("EG800002000156789012345180002")
      end
    end

    describe "Bosnia and Herzegovina creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Bosnia and Herzegovina"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Bosnia and Herzegovina")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Sarajevo")
        fill_in("Phone number", with: "33123456")
        fill_in("Postal code", with: "71000")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Bosnia and Herzegovina Creator")
        fill_in("SWIFT / BIC Code", with: "AAAABABAXXX")
        fill_in("IBAN", with: "BA095520001234567812")
        fill_in("Confirm IBAN", with: "BA095520001234567812")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in BAM.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Bosnia and Herzegovina")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Sarajevo")
        expect(compliance_info.zip_code).to eq("71000")
        expect(compliance_info.phone).to eq("+38733123456")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("BA095520001234567812")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAABABAXXX")
      end
    end

    describe "MA creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Morocco"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "537721072")
        fill_in("Postal code", with: "10020")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("SWIFT / BIC Code", with: "AAAAMAMAXXX")
        fill_in("Account #", with: "MA64011519000001205000534921")
        fill_in("Confirm account #", with: "MA64011519000001205000534921")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MAD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("10020")
        expect(compliance_info.phone).to eq("+212537721072")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("MA64011519000001205000534921")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAMAMAXXX")
      end
    end

    describe "RS creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Serbia"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "113333011")
        fill_in("Postal code", with: "11000")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("SWIFT / BIC Code", with: "TESTSERBXXX")
        fill_in("Account #", with: "RS35105008123123123173")
        fill_in("Confirm account #", with: "RS35105008123123123173")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in RSD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("11000")
        expect(compliance_info.phone).to eq("+381113333011")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("RS35105008123123123173")
        expect(@user.reload.active_bank_account.routing_number).to eq("TESTSERBXXX")
      end
    end

    describe "KZ creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Kazakhstan"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Almaty")
        fill_in("Phone number", with: "7012345678")
        fill_in("Postal code", with: "050000")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("SWIFT / BIC Code", with: "AAAAKZKZXXX")
        fill_in("IBAN", with: "KZ221251234567890123")
        fill_in("Confirm IBAN", with: "KZ221251234567890123")

        fill_in("Individual identification number (IIN)", with: "000000000")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in KZT.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Almaty")
        expect(compliance_info.zip_code).to eq("050000")
        expect(compliance_info.phone).to eq("+77012345678")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("KZ221251234567890123")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAKZKZXXX")
      end
    end

    describe "EC creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Ecuador"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Quito")
        fill_in("Phone number", with: "991234567")
        fill_in("Postal code", with: "170102")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("SWIFT / BIC Code", with: "AAAAECE1XXX")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in USD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Quito")
        expect(compliance_info.zip_code).to eq("170102")
        expect(compliance_info.phone).to eq("+593991234567")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAECE1XXX")
      end
    end

    describe "Antigua and Barbuda creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Antigua and Barbuda"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Antigua and Barbuda")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "AnB City")
        fill_in("Phone number", with: "2681234567")
        fill_in("Postal code", with: "43200")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Antigua and Barbuda Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAAGAGXYZ")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in XCD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Antigua and Barbuda")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("AnB City")
        expect(compliance_info.zip_code).to eq("43200")
        expect(compliance_info.phone).to eq("+12681234567")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAAGAGXYZ")
      end
    end

    describe "Tanzanian creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Tanzania"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Tanzanian")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Tanzania City")
        fill_in("Phone number", with: "201234567")
        fill_in("Postal code", with: "43200")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Tanzanian Creator")
        fill_in("SWIFT / BIC Code", with: "AAAATZTXXXX")
        fill_in("Account #", with: "0000123456789")
        fill_in("Confirm account #", with: "0000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in TZS.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Tanzanian")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Tanzania City")
        expect(compliance_info.zip_code).to eq("43200")
        expect(compliance_info.phone).to eq("+255201234567")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("0000123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAATZTXXXX")
      end
    end

    describe "Namibian creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Namibia"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Namibian")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Namibia City")
        fill_in("Phone number", with: "63123456")
        fill_in("Postal code", with: "43200")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Namibian Creator")
        fill_in("SWIFT / BIC Code", with: "AAAANANXXYZ")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in NAD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Namibian")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Namibia City")
        expect(compliance_info.zip_code).to eq("43200")
        expect(compliance_info.phone).to eq("+26463123456")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAANANXXYZ")
      end
    end

    describe "Albanian creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Albania"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Albanian")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Albania")
        fill_in("Phone number", with: "41234567")
        fill_in("Postal code", with: "43200")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Albanian Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAALTXXXX")
        fill_in("IBAN", with: "AL35202111090000000001234567")
        fill_in("Confirm IBAN", with: "AL35202111090000000001234567")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in ALL.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.reload.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Albanian")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Albania")
        expect(compliance_info.zip_code).to eq("43200")
        expect(compliance_info.phone).to eq("+35541234567")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.active_bank_account.send(:account_number_decrypted)).to eq("AL35202111090000000001234567")
        expect(@user.active_bank_account.routing_number).to eq("AAAAALTXXXX")
      end
    end

    describe "Bahraini creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Bahrain"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Bahraini")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Bahrain")
        fill_in("Phone number", with: "66312345")
        fill_in("Postal code", with: "43200")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Bahraini Creator")
        fill_in("SWIFT / BIC Code", with: "AAAABHBMXYZ")
        fill_in("IBAN", with: "BH29BMAG1299123456BH00")
        fill_in("Confirm IBAN", with: "BH29BMAG1299123456BH00")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in BHD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Bahraini")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Bahrain")
        expect(compliance_info.zip_code).to eq("43200")
        expect(compliance_info.phone).to eq("+97366312345")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("BH29BMAG1299123456BH00")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAABHBMXYZ")
      end
    end

    describe "Rwandan creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Rwanda"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path
        fill_in("First name", with: "Rwandan")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Rwanda")
        fill_in("Phone number", with: "783123456")
        fill_in("Postal code", with: "112")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Rwandan Creator")
        fill_in("SWIFT / BIC", with: "AAAARWRWXXX")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in RWF.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Rwandan")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Rwanda")
        expect(compliance_info.zip_code).to eq("112")
        expect(compliance_info.phone).to eq("+250783123456")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAARWRWXXX")
      end
    end


    describe "Jordanian creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Jordan"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Jordanian")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Jordan")
        fill_in("Phone number", with: "799999999")
        fill_in("Postal code", with: "43200")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Jordanian Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAJOJOXXX")
        fill_in("IBAN", with: "JO32ABCJ0010123456789012345678")
        fill_in("Confirm IBAN", with: "JO32ABCJ0010123456789012345678")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in JOD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Jordanian")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Jordan")
        expect(compliance_info.zip_code).to eq("43200")
        expect(compliance_info.phone).to eq("+962799999999")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("JO32ABCJ0010123456789012345678")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAJOJOXXX")
      end
    end

    describe "Nigerian creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Nigeria"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Nigerian")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Nigeria")
        fill_in("Phone number", with: "2011234567")
        fill_in("Postal code", with: "43200")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Nigerian Creator")
        fill_in("SWIFT / BIC Code", with: "AAAANGLAXXX")
        fill_in("Account #", with: "1111111112")
        fill_in("Confirm account #", with: "1111111112")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in NGN.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Nigerian")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Nigeria")
        expect(compliance_info.zip_code).to eq("43200")
        expect(compliance_info.phone).to eq("+2342011234567")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("1111111112")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAANGLAXXX")
      end
    end

    describe "Azerbaijani creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Azerbaijan"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Azerbaijani")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Azerbaijan")
        fill_in("Phone number", with: "124980335")
        fill_in("Postal code", with: "43200")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Azerbaijani Creator")
        fill_in("Bank code", with: "123456")
        fill_in("Branch code", with: "123456")
        fill_in("IBAN", with: "AZ77ADJE12345678901234567890")
        fill_in("Confirm IBAN", with: "AZ77ADJE12345678901234567890")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in AZN.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank and branch code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Azerbaijani")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Azerbaijan")
        expect(compliance_info.zip_code).to eq("43200")
        expect(compliance_info.phone).to eq("+994124980335")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("AZ77ADJE12345678901234567890")
        expect(@user.reload.active_bank_account.routing_number).to eq("123456-123456")
      end
    end

    describe "Japanese creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Japan"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "japanese")
        fill_in("Last name", with: "creator")
        fill_in("First name (Kanji)", with: "日本語")
        fill_in("Last name (Kanji)", with: "創造者")
        fill_in("First name (Kana)", with: "ニホンゴ")
        fill_in("Last name (Kana)", with: "ソウゾウシャ")
        fill_in("Block / Building Number", with: "1-1")
        fill_in("Street Address (Kanji)", with: "日本語")
        fill_in("Street Address (Kana)", with: "ニホンゴ")
        fill_in("City", with: "tokyo")
        fill_in("Phone number", with: "987654321")
        fill_in("Postal code", with: "100-0000")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "japanese creator")
        fill_in("Bank code", with: "1100")
        fill_in("Branch code", with: "000")
        fill_in("Account #", with: "0001234")
        fill_in("Confirm account #", with: "0001234")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in JPY.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank and branch code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("japanese")
        expect(compliance_info.last_name).to eq("creator")
        expect(compliance_info.first_name_kanji).to eq("日本語")
        expect(compliance_info.last_name_kanji).to eq("創造者")
        expect(compliance_info.first_name_kana).to eq("ニホンゴ")
        expect(compliance_info.last_name_kana).to eq("ソウゾウシャ")
        expect(compliance_info.building_number).to eq("1-1")
        expect(compliance_info.street_address_kanji).to eq("日本語")
        expect(compliance_info.street_address_kana).to eq("ニホンゴ")
        expect(compliance_info.city).to eq("tokyo")
        expect(compliance_info.zip_code).to eq("100-0000")
        expect(compliance_info.phone).to eq("+81987654321")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("0001234")
      end
    end

    describe "GI creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Gibraltar"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Gibraltar")
        fill_in("Phone number", with: "20079123")
        fill_in("Postal code", with: "GX11 1AA")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "GI75NWBK000000007099453")
        fill_in("Confirm IBAN", with: "GI75NWBK000000007099453")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in GBP.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Gibraltar")
        expect(compliance_info.zip_code).to eq("GX11 1AA")
        expect(compliance_info.phone).to eq("+35020079123")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("GI75NWBK000000007099453")
      end
    end


    describe "Botswana creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Botswana"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path
        fill_in("First name", with: "botswana")
        fill_in("Last name", with: "creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "gaborone")
        fill_in("Phone number", with: "71123456")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "botswana creator")
        fill_in("SWIFT / BIC Code", with: "AAAABWBWXXX")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in BWP.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("botswana")
        expect(compliance_info.last_name).to eq("creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("gaborone")
        expect(compliance_info.phone).to eq("+26771123456")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAABWBWXXX")
      end
    end


    describe "Uruguayan creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Uruguay"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "uruguayan")
        fill_in("Last name", with: "creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "montevideo")
        fill_in("Phone number", with: "9876543")
        fill_in("Postal code", with: "11000")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "uruguayan creator")
        fill_in("Bank code", with: "999")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")
        fill_in("Cédula de Identidad (CI)", with: "1.123.123-1")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in UYU.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("uruguayan")
        expect(compliance_info.last_name).to eq("creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("montevideo")
        expect(compliance_info.zip_code).to eq("11000")
        expect(compliance_info.phone).to eq("+5989876543")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.routing_number).to eq("999")
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
      end
    end

    describe "Mauritian creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Mauritius"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "mauritian")
        fill_in("Last name", with: "creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "port louis")
        fill_in("Phone number", with: "51234567")
        fill_in("Postal code", with: "11324")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "mauritian creator")
        fill_in("SWIFT / BIC Code", with: "AAAAMUMUXYZ")
        fill_in("IBAN", with: "MU17BOMM0101101030300200000MUR")
        fill_in("Confirm IBAN", with: "MU17BOMM0101101030300200000MUR")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MUR.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("mauritian")
        expect(compliance_info.last_name).to eq("creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("port louis")
        expect(compliance_info.zip_code).to eq("11324")
        expect(compliance_info.phone).to eq("+23051234567")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAMUMUXYZ")
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("MU17BOMM0101101030300200000MUR")
      end
    end

    describe "Ghanaian creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Ghana"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "ghanaian")
        fill_in("Last name", with: "creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Accra")
        fill_in("Phone number", with: "302213850")
        fill_in("Postal code", with: "00233")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "ghanaian creator")
        fill_in("Bank code", with: "022112")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in GHS.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("ghanaian")
        expect(compliance_info.last_name).to eq("creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Accra")
        expect(compliance_info.zip_code).to eq("00233")
        expect(compliance_info.phone).to eq("+233302213850")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.routing_number).to eq("022112")
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
      end
    end

    describe "Jamaican creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Jamaica"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "jamaican")
        fill_in("Last name", with: "creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "kingston")
        fill_in("Phone number", with: "8767654321")
        fill_in("Postal code", with: "JMAAW01")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "jamaican creator")
        fill_in("Bank code", with: "111")
        fill_in("Branch code", with: "00000")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in JMD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank and branch code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("jamaican")
        expect(compliance_info.last_name).to eq("creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("kingston")
        expect(compliance_info.zip_code).to eq("JMAAW01")
        expect(compliance_info.phone).to eq("+18767654321")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.routing_number).to eq("111-00000")
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
      end
    end

    describe "Omani creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Oman"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path
        fill_in("First name", with: "omani")
        fill_in("Last name", with: "creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "muscat")
        fill_in("Phone number", with: "96896896")
        fill_in("Postal code", with: "112")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "omani creator")
        fill_in("SWIFT / BIC", with: "AAAAOMOMXXX")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in OMR.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("omani")
        expect(compliance_info.last_name).to eq("creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("muscat")
        expect(compliance_info.zip_code).to eq("112")
        expect(compliance_info.phone).to eq("+96896896896")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAOMOMXXX")
      end
    end

    describe "Tunisia creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Tunisia"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path
        fill_in("First name", with: "tunisian")
        fill_in("Last name", with: "creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Tunis")
        fill_in("Phone number", with: "98765432")
        fill_in("Postal code", with: "1001")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "tunisian creator")
        fill_in("IBAN", with: "TN5904018104004942712345")
        fill_in("Confirm IBAN", with: "TN5904018104004942712345")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in TND.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("tunisian")
        expect(compliance_info.last_name).to eq("creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Tunis")
        expect(compliance_info.zip_code).to eq("1001")
        expect(compliance_info.phone).to eq("+21698765432")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.routing_number).to be nil
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("TN5904018104004942712345")
      end
    end

    describe "Dominican Republic creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Dominican Republic"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Dominican Republic")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Santo Domingo")
        fill_in("Phone number", with: "8091234567")
        fill_in("Postal code", with: "10101")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Dominican Republic Creator")
        fill_in("Bank code", with: "999")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")
        fill_in("Cédula de identidad y electoral (CIE)", with: "123-1234567-1")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in DOP.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank and branch code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Dominican Republic")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Santo Domingo")
        expect(compliance_info.zip_code).to eq("10101")
        expect(compliance_info.phone).to eq("+18091234567")
        expect(compliance_info.birthday).to eq(Date.new(1901, 1, 1))
        expect(@user.reload.active_bank_account.routing_number).to eq("999")
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
      end
    end

    describe "Uzbekistan creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Uzbekistan"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Uzbekistan")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Tashkent")
        fill_in("Phone number", with: "987654321")
        fill_in("Postal code", with: "100000")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Uzbekistan Creator")
        fill_in("Bank code", with: "AAAAUZUZXXX")
        fill_in("Branch code", with: "00000")
        fill_in("Account #", with: "99934500012345670024")
        fill_in("Confirm account #", with: "99934500012345670024")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in UZS.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank and branch code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Uzbekistan")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Tashkent")
        expect(compliance_info.zip_code).to eq("100000")
        expect(compliance_info.phone).to eq("+998987654321")
        expect(compliance_info.birthday).to eq(Date.new(1901, 1, 1))
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAUZUZXXX-00000")
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("99934500012345670024")
      end
    end

    describe "Bolivia creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Bolivia"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Bolivian")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "La Paz")
        fill_in("Phone number", with: "21234567")
        fill_in("Postal code", with: "0000")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Chuck Bartowski")
        fill_in("Bank code", with: "040")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")
        fill_in("Cédula de Identidad (CI)", with: "00123456")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in BOB.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Bolivian")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("La Paz")
        expect(compliance_info.zip_code).to eq("0000")
        expect(compliance_info.phone).to eq("+59121234567")
        expect(compliance_info.birthday).to eq(Date.new(1901, 1, 1))
        expect(@user.reload.active_bank_account.routing_number).to eq("040")
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
      end
    end

    describe "Gabon creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Gabon"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Gabonese")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Libreville")
        fill_in("Phone number", with: "6123456")
        fill_in("Postal code", with: "00241")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Gabonese Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAGAGAXXX")
        fill_in("Account #", with: "00001234567890123456789")
        fill_in("Confirm account #", with: "00001234567890123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in XAF.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Gabonese")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Libreville")
        expect(compliance_info.zip_code).to eq("00241")
        expect(compliance_info.phone).to eq("+2416123456")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("00001234567890123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAGAGAXXX")
      end
    end

    describe "Monaco creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Monaco"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Monaco")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Monaco")
        fill_in("Phone number", with: "612345678")
        fill_in("Postal code", with: "98000")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Monaco Creator")
        fill_in("IBAN", with: "MC5810096180790123456789085")
        fill_in("Confirm IBAN", with: "MC5810096180790123456789085")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in EUR.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Monaco")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Monaco")
        expect(compliance_info.zip_code).to eq("98000")
        expect(compliance_info.phone).to eq("+377612345678")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("MC5810096180790123456789085")
        expect(@user.reload.active_bank_account.routing_number).to be nil
      end
    end

    describe "Moldovan creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Moldova"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Moldova")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Chisinau")
        fill_in("Phone number", with: "71234567")
        fill_in("Postal code", with: "2001")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Moldova Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAMDMDXXX")
        fill_in("Account #", with: "MD07AG123456789012345678")
        fill_in("Confirm account #", with: "MD07AG123456789012345678")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MDL.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Moldova")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Chisinau")
        expect(compliance_info.zip_code).to eq("2001")
        expect(compliance_info.phone).to eq("+37371234567")
        expect(compliance_info.birthday).to eq(Date.new(1901, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("MD07AG123456789012345678")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAMDMDXXX")
      end
    end

    describe "North Macedonia creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "North Macedonia"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "North Macedonian")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "skopje")
        fill_in("Phone number", with: "23456789")
        fill_in("Postal code", with: "1000")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Account #", with: "MK49250120000058907")
        fill_in("Confirm account #", with: "MK49250120000058907")
        fill_in("SWIFT / BIC Code", with: "AAAAMK2XXXX")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MKD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("North Macedonian")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("skopje")
        expect(compliance_info.zip_code).to eq("1000")
        expect(compliance_info.phone).to eq("+38923456789")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("MK49250120000058907")
        expect(@user.active_bank_account.routing_number).to eq("AAAAMK2XXXX")
      end
    end

    describe "Ethiopia creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Ethiopia"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Ethiopia")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "eth")
        fill_in("Phone number", with: "912345678")
        fill_in("Postal code", with: "1100")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Ethiopia Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAETETXXX")
        fill_in("Account #", with: "0000000012345")
        fill_in("Confirm account #", with: "0000000012345")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in ETB.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Ethiopia")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("eth")
        expect(compliance_info.zip_code).to eq("1100")
        expect(compliance_info.phone).to eq("+251912345678")
        expect(compliance_info.birthday).to eq(Date.new(1901, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("0000000012345")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAETETXXX")
      end
    end

    describe "Brunei creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Brunei"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Brunei")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "brun")
        fill_in("Phone number", with: "2294567")
        fill_in("Postal code", with: "1100")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Brunei Creator")
        fill_in("SWIFT / BIC Code", with: "AAAABNBBXXX")
        fill_in("Account #", with: "0000123456789")
        fill_in("Confirm account #", with: "0000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in BND.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Brunei")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("brun")
        expect(compliance_info.zip_code).to eq("1100")
        expect(compliance_info.phone).to eq("+6732294567")
        expect(compliance_info.birthday).to eq(Date.new(1901, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("0000123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAABNBBXXX")
      end
    end

    describe "Guyana creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Guyana"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Guyana")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "guy")
        fill_in("Phone number", with: "6291234")
        fill_in("Postal code", with: "1100")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Guyana Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAGYGGXYZ")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in GYD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Guyana")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("guy")
        expect(compliance_info.zip_code).to eq("1100")
        expect(compliance_info.phone).to eq("+5926291234")
        expect(compliance_info.birthday).to eq(Date.new(1901, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAGYGGXYZ")
      end
    end

    describe "Guatemala creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Guatemala"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Guatemala")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "guatemala")
        fill_in("Phone number", with: "31234567")
        fill_in("Postal code", with: "1100")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Guatemala Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAGTGCXYZ")
        fill_in("IBAN", with: "GT82TRAJ01020000001210029690")
        fill_in("Confirm IBAN", with: "GT82TRAJ01020000001210029690")

        fill_in("Número de Identificación Tributaria (NIT)", with: "1234567-8")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in GTQ.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Guatemala")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("guatemala")
        expect(compliance_info.zip_code).to eq("1100")
        expect(compliance_info.phone).to eq("+50231234567")
        expect(compliance_info.birthday).to eq(Date.new(1901, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("GT82TRAJ01020000001210029690")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAGTGCXYZ")
      end
    end

    describe "Panamanian creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Panama"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Panamanian")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Panama City")
        fill_in("Phone number", with: "61234567")
        fill_in("Postal code", with: "00000")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Panamanian creator")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")
        fill_in("SWIFT / BIC Code", with: "AAAAPAPAXXX")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in USD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Panamanian")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Panama City")
        expect(compliance_info.zip_code).to eq("00000")
        expect(compliance_info.phone).to eq("+50761234567")
        expect(compliance_info.birthday).to eq(Date.new(1901, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAPAPAXXX")
      end
    end

    describe "Bangladesh creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Bangladesh"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Bangladesh")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "dhaka")
        fill_in("Phone number", with: "1312345678")
        fill_in("Postal code", with: "1100")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Personal ID number", with: "000000000")
        select("Bangladesh", from: "Nationality")

        fill_in("Pay to the order of", with: "Bangladesh Creator")
        fill_in("Bank Code", with: "110000000")
        fill_in("Account #", with: "0000123456789")
        fill_in("Confirm account #", with: "0000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in BDT.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Bangladesh")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("dhaka")
        expect(compliance_info.zip_code).to eq("1100")
        expect(compliance_info.phone).to eq("+8801312345678")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(compliance_info.individual_tax_id.decrypt("1234")).to eq("000000000")
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("0000123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("110000000")
      end
    end

    describe "Bhutan creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Bhutan"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Bhutan")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "bhutan")
        fill_in("Phone number", with: "12345678")
        fill_in("Postal code", with: "43200")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Bhutan Creator")
        fill_in("SWIFT / BIC Code", with: "AAAABTBTXXX")
        fill_in("Account #", with: "0000123456789")
        fill_in("Confirm account #", with: "0000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in BTN.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Bhutan")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("bhutan")
        expect(compliance_info.zip_code).to eq("43200")
        expect(compliance_info.phone).to eq("+97512345678")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("0000123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAABTBTXXX")
      end
    end

    describe "Laos creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Lao People's Democratic Republic"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Laos")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "laos")
        fill_in("Phone number", with: "21123456")
        fill_in("Postal code", with: "43200")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Laos Creator")
        fill_in("SWIFT / BIC Code", with: "AAAALALAXXX")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in LAK.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Laos")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("laos")
        expect(compliance_info.zip_code).to eq("43200")
        expect(compliance_info.phone).to eq("+85621123456")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(compliance_info.country).to eq("Lao People's Democratic Republic")
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAALALAXXX")
      end
    end

    describe "Mozambique creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Mozambique"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Mozambique")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "mz")
        fill_in("Phone number", with: "811234567")
        fill_in("Postal code", with: "43200")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Mozambique Taxpayer Single ID Number (NUIT)", with: "000000000")

        fill_in("Pay to the order of", with: "Mozambique Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAMZMXXXX")
        fill_in("Account #", with: "001234567890123456789")
        fill_in("Confirm account #", with: "001234567890123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MZN.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Mozambique")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("mz")
        expect(compliance_info.zip_code).to eq("43200")
        expect(compliance_info.phone).to eq("+258811234567")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(compliance_info.individual_tax_id.decrypt("1234")).to eq("000000000")
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("001234567890123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAMZMXXXX")
      end
    end

    describe "El Salvadoran creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "El Salvador"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "El Salvadorian")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "San Salvador")
        fill_in("Phone number", with: "68765432")
        fill_in("Postal code", with: "1101")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "El Salvadorian Creator")
        fill_in("IBAN", with: "SV44BCIE12345678901234567890")
        fill_in("Confirm IBAN", with: "SV44BCIE12345678901234567890")
        fill_in("SWIFT / BIC Code", with: "AAAASVS1XXX")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in USD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("El Salvadorian")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("San Salvador")
        expect(compliance_info.zip_code).to eq("1101")
        expect(compliance_info.phone).to eq("+50368765432")
        expect(compliance_info.birthday).to eq(Date.new(1901, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("SV44BCIE12345678901234567890")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAASVS1XXX")
      end
    end

    describe "Paraguayan creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Paraguay"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Paraguayan")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Asunción")
        fill_in("Phone number", with: "68765432")
        fill_in("Postal code", with: "001001")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Paraguayan Creator")
        fill_in("Bank code", with: "0")
        fill_in("Account #", with: "0567890123456789")
        fill_in("Confirm account #", with: "0567890123456789")
        fill_in("Cédula de Identidad (CI)", with: "1234567")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in PYG.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Paraguayan")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Asunción")
        expect(compliance_info.zip_code).to eq("001001")
        expect(compliance_info.phone).to eq("+59568765432")
        expect(compliance_info.birthday).to eq(Date.new(1901, 1, 1))
        expect(@user.reload.active_bank_account.routing_number).to eq("0")
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("0567890123456789")
      end
    end

    describe "Armenian creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Armenia"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Armenian")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Yerevan")
        fill_in("Phone number", with: "77123456")
        fill_in("Postal code", with: "0010")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Armenian Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAAMNNXXX")
        fill_in("Account #", with: "00001234567")
        fill_in("Confirm account #", with: "00001234567")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in AMD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Armenian")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Yerevan")
        expect(compliance_info.zip_code).to eq("0010")
        expect(compliance_info.phone).to eq("+37477123456")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("00001234567")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAAMNNXXX")
      end
    end

    describe "Madagascar creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Madagascar"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "malagasy")
        fill_in("Last name", with: "creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Antananarivo")
        fill_in("Phone number", with: "321234567")
        fill_in("Postal code", with: "101")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "malagasy creator")
        fill_in("SWIFT / BIC Code", with: "AAAAMGMGXXX")
        fill_in("Account #", with: "MG4800005000011234567890123")
        fill_in("Confirm account #", with: "MG4800005000011234567890123")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MGA.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("malagasy")
        expect(compliance_info.last_name).to eq("creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Antananarivo")
        expect(compliance_info.zip_code).to eq("101")
        expect(compliance_info.phone).to eq("+261321234567")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("MG4800005000011234567890123")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAMGMGXXX")
      end
    end

    describe "Sri Lankan creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Sri Lanka"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Sri Lankan")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Colombo")
        fill_in("Phone number", with: "712345678")
        fill_in("Postal code", with: "00100")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Sri Lankan Creator")
        fill_in("Bank code", with: "AAAALKLXXXX")
        fill_in("Branch code", with: "7010999")
        fill_in("Account #", with: "0000012345")
        fill_in("Confirm account #", with: "0000012345")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in LKR.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("Bank and branch code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Sri Lankan")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Colombo")
        expect(compliance_info.zip_code).to eq("00100")
        expect(compliance_info.phone).to eq("+94712345678")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("0000012345")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAALKLXXXX-7010999")
      end
    end

    describe "Kuwaiti creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Kuwait"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Kuwaiti")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Kuwait City")
        fill_in("Phone number", with: "50123456")
        fill_in("Postal code", with: "12345")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Kuwaiti Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAKWKWXYZ")
        fill_in("IBAN", with: "KW81CBKU0000000000001234560101")
        fill_in("Confirm IBAN", with: "KW81CBKU0000000000001234560101")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in KWD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Kuwaiti")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Kuwait City")
        expect(compliance_info.zip_code).to eq("12345")
        expect(compliance_info.phone).to eq("+96550123456")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("KW81CBKU0000000000001234560101")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAKWKWXYZ")
      end
    end

    describe "Icelandic creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Iceland"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Icelandic")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Reykjavík")
        fill_in("Phone number", with: "6123456")
        fill_in("Postal code", with: "101")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Icelandic Creator")
        fill_in("IBAN", with: "IS140159260076545510730339")
        fill_in("Confirm IBAN", with: "IS140159260076545510730339")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in EUR.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Icelandic")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Reykjavík")
        expect(compliance_info.zip_code).to eq("101")
        expect(compliance_info.phone).to eq("+3546123456")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("IS140159260076545510730339")
      end
    end

    describe "Qatar creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Qatar"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Qatar")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Doha")
        fill_in("Phone number", with: "33123456")
        fill_in("Postal code", with: "12345")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Qatar Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAQAQAXXX")
        fill_in("Account #", with: "QA87CITI123456789012345678901")
        fill_in("Confirm account #", with: "QA87CITI123456789012345678901")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in QAR.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Qatar")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Doha")
        expect(compliance_info.zip_code).to eq("12345")
        expect(compliance_info.phone).to eq("+97433123456")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("QA87CITI123456789012345678901")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAQAQAXXX")
      end
    end

    describe "Bahamas creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Bahamas"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Bahamas")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Nassau")
        fill_in("Phone number", with: "2421234567")
        fill_in("Postal code", with: "12345")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Bahamas Creator")
        fill_in("SWIFT / BIC Code", with: "AAAABSNSXXX")
        fill_in("Account #", with: "0001234")
        fill_in("Confirm account #", with: "0001234")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in BSD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Bahamas")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Nassau")
        expect(compliance_info.zip_code).to eq("12345")
        expect(compliance_info.phone).to eq("+12421234567")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("0001234")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAABSNSXXX")
      end
    end

    describe "Saint Lucia creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Saint Lucia"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Saint Lucia")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Castries")
        fill_in("Phone number", with: "7581234567")
        fill_in("Postal code", with: "12345")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Saint Lucia Creator")
        fill_in("SWIFT / BIC Code", with: "AAAALCLCXYZ")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in XCD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Saint Lucia")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Castries")
        expect(compliance_info.zip_code).to eq("12345")
        expect(compliance_info.phone).to eq("+17581234567")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAALCLCXYZ")
      end
    end

    describe "Senegal creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Senegal"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Senegal")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Dakar")
        fill_in("Phone number", with: "338215322")
        fill_in("Postal code", with: "12500")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Senegal Creator")
        fill_in("Account #", with: "SN08SN0100152000048500003035")
        fill_in("Confirm account #", with: "SN08SN0100152000048500003035")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in XOF.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Senegal")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Dakar")
        expect(compliance_info.zip_code).to eq("12500")
        expect(compliance_info.phone).to eq("+221338215322")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("SN08SN0100152000048500003035")
      end
    end

    describe "Angola creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Angola"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Angola")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "angola")
        fill_in("Phone number", with: "923123456")
        fill_in("Postal code", with: "43200")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Angola Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAAOAOXXX")
        fill_in("IBAN", with: "AO06004400006729503010102")
        fill_in("Confirm IBAN", with: "AO06004400006729503010102")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in AOA.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Angola")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("angola")
        expect(compliance_info.zip_code).to eq("43200")
        expect(compliance_info.phone).to eq("+244923123456")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("AO06004400006729503010102")
        expect(@user.reload.active_bank_account.send(:routing_number)).to eq("AAAAAOAOXXX")
      end
    end

    describe "Niger creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Niger"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Niger")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "niger")
        fill_in("Phone number", with: "70312345")
        fill_in("Postal code", with: "43200")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Niger Creator")
        fill_in("IBAN", with: "NE58NE0380100100130305000268")
        fill_in("Confirm IBAN", with: "NE58NE0380100100130305000268")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in XOF.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Niger")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("niger")
        expect(compliance_info.zip_code).to eq("43200")
        expect(compliance_info.phone).to eq("+22770312345")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("NE58NE0380100100130305000268")
        expect(@user.reload.active_bank_account.routing_number).to be nil
      end
    end

    describe "San Marino creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "San Marino"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "San Marino")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "sm")
        fill_in("Phone number", with: "62312345")
        fill_in("Postal code", with: "43200")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "San Marino Creator")
        fill_in("SWIFT / BIC Code", with: "AAAASMSMXXX")
        fill_in("IBAN", with: "SM86U0322509800000000270100")
        fill_in("Confirm IBAN", with: "SM86U0322509800000000270100")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in EUR.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("San Marino")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("sm")
        expect(compliance_info.zip_code).to eq("43200")
        expect(compliance_info.phone).to eq("+37862312345")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("SM86U0322509800000000270100")
        expect(@user.reload.active_bank_account.send(:routing_number)).to eq("AAAASMSMXXX")
      end
    end

    describe "Cambodia creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Cambodia"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Cambodia")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Phnom Penh")
        fill_in("Phone number", with: "124980335")
        fill_in("Postal code", with: "12000")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Cambodia Creator")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")
        fill_in("SWIFT / BIC Code", with: "AAAAKHKHXXX")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in KHR.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Cambodia")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Phnom Penh")
        expect(compliance_info.zip_code).to eq("12000")
        expect(compliance_info.phone).to eq("+855124980335")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAKHKHXXX")
      end
    end

    describe "Mongolia creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Mongolia"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Mongolia")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Ulaanbaatar")
        fill_in("Phone number", with: "124980335")
        fill_in("Postal code", with: "14200")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Mongolia Creator")
        fill_in("Account #", with: "0002222001")
        fill_in("Confirm account #", with: "0002222001")
        fill_in("SWIFT / BIC Code", with: "AAAAMNUBXXX")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MNT.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Mongolia")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Ulaanbaatar")
        expect(compliance_info.zip_code).to eq("14200")
        expect(compliance_info.phone).to eq("+976124980335")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("0002222001")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAMNUBXXX")
      end
    end

    describe "Algeria creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Algeria"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Algeria")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Algiers")
        fill_in("Phone number", with: "555123456")
        fill_in("Postal code", with: "16000")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Algeria Creator")
        fill_in("Account #", with: "00001234567890123456")
        fill_in("Confirm account #", with: "00001234567890123456")
        fill_in("SWIFT / BIC Code", with: "AAAADZDZXXX")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in DZD.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Algeria")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Algiers")
        expect(compliance_info.zip_code).to eq("16000")
        expect(compliance_info.phone).to eq("+213555123456")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("00001234567890123456")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAADZDZXXX")
      end
    end

    describe "Macao creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Macao"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Macao")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Macao")
        fill_in("Phone number", with: "66123456")
        fill_in("Postal code", with: "999078")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Macao Creator")
        fill_in("Account #", with: "0000000001234567897")
        fill_in("Confirm account #", with: "0000000001234567897")
        fill_in("SWIFT / BIC Code", with: "AAAAMOMXXXX")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MOP.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Macao")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Macao")
        expect(compliance_info.zip_code).to eq("999078")
        expect(compliance_info.phone).to eq("+85366123456")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("0000000001234567897")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAMOMXXXX")
      end
    end

    describe "Benin creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Benin"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Benin")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Cotonou")
        fill_in("Phone number", with: "90123456")
        fill_in("Postal code", with: "300271")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Benin Creator")
        fill_in("IBAN", with: "BJ66BJ0610100100144390000769")
        fill_in("Confirm IBAN", with: "BJ66BJ0610100100144390000769")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in XOF.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Benin")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Cotonou")
        expect(compliance_info.zip_code).to eq("300271")
        expect(compliance_info.phone).to eq("+22990123456")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("BJ66BJ0610100100144390000769")
      end
    end

    describe "Cote d'Ivoire creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Cote d'Ivoire"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Cote d'Ivoire")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Abidjan")
        fill_in("Phone number", with: "+2252512345678")
        fill_in("Postal code", with: "1100")

        select("1", from: "Day")
        select("1", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Cote d'Ivoire Creator")
        fill_in("IBAN", with: "CI93CI0080111301134291200589")
        fill_in("Confirm IBAN", with: "CI93CI0080111301134291200589")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in XOF.")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        expect(page).not_to have_content("Routing number")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Cote d'Ivoire")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Abidjan")
        expect(compliance_info.zip_code).to eq("1100")
        expect(compliance_info.phone).to eq("+2252512345678")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("CI93CI0080111301134291200589")
      end
    end

    context "when there is no compliance info" do
      before do
        @user.alive_user_compliance_info.mark_deleted!
      end

      it "requires selecting a country before proceeding" do
        visit settings_payments_path
        within "dialog" do
          expect(page).to have_content "Where are you located?"
          expect(page).to have_content "You may have to forfeit your balance if you want to change your country in the future."
          expect(page).to have_button "Save", disabled: true
          expect(find(:select, "Country")).to have_selector(:option, "Somalia (not supported)", disabled: true)
          select "United States", from: "Country"
          check "I have a valid, government-issued photo ID"
          check "I have proof of residence within this country"
          check "If I am signing up as a business, it is registered in the country above"
          click_on "Save"
          wait_for_ajax
        end
        expect(page).to have_selector "h1", text: "Settings"
        expect(page).to_not have_content "We need this information so we can start paying you."

        @user.reload
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.country).to eq("United States")
      end
    end

    context "with switching account to user as admin for seller" do
      let(:seller) { @user }

      include_context "with switching account to user as admin for seller"

      it "disables the form" do
        visit settings_payments_path
        expect(page).to have_field("First name", disabled: true)
        expect(page).not_to have_button("Update settings")
      end
    end
  end

  describe "Country selection modal" do
    before do
      @user = create(:named_user, payment_address: nil)
      login_as @user
    end

    it "navigates back to previous page when modal is closed" do
      visit settings_main_path
      find('a[role="tab"]', text: "Payments").click
      expect(page).to have_content("Where are you located?")
      find("button[aria-label='Close']").click
      expect(page).to have_current_path(settings_main_path)
    end

    it "navigates to dashboard page when modal is closed and no previous page exists" do
      visit settings_payments_path
      expect(page).to have_content("Where are you located?")
      find("button[aria-label='Close']").click
      expect(page).to have_current_path(dashboard_path)
    end
  end

  describe "Taxes collection section" do
    before do
      @creator = create(:user_with_compliance_info, name: "Chuck Bartowski", au_backtax_sales_cents: 30000_00, au_backtax_owed_cents: 2727_27)
      create(:user_compliance_info, user: @creator, country: "United States")

      login_as @creator
    end

    describe "when the feature flag is not active" do
      it "displays the taxes collection section" do
        visit settings_payments_path

        expect(page).not_to have_text("Backtaxes collection")
      end
    end

    describe "when the feature flag is active" do
      before do
        Feature.activate(:au_backtaxes)
      end

      it "does not display the backtaxes collection section if creator has not received an email" do
        visit settings_payments_path

        expect(page).not_to have_text("Backtaxes collection")
      end

      describe "when the creator has received an email" do
        before do
          create(:australia_backtax_email_info, user: @creator)
        end

        it "displays the taxes collection section and allows the creator to opt in" do
          visit settings_payments_path

          expect(page).to have_text("Backtaxes collection")

          click_on "Opt-in to backtaxes collection"
          fill_in "Type your full name to opt-in", with: "Chuck Bartowski"
          click_on "Save and opt-in"

          expect(page).to have_text("You've opted in to backtaxes collection.")
          expect(@creator.backtax_agreements.count).to eq(1)
          expect(@creator.backtax_agreements.first.signature).to eq("Chuck Bartowski")
        end

        it "renders an error message when the creator provides an invalid name for a signature" do
          visit settings_payments_path

          expect(page).to have_text("Backtaxes collection")

          click_on "Opt-in to backtaxes collection"
          fill_in "Type your full name to opt-in", with: "Chuck"
          click_on "Save and opt-in"

          expect(page).to have_text("Please enter your exact name.")
          expect(@creator.backtax_agreements.count).to eq(0)
        end
      end
    end
  end

  describe "saved credit cards" do
    before do
      @user = create(:named_user, credit_card: create(:credit_card))
      user_compliance_info = @user.fetch_or_build_user_compliance_info
      user_compliance_info.country = "United States"
      user_compliance_info.save!
      login_as @user
    end

    it "allows user to remove them" do
      visit settings_payments_path
      within_section "Saved credit card", section_element: :section do
        click_on "Remove credit card"
      end
      expect(page).to_not have_section "Saved credit card"
      expect(@user.reload.credit_card_id).to be(nil)
    end

    it "does not allow removing credit cards if requires_credit_card? is true" do
      allow_any_instance_of(User).to receive(:requires_credit_card?).and_return(true)
      visit settings_payments_path
      within_section "Saved credit card", section_element: :section do
        button = find_button("Remove credit card", disabled: true)
        button.hover
        expect(button).to have_tooltip(text: "Please cancel any active preorder or membership purchases before removing your credit card.")
      end
    end
  end

  describe "payout scheduling" do
    let(:user) { create(:named_user) }

    before do
      user_compliance_info = user.fetch_or_build_user_compliance_info
      user_compliance_info.first_name = "John"
      user_compliance_info.last_name = "Smith"
      user_compliance_info.street_address = "123 Main St"
      user_compliance_info.city = "San Francisco"
      user_compliance_info.state = "CA"
      user_compliance_info.zip_code = "94105"
      user_compliance_info.birthday = 20.years.ago.to_date
      user_compliance_info.individual_tax_id = "123456789"
      user_compliance_info.phone = "+12025550123"
      user_compliance_info.country = "United States"
      user_compliance_info.save!
      create(:ach_account_stripe_succeed, user:)
      login_as user
    end

    describe "payouts paused notice" do
      it "shows the warning notice when payouts are paused internally by admin" do
        user.update!(payouts_paused_internally: true)
        visit settings_payments_path

        expect(page).to have_status(text: "Your payouts have been paused by Gumroad admin.")
      end

      it "shows the warning notice when payouts are paused internally by admin with a reason" do
        user.update!(payouts_paused_internally: true, payouts_paused_by: User.last.id)
        user.comments.create!(
          author_id: User.last.id,
          content: "Chargeback rate is too high.",
          comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED
        )

        visit settings_payments_path

        expect(page).to have_status(text: "Your payouts have been paused by Gumroad admin. Reason for pause: Chargeback rate is too high.")
      end

      it "shows the warning notice when payouts are paused internally by Stripe" do
        user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
        visit settings_payments_path

        expect(page).to have_status(text: "Your payouts are currently paused by our payment processor. Please check for any pending verification requirements below.")
      end

      it "shows the warning notice when payouts are paused internally by the system" do
        user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
        visit settings_payments_path

        expect(page).to have_status(text: "Your payouts have been automatically paused for a security review and will be resumed once the review completes.")
      end

      it "shows the warning notice when payouts are paused by the user" do
        user.update!(payouts_paused_by_user: true)
        visit settings_payments_path

        expect(page).to have_status(text: "You have paused your payouts.")
      end
    end

    describe "pausing payouts" do
      it "allows enabling and disabling payouts" do
        visit settings_payments_path

        within_section "Payout schedule", section_element: :section do
          check "Pause payouts", unchecked: true
        end
        click_on "Update settings"

        expect(page).to have_alert(text: "Thanks! You're all set.")
        expect(user.reload.payouts_paused_by_user?).to be true

        refresh

        within_section "Payout schedule", section_element: :section do
          uncheck "Pause payouts", checked: true
        end
        click_on "Update settings"

        expect(page).to have_alert(text: "Thanks! You're all set.")
        expect(user.reload.payouts_paused_by_user?).to be false
      end

      it "disables the toggle when payouts are paused internally by admin" do
        user.update!(payouts_paused_internally: true)
        visit settings_payments_path

        within_section "Payout schedule", section_element: :section do
          toggle = find_field("Pause payouts", disabled: true, checked: true)
          toggle.hover
          expect(toggle).to have_tooltip(text: "Your payouts have been paused by Gumroad admin.")
        end
      end

      it "disables the toggle when payouts are paused internally by admin with a reason" do
        user.update!(payouts_paused_internally: true, payouts_paused_by: User.last.id)
        user.comments.create!(
          author_id: User.last.id,
          content: "Chargeback rate is too high.",
          comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED
        )

        visit settings_payments_path

        within_section "Payout schedule", section_element: :section do
          toggle = find_field("Pause payouts", disabled: true, checked: true)
          toggle.hover
          expect(toggle).to have_tooltip(text: "Your payouts have been paused by Gumroad admin. Reason for pause: Chargeback rate is too high.")
        end
      end

      it "disables the toggle when payouts are paused internally by Stripe" do
        user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
        visit settings_payments_path

        within_section "Payout schedule", section_element: :section do
          toggle = find_field("Pause payouts", disabled: true, checked: true)
          toggle.hover
          expect(toggle).to have_tooltip(text: "Your payouts are currently paused by our payment processor. Please check for any pending verification requirements above.")
        end
      end

      it "disables the toggle when payouts are paused internally by the system" do
        user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
        visit settings_payments_path

        within_section "Payout schedule", section_element: :section do
          toggle = find_field("Pause payouts", disabled: true, checked: true)
          toggle.hover
          expect(toggle).to have_tooltip(text: "Your payouts have been automatically paused for a security review and will be resumed once the review completes.")
        end
      end
    end

    describe "minimum payout threshold" do
      it "allows updating the payout threshold" do
        visit settings_payments_path

        field = find_field("Minimum payout threshold", with: "10")
        field.fill_in(with: "5")

        expect(field["aria-invalid"]).to eq("true")
        expect(page).to have_text("Your payout threshold must be at least $10.")
        expect(page).to have_button("Update settings", disabled: true)

        field.fill_in(with: "15")
        expect(field["aria-invalid"]).to eq("false")
        expect(page).to_not have_text("Your payout threshold must be at least $10.")

        click_on "Update settings"

        expect(page).to have_alert(text: "Thanks! You're all set.")
        expect(user.reload.minimum_payout_amount_cents).to eq(1500)
      end

      context "when the user is in a cross-border payout country" do
        let!(:compliance_info) { create(:user_compliance_info_korea, user:, phone: "+821012345678") }

        before do
          user.active_bank_account.mark_deleted!
          create(:korea_bank_account, user:)
        end

        it "shows the minimum payout threshold for the country" do
          visit settings_payments_path

          field = find_field("Minimum payout threshold", with: "34.74")
          field.fill_in(with: "30")

          expect(field["aria-invalid"]).to eq("true")
          expect(page).to have_text("Your payout threshold must be at least $34.74.")
          expect(page).to have_button("Update settings", disabled: true)

          field.fill_in(with: "40")
          expect(field["aria-invalid"]).to eq("false")
          expect(page).to_not have_text("Your payout threshold must be at least $34.74.")

          click_on "Update settings"

          expect(page).to have_alert(text: "Thanks! You're all set.")
          expect(user.reload.minimum_payout_amount_cents).to eq(4000)
        end
      end
    end

    describe "payout frequency" do
      it "allows updating the payout frequency" do
        visit settings_payments_path

        expect(page).to have_select("Schedule", selected: "Weekly")
        select "Monthly", from: "Schedule"

        click_on "Update settings"

        expect(page).to have_alert(text: "Thanks! You're all set.")
        expect(user.reload.payout_frequency).to eq(User::PayoutSchedule::MONTHLY)

        refresh

        expect(page).to have_select("Schedule", selected: "Monthly")
        select "Quarterly", from: "Schedule"

        click_on "Update settings"

        expect(page).to have_alert(text: "Thanks! You're all set.")
        expect(user.reload.payout_frequency).to eq(User::PayoutSchedule::QUARTERLY)
      end
    end
  end
end
