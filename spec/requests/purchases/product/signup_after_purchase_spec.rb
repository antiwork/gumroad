# frozen_string_literal: true

require "spec_helper"

describe "Sign up after purchase", type: :system, js: true do
  before do
    product = create(:product)
    product2 = create(:product)
    visit product.long_url
    add_to_cart(product)
    visit product2.long_url
    add_to_cart(product2)
    product2.update(price_cents: 600)
    check_out(product2, error: "The price just changed! Refresh the page for the updated price.")
  end

  context "when password is valid" do
    it "creates the account and saves payment method" do
      expect do
        fill_in("Enter password", with: SecureRandom.hex(24))
        click_on("Sign up")
        wait_for_ajax

        expect(page).to have_content("Your account has been created. You'll get a confirmation email shortly.")
        expect(page).not_to have_field("Enter password", visible: false)
        expect(page).not_to have_selector("button", text: "Sign up")
      end.to change { User.count }.by(1)

      user = User.last
      expect(user.credit_card).to be_present
      expect(user.credit_card.visual).to eq "**** **** **** 4242"
    end
  end

  context "when password is invalid" do
    it "shows an error message for compromised passwords" do
      expect do
        fill_in("Enter password", with: "password")

        vcr_turned_on do
          only_matching_vcr_request_from(["pwnedpasswords"]) do
            VCR.use_cassette("Signup after purchase-with a compromised password") do
              with_real_pwned_password_check do
                click_on("Sign up")
                sleep 5 # frontend code will tokenize the card, then actually register. without the `sleep`, `wait_for_ajax` would terminate too soon and break compromised password check
                wait_for_ajax
              end
            end
          end
        end

        expect(page).to have_content("Password has previously appeared in a data breach as per haveibeenpwned.com and should never be used. Please choose something harder to guess.")
        expect(page).to have_selector("button", text: "Sign up")
      end.not_to change { User.count }
    end

    it "shows an error message for passwords too short" do
      expect do
        fill_in("Enter password", with: "1")
        click_on("Sign up")
        wait_for_ajax

        expect(page).to have_content("Password is too short (minimum is 4 characters)")
        expect(page).to have_selector("button", text: "Sign up")
      end.not_to change { User.count }
    end

    it "allows to fix a validation error and submit again" do
      expect do
        fill_in("Enter password", with: "1")
        click_on("Sign up")
        wait_for_ajax

        expect(page).to have_content("Password is too short (minimum is 4 characters)")
        expect(page).to have_selector("button", text: "Sign up")
      end.not_to change { User.count }

      expect do
        fill_in("Enter password", with: SecureRandom.hex(24))
        click_on("Sign up")
        wait_for_ajax

        expect(page).to have_content("Your account has been created. You'll get a confirmation email shortly.")
        expect(page).not_to have_field("Enter password", visible: false)
        expect(page).not_to have_selector("button", text: "Sign up")
      end.to change { User.count }.by(1)
    end
  end
end
