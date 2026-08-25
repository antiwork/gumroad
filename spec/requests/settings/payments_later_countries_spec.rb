# frozen_string_literal: true

require "spec_helper"

describe("Payments Settings — later-country payouts", type: :system, js: true) do
  describe("Payout Information Collection", type: :system, js: true) do
    include_context "with Stripe API stubs"

    before do
      @user = create(:named_user, payment_address: nil)
      user_compliance_info = @user.fetch_or_build_user_compliance_info
      user_compliance_info.country = "United States"
      user_compliance_info.save!
      login_as @user
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("Sort code", with: "10-88-00")
        fill_in("Account #", with: "00012345")
        fill_in("Confirm account #", with: "00012345")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in GBP.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("barnabas")
        expect(compliance_info.last_name).to eq("barnabastein")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Gibraltar")
        expect(compliance_info.zip_code).to eq("GX11 1AA")
        expect(compliance_info.phone).to eq("+35020079123")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("00012345")
        expect(@user.reload.active_bank_account.routing_number).to eq("10-88-00")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "botswana creator")
        fill_in("SWIFT / BIC Code", with: "AAAABWBWXXX")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in BWP.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "uruguayan creator")
        fill_in("Bank code", with: "999")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")
        fill_in("Cédula de Identidad (CI)", with: "1.123.123-1")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in UYU.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "mauritian creator")
        fill_in("SWIFT / BIC Code", with: "AAAAMUMUXYZ")
        fill_in("IBAN", with: "MU17BOMM0101101030300200000MUR")
        fill_in("Confirm IBAN", with: "MU17BOMM0101101030300200000MUR")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MUR.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "ghanaian creator")
        fill_in("Bank code", with: "022112")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in GHS.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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

      it "allows saving unrelated changes when a legacy individual P.O. Box address is unchanged" do
        allow_any_instance_of(User).to receive(:can_setup_paypal_payouts?).and_return(true)
        @user.update!(payment_address: "ghanaian@example.com")
        @user.alive_user_compliance_info.dup_and_save! do |new_compliance_info|
          new_compliance_info.first_name = "ghanaian"
          new_compliance_info.last_name = "creator"
          new_compliance_info.street_address = "PO Box 99, Accra"
          new_compliance_info.city = "Accra"
          new_compliance_info.phone = "+233302213850"
          new_compliance_info.zip_code = "00233"
          new_compliance_info.birthday = Date.new(1980, 1, 1)
        end

        visit settings_payments_path

        fill_in("First name", with: "newfirst")
        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
        expect(@user.reload.alive_user_compliance_info.first_name).to eq("newfirst")
        expect(@user.alive_user_compliance_info.street_address).to eq("PO Box 99, Accra")
      end

      it "allows saving unrelated changes when a hidden legacy business P.O. Box address is unchanged for an individual" do
        allow_any_instance_of(User).to receive(:can_setup_paypal_payouts?).and_return(true)
        @user.update!(payment_address: "ghanaian@example.com")
        @user.alive_user_compliance_info.dup_and_save! do |new_compliance_info|
          new_compliance_info.first_name = "ghanaian"
          new_compliance_info.last_name = "creator"
          new_compliance_info.street_address = "address_full_match"
          new_compliance_info.business_street_address = "PO Box 77, Accra"
          new_compliance_info.city = "Accra"
          new_compliance_info.phone = "+233302213850"
          new_compliance_info.zip_code = "00233"
          new_compliance_info.birthday = Date.new(1980, 1, 1)
        end

        visit settings_payments_path

        fill_in("First name", with: "newfirst")
        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
        expect(@user.reload.alive_user_compliance_info.first_name).to eq("newfirst")
        expect(@user.alive_user_compliance_info.business_street_address).to eq("PO Box 77, Accra")
      end

      it "does not allow saving an individual P.O. Box address" do
        visit settings_payments_path

        choose "Individual"
        fill_in("Phone number", with: "302213850")

        find_field("Address", match: :first).set("P.O. Box 123, High street")

        expect do
          click_on "Update settings"
          expect(page).to have_status(text: "We require a valid physical address in Ghana. We cannot accept a P.O. Box as a valid address.")
        end.to_not change { @user.alive_user_compliance_info.reload.street_address }
      end

      it "does not allow saving a business P.O. Box address" do
        visit settings_payments_path

        fill_in("First name", with: "ghanaian")
        fill_in("Last name", with: "creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Accra")
        fill_in("Phone number", with: "302213850")
        fill_in("Postal code", with: "00233")

        select("1", from: "Day")
        select("January", from: "Month")
        select("1980", from: "Year")

        choose "Business"

        fill_in "Legal business name", with: "Acme"
        select("LLC", from: "Type")
        find_field("Address", match: :first).set("PO Box 123 High street")
        find_field("City", match: :first).set("Accra")
        find_field("Postal code", match: :first).set("00233")
        fill_in "Business phone number", with: "302213850"
        fill_in "Company tax ID", with: "000000000"

        fill_in("Pay to the order of", with: "ghanaian creator")
        fill_in("Bank code", with: "022112")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect do
          click_on "Update settings"
          expect(page).to have_status(text: "We require a valid physical address in Ghana. We cannot accept a P.O. Box as a valid address.")
        end.to_not change { @user.alive_user_compliance_info.reload.business_street_address }
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "jamaican creator")
        fill_in("Bank code", with: "111")
        fill_in("Branch code", with: "00000")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in JMD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "omani creator")
        fill_in("SWIFT / BIC", with: "AAAAOMOMXXX")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in OMR.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "tunisian creator")
        fill_in("IBAN", with: "TN5904018104004942712345")
        fill_in("Confirm IBAN", with: "TN5904018104004942712345")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in TND.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Dominican Republic Creator")
        fill_in("Bank code", with: "999")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")
        fill_in("Cédula de identidad y electoral (CIE)", with: "123-1234567-1")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in DOP.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Uzbekistan Creator")
        fill_in("SWIFT/BIC code", with: "AAAAUZUZXXX")
        fill_in("MFO (branch code)", with: "00000")
        fill_in("Account #", with: "99934500012345670024")
        fill_in("Confirm account #", with: "99934500012345670024")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in UZS.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Chuck Bartowski")
        fill_in("Bank code", with: "040")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")
        fill_in("Cédula de Identidad (CI)", with: "00123456")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in BOB.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Gabonese Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAGAGAXXX")
        fill_in("Account #", with: "00001234567890123456789")
        fill_in("Confirm account #", with: "00001234567890123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in XAF.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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

    describe "Gambia creator" do
      before do
        old_user_compliance_info = @user.alive_user_compliance_info
        new_user_compliance_info = old_user_compliance_info.dup
        new_user_compliance_info.country = "Gambia"
        ActiveRecord::Base.transaction do
          old_user_compliance_info.mark_deleted!
          new_user_compliance_info.save!
        end
      end

      it "allows to enter bank account details" do
        visit settings_payments_path

        fill_in("First name", with: "Gambian")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "Banjul")
        fill_in("Phone number", with: "3123456")

        # Gambia has no postal codes in its official addressing format, so the field is not shown
        # and saving without one has to work.
        expect(page).to have_no_field("Postal code")

        select("1", from: "Day")
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Gambian Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAGMGMXYZ")
        fill_in("Account #", with: "000123000456000789")
        fill_in("Confirm account #", with: "000123000456000789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in GMD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Gambian")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("Banjul")
        expect(compliance_info.zip_code).to be_blank
        expect(compliance_info.phone).to eq("+2203123456")
        expect(compliance_info.birthday).to eq(Date.new(1980, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123000456000789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAGMGMXYZ")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Monaco Creator")
        fill_in("IBAN", with: "MC5810096180790123456789085")
        fill_in("Confirm IBAN", with: "MC5810096180790123456789085")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in EUR.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Moldova Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAMDMDXXX")
        fill_in("IBAN", with: "MD07AG123456789012345678")
        fill_in("Confirm IBAN", with: "MD07AG123456789012345678")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MDL.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "barnabas ngagy")
        fill_in("IBAN", with: "MK49250120000058907")
        fill_in("Confirm IBAN", with: "MK49250120000058907")
        fill_in("SWIFT / BIC Code", with: "AAAAMK2XXXX")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MKD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Ethiopia Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAETETXXX")
        fill_in("Account #", with: "0000000012345")
        fill_in("Confirm account #", with: "0000000012345")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in ETB.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Brunei Creator")
        fill_in("SWIFT / BIC Code", with: "AAAABNBBXXX")
        fill_in("Account #", with: "0000123456789")
        fill_in("Confirm account #", with: "0000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in BND.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Guyana Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAGYGGXYZ")
        fill_in("Branch code", with: "12345678")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in GYD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
        expect(page).to have_content("SWIFT/BIC and branch code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("Guyana")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("guy")
        expect(compliance_info.zip_code).to eq("1100")
        expect(compliance_info.phone).to eq("+5926291234")
        expect(compliance_info.birthday).to eq(Date.new(1901, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("000123456789")
        expect(@user.reload.active_bank_account.routing_number).to eq("AAAAGYGGXYZ-12345678")
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
        select("January", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Guatemala Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAGTGCXYZ")
        fill_in("IBAN", with: "GT82TRAJ01020000001210029690")
        fill_in("Confirm IBAN", with: "GT82TRAJ01020000001210029690")

        fill_in("Número de Identificación Tributaria (NIT)", with: "1234567-8")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in GTQ.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Panamanian creator")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")
        fill_in("SWIFT / BIC Code", with: "AAAAPAPAXXX")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in USD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
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

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Bhutan Creator")
        fill_in("SWIFT / BIC Code", with: "AAAABTBTXXX")
        fill_in("Account #", with: "0000123456789")
        fill_in("Confirm account #", with: "0000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in BTN.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Laos Creator")
        fill_in("SWIFT / BIC Code", with: "AAAALALAXXX")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in LAK.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Mozambique Taxpayer Single ID Number (NUIT)", with: "000000000")

        fill_in("Pay to the order of", with: "Mozambique Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAMZMXXXX")
        fill_in("Account #", with: "001234567890123456789")
        fill_in("Confirm account #", with: "001234567890123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MZN.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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

      # The account-number inputs carry a per-country `pattern`, but this page saves through Inertia
      # rather than submitting the form, so the browser never enforces it — Show.tsx runs the same
      # check itself. This is the only test that covers that wiring: delete the call and the field
      # goes back to hinting a format nothing checks, which is the bug this all exists to fix.
      it "refuses to save an account number its bank-account model would reject" do
        visit settings_payments_path

        fill_in("First name", with: "Mozambique")
        fill_in("Last name", with: "Creator")
        fill_in("Address", with: "address_full_match")
        fill_in("City", with: "mz")
        fill_in("Phone number", with: "811234567")
        fill_in("Postal code", with: "43200")

        select("1", from: "Day")
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Mozambique Taxpayer Single ID Number (NUIT)", with: "000000000")

        fill_in("Pay to the order of", with: "Mozambique Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAMZMXXXX")
        # The generic example the form used to show every non-IBAN country. MozambiqueBankAccount
        # requires exactly 21 characters, so this can never save.
        fill_in("Account #", with: "1234567890")
        fill_in("Confirm account #", with: "1234567890")

        click_on("Update settings")

        expect(page).to have_status(text: "Enter your 21-character NIB, without the MZ IBAN prefix")
        expect(@user.reload.active_bank_account).to be_nil
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
        select("January", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "El Salvadorian Creator")
        fill_in("Account number", with: "12345678901234")
        fill_in("Confirm account number", with: "12345678901234")
        fill_in("SWIFT / BIC Code", with: "AAAASVS1XXX")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in USD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
        expect(page).to have_content("SWIFT / BIC code")
        compliance_info = @user.alive_user_compliance_info
        expect(compliance_info.first_name).to eq("El Salvadorian")
        expect(compliance_info.last_name).to eq("Creator")
        expect(compliance_info.street_address).to eq("address_full_match")
        expect(compliance_info.city).to eq("San Salvador")
        expect(compliance_info.zip_code).to eq("1101")
        expect(compliance_info.phone).to eq("+50368765432")
        expect(compliance_info.birthday).to eq(Date.new(1901, 1, 1))
        expect(@user.reload.active_bank_account.send(:account_number_decrypted)).to eq("12345678901234")
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
        select("January", from: "Month")
        select("1901", from: "Year")

        fill_in("Pay to the order of", with: "Paraguayan Creator")
        fill_in("Bank code", with: "0")
        fill_in("Account #", with: "0567890123456789")
        fill_in("Confirm account #", with: "0567890123456789")
        fill_in("Cédula de Identidad (CI)", with: "1234567")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in PYG.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Armenian Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAAMNNXXX")
        fill_in("Account #", with: "00001234567")
        fill_in("Confirm account #", with: "00001234567")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in AMD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "malagasy creator")
        fill_in("SWIFT / BIC Code", with: "AAAAMGMGXXX")
        fill_in("IBAN", with: "MG4800005000011234567890123")
        fill_in("Confirm IBAN", with: "MG4800005000011234567890123")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MGA.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Sri Lankan Creator")
        fill_in("Bank code", with: "AAAALKLXXXX")
        fill_in("Branch code", with: "7010999")
        fill_in("Account #", with: "0000012345")
        fill_in("Confirm account #", with: "0000012345")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in LKR.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Kuwaiti Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAKWKWXYZ")
        fill_in("IBAN", with: "KW81CBKU0000000000001234560101")
        fill_in("Confirm IBAN", with: "KW81CBKU0000000000001234560101")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in KWD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Icelandic Creator")
        fill_in("IBAN", with: "IS140159260076545510730339")
        fill_in("Confirm IBAN", with: "IS140159260076545510730339")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in EUR.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Qatar Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAQAQAXXX")
        fill_in("IBAN", with: "QA87CITI123456789012345678901")
        fill_in("Confirm IBAN", with: "QA87CITI123456789012345678901")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in QAR.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Bahamas Creator")
        fill_in("SWIFT / BIC Code", with: "AAAABSNSXXX")
        fill_in("Account #", with: "0001234")
        fill_in("Confirm account #", with: "0001234")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in BSD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Saint Lucia Creator")
        fill_in("SWIFT / BIC Code", with: "AAAALCLCXYZ")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in XCD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Senegal Creator")
        fill_in("IBAN", with: "SN08SN0100152000048500003035")
        fill_in("Confirm IBAN", with: "SN08SN0100152000048500003035")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in XOF.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Angola Creator")
        fill_in("SWIFT / BIC Code", with: "AAAAAOAOXXX")
        fill_in("IBAN", with: "AO06004400006729503010102")
        fill_in("Confirm IBAN", with: "AO06004400006729503010102")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in AOA.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Niger Creator")
        fill_in("IBAN", with: "NE58NE0380100100130305000268")
        fill_in("Confirm IBAN", with: "NE58NE0380100100130305000268")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in XOF.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "San Marino Creator")
        fill_in("SWIFT / BIC Code", with: "AAAASMSMXXX")
        fill_in("IBAN", with: "SM86U0322509800000000270100")
        fill_in("Confirm IBAN", with: "SM86U0322509800000000270100")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in EUR.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Cambodia Creator")
        fill_in("Account #", with: "000123456789")
        fill_in("Confirm account #", with: "000123456789")
        fill_in("SWIFT / BIC Code", with: "AAAAKHKHXXX")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in KHR.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Mongolia Creator")
        fill_in("Account #", with: "0002222001")
        fill_in("Confirm account #", with: "0002222001")
        fill_in("SWIFT / BIC Code", with: "AAAAMNUBXXX")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MNT.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Algeria Creator")
        fill_in("Account #", with: "00001234567890123456")
        fill_in("Confirm account #", with: "00001234567890123456")
        fill_in("SWIFT / BIC Code", with: "AAAADZDZXXX")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in DZD.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Macao Creator")
        fill_in("Account #", with: "0000000001234567897")
        fill_in("Confirm account #", with: "0000000001234567897")
        fill_in("SWIFT / BIC Code", with: "AAAAMOMXXXX")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in MOP.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Benin Creator")
        fill_in("IBAN", with: "BJ66BJ0610100100144390000769")
        fill_in("Confirm IBAN", with: "BJ66BJ0610100100144390000769")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in XOF.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
        select("January", from: "Month")
        select("1980", from: "Year")

        fill_in("Pay to the order of", with: "Cote d'Ivoire Creator")
        fill_in("IBAN", with: "CI93CI0080111301134291200589")
        fill_in("Confirm IBAN", with: "CI93CI0080111301134291200589")

        expect(page).to have_content("Must exactly match the name on your bank account")
        expect(page).to have_content("Payouts will be made in XOF.")

        click_on("Update settings")

        expect(page).to have_alert(text: "Thanks! You're all set.")
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
  end
end
