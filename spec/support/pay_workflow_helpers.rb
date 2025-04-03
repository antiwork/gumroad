# frozen_string_literal: true

# TODO: Remove this when the new checkout experience is rolled out
module PayWorkflowHelpers
  def login_to_braintree_paypal
    # Avoid flaky specs by ignoring PayPal's asset loading JS errors
    ignore_js_error("https://checkout.paypal.com/favicon.ico - Failed to load resource: the server responded with a status of 404 ()")
    ignore_js_error("https://www.paypalobjects.comimages/checkout/hermes/icon_ot_spin_lock_skinny.png - Failed to load resource: net::ERR_NAME_NOT_RESOLVED")
    ignore_js_error("https://c.sandbox.paypal.com/v1/r/d/b/p1 - Failed to load resource: the server responded with a status of 503 ()")

    # Ensure PayPal button has loaded
    expect(page).to(have_selector(".credit_card_holder [role='progressbar'][aria-label='Loading PayPal button']"))

    paypal_window = window_opened_by do
      click_on "Pay with PayPal"
    end

    within_window paypal_window do
      if page.has_button?("Continue")
        click_on("Continue")
      elsif page.has_button?("Agree & Continue")
        click_on("Agree & Continue")
      else
        find("input#email").fill_in(with: "paypal-gr-integspecs@gumroad.com")

        # Sometimes the login form only has the email prompt and the password field is on the next page
        click_on("Next") if page.has_content?("Enter your email or mobile number to get started.")

        fill_in("Password", with: "gumroadintegspecs")
        click_on("Log In")

        # Depending on the country this button has a different label, ID, class.
        if page.has_button?("Continue")
          click_on("Continue")
        elsif page.has_button?("Agree & Continue")
          click_on("Agree & Continue")
        elsif page.has_button?("Pay Now")
          click_on("Pay Now")
        else
          find("#consentButton").click
        end
      end
    end

    expect(page).to have_selector(".charge-to-container", text: "paypal-gr-integspecs@gumroad.com")
  end

  def login_to_native_paypal
    # Avoid flaky specs by ignoring PayPal's loading JS errors
    ignore_js_error("https://www.paypalobjects.comimages/checkout/hermes/icon_ot_spin_lock_skinny.png - Failed to load resource: net::ERR_NAME_NOT_RESOLVED")
    ignore_js_error("Uncaught TypeError: Cannot set property 'visual' of undefined")
    ignore_js_error("\"- path .: is not an object (got value 'null')\"")
    ignore_js_error(/Cannot use 'in' operator to search for 'is_tax_mismatch' in undefined/)
    ignore_js_error(/does not match recipient window's origin/)
    ignore_js_error(/Parsing error in 'paypal#create_agreement/)
    ignore_js_error(/Failed to execute 'postMessage' on 'DOMWindow'/)

    # Ensure PayPal button has loaded
    expect(page).to(have_selector(".credit_card_holder [role='progressbar'][aria-label='Loading PayPal button']"))

    native_paypal_window = window_opened_by do
      click_on "Pay with PayPal"
    end

    within_window native_paypal_window do
      expect(page).to have_selector("[aria-label='PayPal Logo']")
      if page.has_button?("Continue")
        click_on("Continue")
      elsif page.has_button?("Agree & Pay")
        click_on("Agree & Pay")
      else
        find("input#email").fill_in(with: "paypal-gr-integspecs@gumroad.com")

        # Sometimes the login form only has the email prompt and the password field is on the next page
        click_on("Next") if page.has_content?("Enter your email or mobile number to get started.")

        fill_in("Password", with: "gumroadintegspecs")
        click_on("Log In")

        # Remove cookie banner so we don't need to scroll for the confirmation button
        if page.has_content?("Accept Cookies")
          page.execute_script("document.querySelector(\"#ccpaCookieBanner\").remove()")
        end

        # Depending on the country this button has a different label, ID, class.
        if page.has_button?("Continue")
          click_on("Continue")
        elsif page.has_button?("Agree & Pay")
          click_on("Agree & Pay")
        else
          click_on("Pay Now")
        end
      end
    end

    expect(page).to have_selector(".charge-to-container", text: "paypal-gr-integspecs@gumroad.com")
  end

  def clear_cc_details
    within_fieldset "Card information" do
      within_frame(0) do
        fill_in "Card number", with: ""
        fill_in "MM / YY", with: ""
        fill_in "CVC", with: ""
      end
    end
    fill_in "Name on card", with: ""
  end

  def fill_cc_details(card_number: "4242424242424242", card_expiry: StripePaymentMethodHelper::EXPIRY_MMYY, card_cvc: "123", zip_code: nil)
    within_fieldset "Card information" do
      within_frame(0) do
        fill_in "Card number", with: card_number, visible: false
        fill_in "MM / YY", with: card_expiry, visible: false
        fill_in "CVC", with: card_cvc, visible: false
        fill_in "ZIP", with: zip_code, visible: false if zip_code.present?
      end
    end
    fill_in "Name on card", with: "Edgar Gumroad"
  end
end
