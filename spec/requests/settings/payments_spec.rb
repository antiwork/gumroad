# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Payments Settings Scenario", type: :system, js: true) do
  def change_masked_tax_field(label)
    if has_field?(label, disabled: true, wait: 0)
      field = find_field(label, disabled: true)
      container = field.find(:xpath, "./ancestor::div[.//button[text()='Change']][1]")
      container.find("button", text: "Change", match: :first).click
    end
  end

  describe "PayPal section" do
    let(:user) { create(:user, name: "Gum") }

    before do
      login_as user
    end

    it "renders Payments tab navigation" do
      visit settings_payments_path

      expect(page).to have_tab_button("Payments", open: true)
    end

    it "does not render the PayPal Connect section and points to checkout settings instead" do
      create(:user_compliance_info, user:)

      visit settings_payments_path

      expect(page).not_to have_link("Connect with PayPal")
      expect(page).to have_text("Looking for PayPal Connect?")
      expect(page).to have_link("Checkout settings", href: checkout_form_path)
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
    include_context "with Stripe API stubs"

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
      fill_in("Account number", with: "000123456789")
      fill_in("Confirm account number", with: "000123456789")

      expect(page).to have_content("Must exactly match the name on your bank account")
      expect(page).to have_content("Payouts will be made in USD.")

      select("1", from: "Day")
      select("January", from: "Month")
      select("1980", from: "Year")
      fill_in("Last 4 digits of SSN", with: "1235")

      click_on("Update settings")
      expect(page).to have_alert(text: "Thanks! You're all set.")
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

    it "names the missing required fields when the save is blocked client-side" do
      visit settings_payments_path

      fill_in("First name", with: "barnabas")
      fill_in("Last name", with: "barnabastein")
      fill_in("Address", with: "address_full_match")
      select("California", from: "State")
      fill_in("Phone number", with: "(502) 254-1982")

      fill_in("Pay to the order of", with: "barnabas ngagy")
      fill_in("Routing number", with: "110000000")
      fill_in("Account number", with: "000123456789")
      fill_in("Confirm account number", with: "000123456789")
      fill_in("Last 4 digits of SSN", with: "1235")

      # City, ZIP code and the date of birth are left blank on purpose.
      expect do
        click_on("Update settings")
        expect(page).to have_status(text: "Please complete the required fields below:")
        expect(page).to have_status(text: "City")
        # The banner names the label a US seller actually sees, not the generic "Postal code".
        expect(page).to have_status(text: "ZIP code")
        expect(page).to have_status(text: "Date of birth")
      end.to_not change { @user.alive_user_compliance_info.reload.first_name }

      # Filling one of the named fields must not yank the seller away from it: the scroll-to-field
      # effect fires once per save attempt, not on every keystroke.
      fill_in("City", with: "barnabasville")
      expect(page).to have_field("City", with: "barnabasville", focused: true)

      fill_in("ZIP code", with: "12345")
      select("1", from: "Day")
      select("January", from: "Month")
      select("1980", from: "Year")

      click_on("Update settings")
      expect(page).to have_alert(text: "Thanks! You're all set.")
      expect(@user.alive_user_compliance_info.reload.first_name).to eq("barnabas")
    end

    it "keeps the specific validation message when one applies instead of the generic field list" do
      visit settings_payments_path

      fill_in("First name", with: "barnabas")
      fill_in("Last name", with: "barnabastein")
      fill_in("Address", with: "P.O. Box 123, Smith street")
      fill_in("City", with: "barnabasville")
      select("California", from: "State")
      fill_in("ZIP code", with: "12345")
      fill_in("Phone number", with: "(502) 254-1982")
      select("1", from: "Day")
      select("January", from: "Month")
      select("1980", from: "Year")
      fill_in("Last 4 digits of SSN", with: "1235")

      fill_in("Pay to the order of", with: "barnabas ngagy")
      fill_in("Routing number", with: "110000000")
      fill_in("Account number", with: "000123456789")
      fill_in("Confirm account number", with: "000123456789")

      click_on("Update settings")

      expect(page).to have_status(text: "We cannot accept a P.O. Box as a valid address.")
      expect(page).not_to have_status(text: "Please complete the required fields below:")
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
      select("January", from: "Month")
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

      expect(page).to have_alert(text: "Thanks! You're all set.")
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

    it "does not show the deprecated Stripe Connect option even if the can_connect_stripe flag is enabled" do
      visit settings_payments_path
      expect(page).not_to have_field("Stripe")

      @user.update!(can_connect_stripe: true)
      refresh
      expect(page).not_to have_field("Stripe")
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

    it "allows Stripe Connect users to update payout schedule without compliance validation" do
      # Create a fresh user with Stripe Connect but no phone number to simulate the reported bug
      # where Stripe Connect users manage compliance info through Stripe, not Gumroad
      creator = create(:user, payment_address: nil)
      create(:user_compliance_info, user: creator, phone: nil)
      create(:merchant_account_stripe_connect, user: creator)
      creator.check_merchant_account_is_linked = true
      creator.save!

      expect(creator.has_stripe_account_connected?).to be true
      expect(creator.alive_user_compliance_info.phone).to be_blank
      expect(creator.payout_frequency).to eq(User::PayoutSchedule::WEEKLY)

      login_as creator
      visit settings_payments_path

      # Verify Stripe Connect section is shown (not the compliance form with phone field)
      expect(page).to have_button("Disconnect Stripe account")
      expect(page).not_to have_field("Phone number")

      # Change payout schedule and submit - the fix should skip compliance validation for Stripe Connect
      expect(page).to have_select("Schedule", selected: "Weekly")
      select "Monthly", from: "Schedule"

      click_on "Update settings"
      wait_for_ajax

      expect(page).to have_alert(text: "Thanks! You're all set.")
      expect(creator.reload.payout_frequency).to eq(User::PayoutSchedule::MONTHLY)
    end

    it "does not allow saving placeholder state values" do
      visit settings_payments_path

      fill_in("First name", with: "barnabas")
      fill_in("Last name", with: "barnabastein")
      fill_in("Address", with: "address_full_match")
      fill_in("City", with: "barnabasville")
      select("State", from: "State")
      fill_in("ZIP code", with: "12345")
      fill_in("Phone number", with: "(502) 254-1982")

      fill_in("Pay to the order of", with: "barnabas ngagy")
      fill_in("Routing number", with: "110000000")
      fill_in("Account number", with: "000123456789")
      fill_in("Confirm account number", with: "000123456789")

      select("1", from: "Day")
      select("January", from: "Month")
      select("1980", from: "Year")
      fill_in("Last 4 digits of SSN", with: "1235")

      expect do
        click_on("Update settings")
        expect(page).to have_status(text: "Please select a valid state or province.")
      end.to_not change { @user.alive_user_compliance_info.reload.state }

      select("California", from: "State")
      expect do
        click_on("Update settings")
        wait_for_ajax
        expect(page).to have_alert(text: "Thanks! You're all set.")
      end.to change { @user.alive_user_compliance_info.reload.state }.to("CA")
    end

    it "does not allow saving placeholder state values for business" do
      visit settings_payments_path

      choose("Business")
      fill_in("Legal business name", with: "Acme")
      select("LLC", from: "Type")
      find_field("Address", match: :first).set("123 North street")
      find_field("City", match: :first).set("Barnesville")
      find_field("State", match: :first).select("State")
      find_field("ZIP code", match: :first).set("12345")
      fill_in("Business phone number", with: "15052229876")
      fill_in("Business Tax ID (EIN, or SSN for sole proprietors)", with: "123456789")

      fill_in("First name", with: "barnabas")
      fill_in("Last name", with: "barnabastein")
      all('input[id$="creator-street-address"]').last.set("address_full_match")
      all('input[id$="creator-city"]').last.set("barnabasville")
      all('select[id$="creator-state"]').last.select("California")
      all('input[id$="creator-zip-code"]').last.set("12345")
      fill_in("Phone number", with: "(502) 254-1982")

      fill_in("Pay to the order of", with: "barnabas ngagy")
      fill_in("Routing number", with: "110000000")
      fill_in("Account number", with: "000123456789")
      fill_in("Confirm account number", with: "000123456789")

      select("1", from: "Day")
      select("January", from: "Month")
      select("1980", from: "Year")
      fill_in("Last 4 digits of SSN", with: "1235")

      expect do
        click_on("Update settings")
        expect(page).to have_status(text: "Please select a valid state or province.")
      end.to_not change { @user.alive_user_compliance_info.reload.business_state }

      find_field("State", match: :first).select("California")
      expect do
        click_on("Update settings")
        wait_for_ajax
        expect(page).to have_alert(text: "Thanks! You're all set.")
      end.to change { @user.alive_user_compliance_info.reload.business_state }.to("CA")
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

        expect(page).to have_alert(text: "Thanks! You're all set.")
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

      it "shows masked SSN with eye icon toggle when tax ID has been entered" do
        visit settings_payments_path

        # Should show masked field, not an empty input
        ssn_field = find_field("Last 4 digits of SSN", disabled: true)
        expect(ssn_field.value).to eq("•••-••-••••")
        expect(ssn_field).to be_disabled

        # Toggle eye icon to reveal last 4 digits
        find("button[aria-label='Show last 4 digits']").click
        ssn_field = find_field("Last 4 digits of SSN", disabled: true)
        expect(ssn_field.value).to eq("•••-••-1234")

        # Toggle back to hide
        find("button[aria-label='Hide tax ID']").click
        ssn_field = find_field("Last 4 digits of SSN", disabled: true)
        expect(ssn_field.value).to eq("•••-••-••••")

        # Click Change to re-enable editing
        click_on("Change")
        ssn_field = find_field("Last 4 digits of SSN")
        expect(ssn_field).not_to be_disabled
        expect(ssn_field.value).to eq("")
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

        within(:alert, text: "You cannot change legal_entity[first_name] via API if an account is verified.")

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

        expect(page).to have_alert(text: "Thanks! You're all set.")
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

      it "shows the verification section when identity verification is needed" do
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
        expect(page).to have_section("Account status")
        expect(page).not_to have_status(text: "Your identity has been verified!")
      end

      it "hides the account status section when verification is not needed" do
        user = create(:user, username: nil, payment_address: nil)
        create(:user_compliance_info, user:, birthday: Date.new(1901, 1, 2))
        create(:ach_account_stripe_succeed, user:)
        create(:tos_agreement, user:)

        StripeMerchantAccountManager.create_account(user, passphrase: "1234")

        expect(user.user_compliance_info_requests.requested.count).to eq(0)

        login_as user
        visit settings_payments_path

        expect(page).not_to have_section("Account status")

        expect(page).not_to have_status(text: "Your identity has been verified!")
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
        expect(page).to have_section("Account status")
        expect(page).not_to have_status(text: "Your identity has been verified!")

        merchant_account.mark_deleted!
        visit settings_payments_path
        expect(page).not_to have_status(text: "Your identity has been verified!")
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
        find_field("Address", match: :first).set("P.O. Box 123, Smith street")
        expect do
          click_on "Update settings"
          expect(page).to have_status(text: "We require a valid physical US address. We cannot accept a P.O. Box as a valid address.")
        end.to_not change { @user.alive_user_compliance_info.reload.street_address }
        find_field("Address", match: :first).set("123, Smith street")
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
          sleep 0.5 # Since the previous Alerts takes time to disappear, checking alert returns early before the api call is complete
        end.to change { @user.alive_user_compliance_info.reload.business_street_address }.to("123 North street")
        find(:css, "input[id$='creator-street-address']").set("po box 123 smith street")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "US LLC Brazilian Rep")
        fill_in("Routing number", with: "110000000")
        fill_in("Account number", with: "000123456789")
        fill_in("Confirm account number", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in USD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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

    describe "US business with EIN already saved, editing non-EIN fields" do
      before do
        create(:ach_account_stripe_succeed, user: @user)
        ActiveRecord::Base.transaction do
          @user.alive_user_compliance_info.mark_deleted!
          create(
            :user_compliance_info_business,
            user: @user,
            business_phone: "+15052426789",
            phone: "+15022541982",
            birthday: Date.new(1980, 1, 1),
          )
        end
      end

      it "saves changes without rejecting the saved EIN" do
        visit settings_payments_path

        fill_in "Address", match: :first, with: "456 Updated Business Lane", fill_options: { clear: :backspace }

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")

        compliance_info = @user.reload.alive_user_compliance_info
        expect(compliance_info.business_street_address).to eq("456 Updated Business Lane")
        expect(compliance_info.business_tax_id.decrypt("1234")).to eq("000000000")
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
        all('select[id$="creator-country"]').last.select("Canada")
        all('input[id$="creator-street-address"]').last.set("address_full_match")
        all('input[id$="creator-city"]').last.set("Toronto")
        all('select[id$="creator-province"]').last.select("Ontario")
        all('input[id$="creator-zip-code"]').last.set("M4C 1T2")
        fill_in("Phone number", with: "5052429876")
        fill_in("Social Insurance Number", with: "111111111")

        select("1", from: "Day")
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "CA Pvt Corp")
        fill_in("Transit #", with: "11000")
        fill_in("Institution #", with: "000")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in CAD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        expect(page).to have_section("Account status")
        expect(page).not_to have_status(text: "Your identity has been verified!")
      end
    end

    it "just shows payment address to a US creator with a payment address setup" do
      @user.update(payment_address: "barny@paypal.com")
      visit settings_payments_path
      expect(page).to have_field("PayPal Email")
    end

    it "warns a Zambian creator that PayPal cannot receive payouts there" do
      old_user_compliance_info = @user.alive_user_compliance_info
      new_user_compliance_info = old_user_compliance_info.dup
      new_user_compliance_info.country = "Zambia"
      ActiveRecord::Base.transaction do
        old_user_compliance_info.mark_deleted!
        new_user_compliance_info.save!
      end

      visit settings_payments_path

      expect(page).to have_field("PayPal Email")
      expect(page).to have_content("PayPal does not let accounts registered in Zambia receive money")
      expect(page).to have_content("bank payouts are not available there either")
    end

    # Zambia used to be the only country this warning knew about. Syria is the regression guard: it
    # is equally rail-less and must be named by the same copy path.
    it "warns a Syrian creator with the same copy, naming their own country" do
      old_user_compliance_info = @user.alive_user_compliance_info
      new_user_compliance_info = old_user_compliance_info.dup
      new_user_compliance_info.country = "Syria"
      ActiveRecord::Base.transaction do
        old_user_compliance_info.mark_deleted!
        new_user_compliance_info.save!
      end

      visit settings_payments_path

      expect(page).to have_field("PayPal Email")
      expect(page).to have_content("PayPal does not let accounts registered in Syrian Arab Republic receive money")
      expect(page).to have_content("bank payouts are not available there either")
    end

    it "does not show the no-payout-rail warning to creators in other countries" do
      @user.update(payment_address: "barny@paypal.com")
      visit settings_payments_path

      expect(page).to have_field("PayPal Email")
      expect(page).to_not have_content("receive money, so a payout to one will fail")
    end

    it "allows US creator to switch to ACH" do
      @user.update(payment_address: "barny@paypal.com")
      visit settings_payments_path
      click_on "Switch to direct deposit"
      expect(page).to_not have_field("PayPal Email")
    end

    it "does not offer direct deposit to an India creator, who cannot complete bank setup" do
      @user.update!(payment_address: "barny@paypal.com")
      old_user_compliance_info = @user.alive_user_compliance_info
      new_user_compliance_info = old_user_compliance_info.dup
      new_user_compliance_info.country = "India"
      ActiveRecord::Base.transaction do
        old_user_compliance_info.mark_deleted!
        new_user_compliance_info.save!
      end

      visit settings_payments_path

      expect(page).to have_field("PayPal Email")
      expect(page).to_not have_button("Switch to direct deposit")
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
      select("January", from: "Month")
      select("1980", from: "Year")
      fill_in("Last 4 digits of SSN", with: "1235")
      click_on("Update settings")
      expect(page).to have_alert(text: "Thanks! You're all set.")

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
      select("January", from: "Month")
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
        expect(find(:select, "Country")).not_to have_selector(:option, "Cuba")
        expect(find(:select, "Country")).not_to have_selector(:option, "Syrian Arab Republic")
        select(@update_country, from: "Country")

        within_modal do
          expect(page).to have_content "Confirm country change"
          expect(page).to have_content "Your payout and identity details are tied to your country, so changing it clears your bank account, name, date of birth and address."
          expect(page).to have_content "You are about to change your country. Please click \"Confirm\" to continue."
          expect(page).to have_button "Cancel"
          expect(page).to have_button "Confirm"
          click_on "Confirm"
        end
        wait_for_ajax
        expect(page).to have_alert(text: "Your country has been updated!")
      end

      # The reported bug: the page is one form with one save button, so a seller who corrects
      # their country and enters their bank details in the same pass gets only the country
      # change. That used to be reported as a plain success, leaving the seller to conclude the
      # bank account had saved when no BankAccount row was ever created (issue #1411).
      it "says the bank details were not saved when they were entered in the same save" do
        visit settings_payments_path
        click_on "Add bank account" if has_button?("Add bank account", wait: 0)
        click_on "Change account" if has_button?("Change account", wait: 0)
        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Routing number", with: "110000000")
        fill_in("Account number", with: "000123456789")
        fill_in("Confirm account number", with: "000123456789")
        select(@update_country, from: "Country")

        within_modal { click_on "Confirm" }
        wait_for_ajax

        expect(page).to have_alert(text: "Your country has been updated to United Kingdom")
        expect(page).to have_alert(text: "please re-enter your bank account and personal details")
        expect(@user.reload.active_bank_account).to be_nil
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

          within_modal do
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
          select("January", from: "Month")
          select("1980", from: "Year")
          select("India", from: "Nationality")
          change_masked_tax_field("Emirates ID")
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
          select("January", from: "Month")
          select("1980", from: "Year")
          select("India", from: "Nationality")
          change_masked_tax_field("Emirates ID")
          fill_in("Emirates ID", with: "000000000000000")

          expect(page).to have_status(text: "PayPal payouts are subject to a 2% processing fee.")
          fill_in("PayPal Email", with: "uaecr@gumroad.com")

          click_on("Update settings")

          within_modal do
            expect(page).to have_content "Confirm payout method change"
            expect(page).to have_content "Due to limitations with our payments provider, changing payout method from bank account to PayPal means that you will have to forfeit your existing balance of #{@user.formatted_balance_to_forfeit(:payout_method_change)}"
            expect(page).to have_content "Please confirm that you're okay forfeiting your balance by typing \"I understand\" below and clicking Confirm."
            click_on "Cancel"
          end

          expect(page).not_to have_content "Confirm payout method change"
          click_on("Update settings")

          within_modal do
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

    context "when there is no compliance info" do
      before do
        @user.alive_user_compliance_info.mark_deleted!
      end

      it "requires selecting a country before proceeding" do
        visit settings_payments_path
        within_modal do
          expect(page).to have_content "Where are you located?"
          expect(page).to have_button "Save", disabled: true
          expect(find(:select, "Country")).not_to have_selector(:option, "Cuba")
          expect(find(:select, "Country")).not_to have_selector(:option, "Syrian Arab Republic")
          select "United States", from: "Country"
          check "I have a valid, government-issued photo ID"
          expect(page).to have_button "Save", disabled: true
          check "I can provide proof of residence in the country above, or my business is registered there"
          expect(page).to have_button "Save", disabled: false
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

      it "keeps the form enabled for team admins" do
        visit settings_payments_path
        expect(page).to have_field("First name", disabled: false)
        expect(page).to have_button("Update settings")
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

      it "allows the creator to open the opt-in modal even if their legal entity name is missing" do
        @creator.fetch_or_build_user_compliance_info
        allow_any_instance_of(UserComplianceInfo).to receive(:legal_entity_name).and_return(nil)

        visit settings_payments_path

        click_on "Opt-in to backtaxes collection"

        expect(page).to have_field("Type your full name to opt-in")
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

        expect(page).to have_status(text: "Your payouts have been paused by Gumroad.")
      end

      it "does not expose the admin pause reason in the warning notice" do
        user.update!(payouts_paused_internally: true, payouts_paused_by: User.last.id)
        user.comments.create!(
          author_id: User.last.id,
          content: "Chargeback rate is too high.",
          comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED
        )

        visit settings_payments_path

        expect(page).to have_status(text: "Your payouts have been paused by Gumroad.")
        expect(page).not_to have_text("Chargeback rate is too high")
      end

      it "shows the warning notice when payouts are paused internally by Stripe" do
        user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
        visit settings_payments_path

        expect(page).to have_status(text: "Your payouts have been paused by Stripe.")
      end

      it "shows the warning notice when payouts are paused internally by the system" do
        user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
        visit settings_payments_path

        expect(page).to have_status(text: "Your payouts have been paused for a security review.")
      end

      it "shows the warning notice when payouts are paused by the user" do
        user.update!(payouts_paused_by_user: true)
        visit settings_payments_path

        expect(page).to have_status(text: "You have paused your payouts.")
      end

      it "does not suggest the pause toggle will resume payouts while the account is under review" do
        user.put_on_probation!(author_name: "test")
        user.update!(payouts_paused_by_user: true)
        visit settings_payments_path

        expect(page).to have_status(text: "You have paused your payouts.")
        expect(page).to have_status(text: "Your account is under review and payouts are on hold until it's resolved.")
        expect(page).not_to have_text("Use the pause payouts toggle below to resume.")
      end
    end

    describe "account status" do
      it "renders compliance actions as direct linked instructions" do
        request = create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::TAX_ID)
        request.verification_error = { "message" => "Please provide your tax ID" }
        request.save!
        visit settings_payments_path

        within_section "Account status", section_element: :section do
          expect(page).to have_text("Please provide your tax ID.")
          expect(page).to have_link("contact support", href: help_center_root_path)
          expect(page).not_to have_text("Action needed")
        end
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
          expect(toggle).to have_tooltip(text: "Your payouts have been paused by Gumroad.")
        end
      end

      it "does not expose the admin pause reason in the toggle tooltip" do
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
          expect(toggle).to have_tooltip(text: "Your payouts have been paused by Gumroad.")
          expect(toggle).not_to have_tooltip(text: "Chargeback rate is too high")
        end
      end

      it "disables the toggle when payouts are paused internally by Stripe" do
        user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
        visit settings_payments_path

        within_section "Payout schedule", section_element: :section do
          toggle = find_field("Pause payouts", disabled: true, checked: true)
          toggle.hover
          expect(toggle).to have_tooltip(text: "Your payouts have been paused by Stripe.")
        end
      end

      it "disables the toggle when payouts are paused internally by the system" do
        user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
        visit settings_payments_path

        within_section "Payout schedule", section_element: :section do
          toggle = find_field("Pause payouts", disabled: true, checked: true)
          toggle.hover
          expect(toggle).to have_tooltip(text: "Your payouts have been paused for a security review.")
        end
      end
    end

    describe "minimum payout threshold" do
      it "allows updating the payout threshold" do
        visit settings_payments_path

        field = find_field("Minimum payout threshold", with: "100")
        field.fill_in(with: "50")

        expect(field["aria-invalid"]).to eq("true")
        expect(page).to have_text("The minimum payout threshold for United States is $100.")
        expect(page).to have_button("Update settings", disabled: true)

        field.fill_in(with: "150")
        expect(field["aria-invalid"]).to eq("false")
        expect(page).to have_text("The minimum payout threshold for United States is $100.")

        click_on "Update settings"

        expect(page).to have_alert(text: "Thanks! You're all set.")
        expect(user.reload.minimum_payout_amount_cents).to eq(15_000)
      end

      context "when the user is in a cross-border payout country" do
        let!(:compliance_info) { create(:user_compliance_info_korea, user:, phone: "+821012345678") }

        before do
          user.active_bank_account.mark_deleted!
          create(:korea_bank_account, user:)
        end

        it "shows the minimum payout threshold for the country" do
          visit settings_payments_path

          field = find_field("Minimum payout threshold", with: "100")
          field.fill_in(with: "50")

          expect(field["aria-invalid"]).to eq("true")
          expect(page).to have_text("The minimum payout threshold for South Korea is $100.")
          expect(page).to have_button("Update settings", disabled: true)

          field.fill_in(with: "150")
          expect(field["aria-invalid"]).to eq("false")
          expect(page).to have_text("The minimum payout threshold for South Korea is $100.")

          click_on "Update settings"

          expect(page).to have_alert(text: "Thanks! You're all set.")
          expect(user.reload.minimum_payout_amount_cents).to eq(15_000)
        end

        it "loads the raw stored payout threshold in the form field, not the effective minimum" do
          user.update!(payout_threshold_cents: 5000)

          visit settings_payments_path

          field = find_field("Minimum payout threshold")
          expect(field.value).to eq("50")

          fill_in "Minimum payout threshold", with: "105", fill_options: { clear: :backspace }

          click_on "Update settings"

          expect(page).to have_alert(text: "Thanks! You're all set.")
          expect(user.reload.payout_threshold_cents).to eq(10_500)
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
