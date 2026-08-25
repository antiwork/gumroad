# frozen_string_literal: true

require "spec_helper"

describe("Payments Settings — mid-country payouts", type: :system, js: true) do
  def change_masked_tax_field(label)
    if has_field?(label, disabled: true, wait: 0)
      field = find_field(label, disabled: true)
      container = field.find(:xpath, "./ancestor::div[.//button[text()='Change']][1]")
      container.find("button", text: "Change", match: :first).click
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

        select("January", from: "Month")
        click_on("Update settings")
        expect(page).to_not have_alert(text: "Thanks! You're all set.")
        expect(find_field("Year")["aria-invalid"]).to eq "true"

        select("1980", from: "Year")
        click_on("Update settings")
        expect(page).to_not have_alert(text: "Thanks! You're all set.")
        expect(find_field("State")["aria-invalid"]).to eq "true"
        expect(page).to have_status(text: "Please select a valid state or province.")

        select("Rio de Janeiro", from: "State")
        click_on("Update settings")
        expect(page).to have_alert(text: "Thanks! You're all set.")
      end

      it "allows the (non-US based) creator to enter their kyc and paypal email address and it'll save it properly" do
        visit settings_payments_path

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "5022541982")
        fill_in("Postal code", with: "12345")
        select("Rio de Janeiro", from: "State")

        select("1", from: "Day")
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("PayPal Email", with: "valid@gumroad.com")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("São Paulo", from: "State")
        select("1", from: "Day")
        select("January", from: "Month")
        select("1990", from: "Year")
        expect do
          click_on "Update settings"
          wait_for_ajax
          expect(page).to have_alert(text: "Thanks! You're all set.")
        end.to change { @user.alive_user_compliance_info.reload.street_address }.to("P.O. Box 123, Tokyo central hall")
      end

      describe "BR business" do
        before do
          old_user_compliance_info = @user.alive_user_compliance_info
          new_user_compliance_info = old_user_compliance_info.dup
          new_user_compliance_info.country = "Brazil"
          ActiveRecord::Base.transaction do
            old_user_compliance_info.mark_deleted!
            new_user_compliance_info.save!
          end
          expect(@user.active_bank_account).to be nil
          expect(@user.stripe_account).to be nil
        end

        it "allows to enter PayPal address" do
          visit settings_payments_path

          choose "Business"

          fill_in("Legal business name", with: "BR LLC")
          select("Sole Proprietorship", from: "Type")
          find_field("Address", match: :first).set("address_full_match")
          find_field("City", match: :first).set("Curitiba")
          all('select[id$="business-state"]').last.select("Paraná")
          find_field("Postal code", match: :first).set("81010-250")
          fill_in("Business phone number", with: "5022541982")

          fill_in("First name", with: "Brazilian")
          fill_in("Last name", with: "Creator")
          all('select[id$="creator-country"]').last.select("Brazil")
          all('input[id$="creator-street-address"]').last.set("address_full_match")
          all('input[id$="creator-city"]').last.set("Curitiba")
          all('select[id$="creator-state"]').last.select("Paraná")
          all('input[id$="creator-zip-code"]').last.set("81010-250")
          fill_in("Phone number", with: "5022541982")

          select("1", from: "Day")
          select("January", from: "Month")
          select("1980", from: "Year")

          fill_in("PayPal Email", with: "br@example.com")

          click_on("Update settings")

          expect(page).to have_alert(text: "Thanks! You're all set.")

          compliance_info = @user.alive_user_compliance_info
          expect(compliance_info.is_business).to be true
          expect(compliance_info.business_name).to eq("BR LLC")
          expect(compliance_info.business_street_address).to eq("address_full_match")
          expect(compliance_info.business_city).to eq("Curitiba")
          expect(compliance_info.business_state).to eq("PR")
          expect(compliance_info.business_country).to eq("Brazil")
          expect(compliance_info.business_zip_code).to eq("81010-250")
          expect(compliance_info.business_phone).to eq("+555022541982")
          expect(compliance_info.business_type).to eq("sole_proprietorship")
          expect(compliance_info.first_name).to eq("Brazilian")
          expect(compliance_info.last_name).to eq("Creator")
          expect(compliance_info.street_address).to eq("address_full_match")
          expect(compliance_info.city).to eq("Curitiba")
          expect(compliance_info.state).to eq("PR")
          expect(compliance_info.country).to eq("Brazil")
          expect(compliance_info.zip_code).to eq("81010-250")
          expect(compliance_info.phone).to eq("+555022541982")
          expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
          expect(@user.reload.payment_address).to eq("br@example.com")
        end
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
        fill_in("Postal code", with: "1234")

        select("1", from: "Day")
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "DE89370400440532013000")
        fill_in("Confirm IBAN", with: "DE89370400440532013000")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in EUR.")

        click_on("Update settings")
        expect(page).to have_content("We couldn't verify the postal code you entered for Germany. Please double-check it — but if you're sure it's correct (for example, a newly built address), you don't need to do anything. New postal codes can take a few days to a few weeks to reach our payment partner's records, so we'll automatically re-check yours once a week for up to #{RetryStripeRejectedPayoutSetupsJob::RETRY_WINDOW_WEEKS} weeks, and only reach out if we still can't verify it.")

        fill_in("Postal code", with: "01067")
        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
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

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        all('select[id$="creator-country"]').last.select("Canada")
        all('input[id$="creator-street-address"]').last.set("address_full_match")
        all('input[id$="creator-city"]').last.set("Toronto")
        all('select[id$="creator-province"]').last.select("Ontario")
        all('input[id$="creator-zip-code"]').last.set("M4C 1T2")
        fill_in("Phone number", with: "5052426789")
        fill_in("Social Insurance Number", with: "000000000")

        select("1", from: "Day")
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "CA LLC")
        fill_in("Transit #", with: "110000")
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
        expect(compliance_info.business_name).to eq("CA LLC")
        expect(compliance_info.business_street_address).to eq("address_full_match")
        expect(compliance_info.business_city).to eq("Toronto")
        expect(compliance_info.business_state).to eq("ON")
        expect(compliance_info.business_country).to eq("Canada")
        expect(compliance_info.business_zip_code).to eq("M4C 1T2")
        expect(compliance_info.business_phone).to eq("+15052426789")
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
        select("January", from: "Month")
        select("1980", from: "Year")
        # Must be a real NRIC/FIN shape (letter + 7 digits + letter) — the save path now
        # rejects letterless values like "000000000" so sellers can't get stuck in a
        # Stripe verification loop with an ID Stripe will never match.
        fill_in("NRIC number / FIN", with: "S1234567D")
        select("India", from: "Nationality")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Bank code", with: "1100")
        fill_in("Branch code", with: "000")
        fill_in("Account #", with: "000123456")
        fill_in("Confirm account #", with: "000123456")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in SGD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Bank code", with: "999")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in THB.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        expect(page).to have_field("IBAN")

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "987654321")
        fill_in("Postal code", with: "1138")

        select("1", from: "Day")
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "BG80BNBG96611020345678")
        fill_in("Confirm IBAN", with: "BG80BNBG96611020345678")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in EUR.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "DK5000400440116243")
        fill_in("Confirm IBAN", with: "DK5000400440116243")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in DKK.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "HU42117730161111101800000000")
        fill_in("Confirm IBAN", with: "HU42117730161111101800000000")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in HUF.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Bank code", with: "SGSEKRSLXXX")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in KRW.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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

        choose "Bank Account"

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
        change_masked_tax_field("Emirates ID")
        fill_in("Emirates ID", with: "000000000000000")

        select("1", from: "Day")
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "uae biz")
        fill_in("IBAN", with: "AE070331234567890123456")
        fill_in("Confirm IBAN", with: "AE070331234567890123456")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in AED.")
        expect(page).not_to have_content("Individual accounts from the UAE are not supported. Please use a business account.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        expect(page).to have_section("Account status")
        expect(page).not_to have_status(text: "Your identity has been verified!")
      end

      it "allows the creator to use paypal payouts as an individual" do
        user = create(:user, username: nil, payment_address: nil)
        create(:user_compliance_info_uae_business, user:, birthday: Date.new(1901, 1, 2))
        create(:uae_bank_account, user:)
        create(:tos_agreement, user:)
        create(:merchant_account, user:)

        login_as user
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

        expect(page).to have_alert(text: "Thanks! You're all set.")
        compliance_info = user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("51133")
        expect(compliance_info.phone).to eq("+97198765432")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(user.reload.payment_address).to eq("uaecr@gumroad.com")
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
        select("January", from: "Month")
        select("1980", from: "Year")
        select("India", from: "Nationality")
        change_masked_tax_field("Emirates ID")
        fill_in("Emirates ID", with: "000000000000000")

        expect(page).to have_status(text: "PayPal payouts are subject to a 2% processing fee.")
        fill_in("PayPal Email", with: "uaecr@gumroad.com")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")
        select("India", from: "Nationality")
        change_masked_tax_field("Emirates ID")
        fill_in("Emirates ID", with: "000000000000000")

        expect(page).not_to have_status(text: "PayPal payouts are subject to a 2% processing fee.")
        fill_in("PayPal Email", with: "uaecr@gumroad.com")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "IL620108000000099999999")
        fill_in("Confirm IBAN", with: "IL620108000000099999999")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in ILS.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Bank code", with: "999")
        fill_in("Branch code", with: "00001")
        fill_in("Account #", with: "00567890123456789")
        fill_in("Confirm account #", with: "00567890123456789")
        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in TTD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Bank Identifier Code (BIC)", with: "BCDEPHM1123")
        fill_in("Account #", with: "01567890123456789")
        fill_in("Confirm account #", with: "01567890123456789")
        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in PHP.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "RO49AAAA1B31007593840000")
        fill_in("Confirm IBAN", with: "RO49AAAA1B31007593840000")
        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in RON.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "SE3550000000054910000003")
        fill_in("Confirm IBAN", with: "SE3550000000054910000003")
        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in SEK.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")
        fill_in("Personal RFC", with: "0000000000000")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Account number", with: "000000001234567897")
        fill_in("Confirm account number", with: "000000001234567897")
        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MXN.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        select("Checking", from: "Account Type")
        fill_in("Bank Code", with: "060")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")
        # Six digits: the shortest Cédula de Ciudadanía or Cédula de Extranjería number Stripe
        # accepts for Colombia.
        fill_in("Cédula de Ciudadanía (CC) or Cédula de Extranjería (CE)", with: "482913")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in COP.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
        expect(page).to have_content("Bank code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.individual_tax_id.decrypt("1234")).to eq("482913")
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
        select("January", from: "Month")
        select("1980", from: "Year")
        fill_in("CUIL", with: "00-00000000-0")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Account number", with: "0110000600000000000000")
        fill_in("Confirm account number", with: "0110000600000000000000")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in ARS.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")
        fill_in("DNI number", with: "00000000-0")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Account number", with: "99934500012345670024")
        fill_in("Confirm account number", with: "99934500012345670024")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in PEN.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Norwegian Creator")
        fill_in("IBAN", with: "NO9386011117947")
        fill_in("Confirm IBAN", with: "NO9386011117947")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in NOK.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "IE29AIBK93115212345678")
        fill_in("Confirm IBAN", with: "IE29AIBK93115212345678")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in EUR.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Liechtenstein Creator")
        fill_in("IBAN", with: "LI0508800636123378777")
        fill_in("Confirm IBAN", with: "LI0508800636123378777")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in CHF.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Bank code", with: "000")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in IDR.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "CR04010212367856709123")
        fill_in("Confirm IBAN", with: "CR04010212367856709123")
        fill_in("Tax Identification Number", with: "1234567890")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in CRC.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("SWIFT / BIC Code", with: "RIBLSARIXXX")
        fill_in("IBAN", with: "SA4420000001234567891234")
        fill_in("Confirm IBAN", with: "SA4420000001234567891234")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in SAR.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
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

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
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

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("SWIFT / BIC Code", with: "FIRNZAJJ")
        fill_in("Account #", with: "000001234")
        fill_in("Confirm account #", with: "000001234")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in ZAR.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("SWIFT / BIC Code", with: "BARCKENXMDR")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in KES.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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

        choose "Bank Account"

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "9876543210")
        fill_in("Postal code", with: "10110")

        select("1", from: "Day")
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("SWIFT / BIC Code", with: "NBEGEGCX331")
        fill_in("IBAN", with: "EG800002000156789012345180002")
        fill_in("Confirm IBAN", with: "EG800002000156789012345180002")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in EGP.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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

      it "allows to enter PayPal details" do
        visit settings_payments_path

        choose "PayPal"

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "9876543210")
        fill_in("Postal code", with: "10110")

        select("1", from: "Day")
        select("January", from: "Month")
        select("1980", from: "Year")

        expect(page).to have_status(text: "PayPal payouts are subject to a 2% processing fee.")
        fill_in("PayPal Email", with: "egycr@example.com")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("10110")
        expect(compliance_info.country).to eq("Egypt")
        expect(compliance_info.phone).to eq("+209876543210")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.payment_address).to eq("egycr@example.com")
        expect(@user.active_bank_account).to be nil
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Bosnia and Herzegovina Creator")
        fill_in("SWIFT / BIC Code", with: "AAAABABAXXX")
        fill_in("IBAN", with: "BA095520001234567812")
        fill_in("Confirm IBAN", with: "BA095520001234567812")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in BAM.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("SWIFT / BIC Code", with: "AAAAMAMAXXX")
        fill_in("IBAN", with: "MA64011519000001205000534921")
        fill_in("Confirm IBAN", with: "MA64011519000001205000534921")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MAD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("SWIFT / BIC Code", with: "TESTSERBXXX")
        fill_in("IBAN", with: "RS35105008123123123173")
        fill_in("Confirm IBAN", with: "RS35105008123123123173")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in RSD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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

        choose "Bank Account"

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Almaty")
        fill_in("Phone number", with: "7012345678")
        fill_in("Postal code", with: "050000")

        select("1", from: "Day")
        select("January", from: "Month")
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

      it "allows to enter PayPal details" do
        visit settings_payments_path

        choose "PayPal"

        fill_in("First name", with: "barnabas")
        fill_in("Last name", with: "barnabastein")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "barnabasville")
        fill_in("Phone number", with: "9876543210")
        fill_in("Postal code", with: "10110")

        select("1", from: "Day")
        select("January", from: "Month")
        select("1980", from: "Year")

        expect(page).to have_status(text: "PayPal payouts are subject to a 2% processing fee.")
        fill_in("PayPal Email", with: "kzcr@example.com")

        click_on("Update settings")

        expect(page).to have_content("Thanks! You're all set.")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("barnabasville")
        expect(compliance_info.zip_code).to eq("10110")
        expect(compliance_info.country).to eq("Kazakhstan")
        expect(compliance_info.phone).to eq("+79876543210")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.payment_address).to eq("kzcr@example.com")
        expect(@user.active_bank_account).to be nil
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("SWIFT / BIC Code", with: "AAAAECE1XXX")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in USD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Antigua and Barbuda Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAAGAGXYZ")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in XCD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Tanzanian Creator")
        fill_in("SWIFT / BIC Code", with: "AAAATZTXXXX")
        fill_in("Account #", with: "0000123456789")
        fill_in("Confirm account #", with: "0000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in TZS.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Namibian Creator")
        fill_in("SWIFT / BIC Code", with: "AAAANANXXYZ")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in NAD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Albanian Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAALTXXXX")
        fill_in("IBAN", with: "AL35202111090000000001234567")
        fill_in("Confirm IBAN", with: "AL35202111090000000001234567")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in ALL.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Bahraini Creator")
        fill_in("SWIFT / BIC Code", with: "AAAABHBMXYZ")
        fill_in("IBAN", with: "BH29BMAG1299123456BH00")
        fill_in("Confirm IBAN", with: "BH29BMAG1299123456BH00")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in BHD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Rwandan Creator")
        fill_in("SWIFT / BIC", with: "AAAARWRWXXX")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in RWF.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Jordanian Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAJOJOXXX")
        fill_in("IBAN", with: "JO32ABCJ0010123456789012345678")
        fill_in("Confirm IBAN", with: "JO32ABCJ0010123456789012345678")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in JOD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Nigerian Creator")
        fill_in("SWIFT / BIC Code", with: "AAAANGLAXXX")
        fill_in("Account #", with: "1111111112")
        fill_in("Confirm account #", with: "1111111112")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in NGN.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Azerbaijani Creator")
        fill_in("Bank code", with: "123456")
        fill_in("Branch code", with: "123456")
        fill_in("IBAN", with: "AZ77ADJE12345678901234567890")
        fill_in("Confirm IBAN", with: "AZ77ADJE12345678901234567890")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in AZN.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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

      it "rejects invalid kana characters" do
        visit settings_payments_path

        fill_in("First name", with: "japanese")
        fill_in("Last name", with: "creator")
        fill_in("First name / 名 (Kanji)", with: "日本語")
        fill_in("Last name / 姓 (Kanji)", with: "創造者")
        fill_in("First name / メイ (Kana)", with: "ニホンゴ")
        fill_in("Last name / セイ (Kana)", with: "ソウゾウシャ）")
        fill_in("Block / Building number", with: "1-1")
        fill_in("Block / Building number (Kana)", with: "イチノイチ")
        fill_in("Town/Cho-me (Kanji)", with: "日本語")
        fill_in("Town/Cho-me (Kana)", with: "ニホンゴ")
        select("東京都", from: "Prefecture")
        fill_in("Phone number", with: "987654321")
        fill_in("Postal code", with: "100-0000")
        select("1", from: "Day")
        select("January", from: "Month")
        select("1980", from: "Year")
        fill_in("Pay to the order of", with: "japanese creator")
        fill_in("Bank code", with: "1100")
        fill_in("Branch code", with: "000")
        fill_in("Account #", with: "0001234")
        fill_in("Confirm account #", with: "0001234")

        click_on("Update settings")
        expect(page).to have_status(text: "Last name (Kana) may only contain katakana characters, spaces, dashes, and dots.")
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "japanese")
        fill_in("Last name", with: "creator")
        fill_in("First name / 名 (Kanji)", with: "日本語")
        fill_in("Last name / 姓 (Kanji)", with: "創造者")
        fill_in("First name / メイ (Kana)", with: "ニホンゴ")
        fill_in("Last name / セイ (Kana)", with: "ソウゾウシャ")
        fill_in("Block / Building number", with: "1-1")
        fill_in("Block / Building number (Kana)", with: "イチノイチ")
        fill_in("Town/Cho-me (Kanji)", with: "日本語")
        fill_in("Town/Cho-me (Kana)", with: "ニホンゴ")
        fill_in("City/Ward (Kanji)", with: "渋谷区")
        fill_in("City/Ward (Kana)", with: "シブヤク")
        select("東京都", from: "Prefecture")
        fill_in("Phone number", with: "987654321")
        fill_in("Postal code", with: "100-0000")

        select("1", from: "Day")
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "japanese creator")
        fill_in("Bank code", with: "1100")
        fill_in("Branch code", with: "000")
        fill_in("Account #", with: "0001234")
        fill_in("Confirm account #", with: "0001234")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in JPY.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        expect(compliance_info.city).to eq("渋谷区")
        expect(compliance_info.city_kana).to eq("シブヤク")
        expect(compliance_info.state).to eq("東京都")
        expect(compliance_info.zip_code).to eq("100-0000")
        expect(compliance_info.phone).to eq("+81987654321")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("0001234")
      end
    end

    describe "Japanese business creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Japan"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "rejects Japanese characters in legal business name" do
        visit settings_payments_path

        fill_in("First name", with: "japanese")
        fill_in("Last name", with: "creator")
        fill_in("First name / 名 (Kanji)", with: "日本語")
        fill_in("Last name / 姓 (Kanji)", with: "創造者")
        fill_in("First name / メイ (Kana)", with: "ニホンゴ")
        fill_in("Last name / セイ (Kana)", with: "ソウゾウシャ")
        fill_in("Block / Building number", with: "1-1")
        fill_in("Block / Building number (Kana)", with: "イチノイチ")
        fill_in("Town/Cho-me (Kanji)", with: "日本語")
        fill_in("Town/Cho-me (Kana)", with: "ニホンゴ")
        select("東京都", from: "Prefecture")
        fill_in("Phone number", with: "987654321")
        fill_in("Postal code", with: "100-0000")
        select("1", from: "Day")
        select("January", from: "Month")
        select("1980", from: "Year")

        choose "Business"

        fill_in("Legal business name", with: "サクラショウテン", match: :first)
        select("LLC", from: "Type")
        fill_in("Business Name (Kanji)", with: "桜商店株式会社")
        fill_in("Legal Business Name (Kana)", with: "サクラショウテン")
        find(:fillable_field, id: /business-building-number$/).set("1-1")
        find(:fillable_field, id: /business-building-number-kana$/).set("イチノイチ")
        fill_in("Business town/Cho-me (Kanji)", with: "日本語")
        fill_in("Business town/Cho-me (Kana)", with: "ニホンゴ")
        find(:select, id: /business-prefecture/).select("東京都")
        fill_in("Business phone number", with: "987654321")

        fill_in("Pay to the order of", with: "japanese creator")
        fill_in("Bank code", with: "1100")
        fill_in("Branch code", with: "000")
        fill_in("Account #", with: "0001234")
        fill_in("Confirm account #", with: "0001234")

        click_on("Update settings")
        expect(page).to have_status(text: "Legal business name must be in romaji (latin characters) for Japanese accounts")
      end

      it "clears stale error message after fixing the field and resubmitting" do
        visit settings_payments_path

        fill_in("First name", with: "japanese")
        fill_in("Last name", with: "creator")
        fill_in("First name / 名 (Kanji)", with: "日本語")
        fill_in("Last name / 姓 (Kanji)", with: "創造者")
        fill_in("First name / メイ (Kana)", with: "ニホンゴ")
        fill_in("Last name / セイ (Kana)", with: "ソウゾウシャ")
        fill_in("Block / Building number", with: "1-1")
        fill_in("Block / Building number (Kana)", with: "イチノイチ")
        fill_in("Town/Cho-me (Kanji)", with: "日本語")
        fill_in("Town/Cho-me (Kana)", with: "ニホンゴ")
        select("東京都", from: "Prefecture")
        fill_in("Phone number", with: "987654321")
        fill_in("Postal code", with: "100-0000")
        select("1", from: "Day")
        select("January", from: "Month")
        select("1980", from: "Year")

        choose "Business"

        fill_in("Legal business name", with: "サクラショウテン", match: :first)
        select("LLC", from: "Type")
        fill_in("Business Name (Kanji)", with: "桜商店株式会社")
        fill_in("Legal Business Name (Kana)", with: "サクラショウテン")
        find(:fillable_field, id: /business-building-number$/).set("1-1")
        find(:fillable_field, id: /business-building-number-kana$/).set("イチノイチ")
        fill_in("Business town/Cho-me (Kanji)", with: "日本語")
        fill_in("Business town/Cho-me (Kana)", with: "ニホンゴ")
        find(:select, id: /business-prefecture/).select("東京都")
        fill_in("Business phone number", with: "987654321")

        fill_in("Pay to the order of", with: "japanese creator")
        fill_in("Bank code", with: "1100")
        fill_in("Branch code", with: "000")
        fill_in("Account #", with: "0001234")
        fill_in("Confirm account #", with: "0001234")

        click_on("Update settings")
        expect(page).to have_status(text: "Legal business name must be in romaji (latin characters) for Japanese accounts")

        fill_in("Legal business name", with: "Sakura Shoten", match: :first)
        click_on("Update settings")
        expect(page).not_to have_status(text: "Legal business name must be in romaji (latin characters) for Japanese accounts")
      end
    end
  end
end
