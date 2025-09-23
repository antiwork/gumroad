# frozen_string_literal: true

module CheckoutHelpers
  def add_to_cart(product, cart: false, pwyw_price: nil, option: nil, rent: false, recurrence: nil, logged_in_user: nil, quantity: 1, offer_code: nil, ppp_factor: nil, **params)
    choose "Rent" if rent && product.purchase_type != "rent_only"
    choose option == "Untitled" ? product.name : option if option.present?
    select recurrence, from: "Recurrence" if recurrence.present?

    quantity_field = first(:field, "Quantity", minimum: 0)
    quantity_field&.set quantity if quantity.present?

    fill_in "Name a fair price", with: pwyw_price if pwyw_price.present?

    if product.purchase_info_for_product_page(logged_in_user, Capybara.current_session.driver.browser.manage.all_cookies.find { |cookie| cookie[:name] == "_gumroad_guid" }&.[](:value)).present?
      buy_text = "Purchase again"
    elsif cart
      buy_text = "Add to cart"
    elsif product.is_recurring_billing
      buy_text = "Subscribe"
    elsif product.purchase_type == "rent_only" || rent
      buy_text = "Rent"
    else
      buy_text = "I want this!"
    end

    within find(:article) do
      buy_button = find(:link, buy_text)
      uri = URI.parse buy_button[:href]
      expect(uri.path).to eq "/checkout"
      query = Rack::Utils.parse_query(uri.query)
      expect(query["product"]).to eq(product.unique_permalink)
      expect(query["quantity"]).to eq(quantity.to_s)
      expect(query["code"]).to eq(offer_code&.code)
      expect(query["rent"]).to eq(rent ? "true" : nil)
      expect(query["option"]).to eq(option.present? ? (product.is_physical ? product.skus.alive.find_by(name: option)&.external_id : product.variant_categories.alive.first&.variants&.alive&.find_by(name: option)&.external_id) : nil)
      if pwyw_price.present?
        pwyw_price = (pwyw_price * 100)
        if offer_code.present?
          pwyw_price += offer_code.amount_cents if offer_code.amount_cents.present?
          pwyw_price /= ((100 - offer_code.amount_percentage) / 100.0) if offer_code.amount_percentage.present?
        end
        pwyw_price /= ppp_factor if ppp_factor.present?
      end
      expect(query["price"]).to eq(pwyw_price && pwyw_price.to_i.to_s)
      params.each { |key, value| expect(query[key.to_s]).to eq(value.to_s) }
      buy_button.click
    end

    within_cart_item(product.name) do
      expect(page).to have_text((pwyw_price.to_i * quantity / 100).to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse) if pwyw_price.present?
      expect(page).to have_text("Qty: #{quantity}")
      expect(page).to have_text("#{variant_label(product)}: #{option == "Untitled" ? product.name : option}") if option.present?
      expect(page).to have_text("Membership: #{recurrence}") if recurrence.present?
      expect(page).to have_text("one #{product.free_trial_details[:duration][:unit]} free") if product.free_trial_enabled
    end
    expect(page).to have_selector("[aria-label='Discount code']", text: offer_code.code) if offer_code.present? && ((offer_code.amount_cents || 0) > 0 || (offer_code.amount_percentage || 0) > 0)
  end

  def fill_checkout_form(product, email: "test@gumroad.com", address: nil, offer_code: nil, is_free: false, country: nil, zip_code: "94107", vat_id: nil, abn_id: nil, gst_id: nil, qst_id: nil, mva_id: nil, cn_id: nil, ird_id: nil, sst_id: nil, vsk_id: nil, trn_id: nil, oman_vat_number: nil, unp_id: nil, rut_id: nil, nit_id: nil, cpj_id: nil, ruc_id: nil, tn_id: nil, tin_id: nil, rfc_id: nil, inn_id: nil, pib_id: nil, brn_id: nil, vkn_id: nil, edrpou_id: nil, mst_id: nil, kra_pin_id: nil, firs_tin_id: nil, tra_tin: nil, gift: nil, custom_fields: [], credit_card: {}, logged_in_user: nil)
    fill_in "Email address", with: email if email.present? && logged_in_user.nil?

    if gift&.dig(:email).present?
      check "Give as a gift"
      expect(page).to have_text("Note: Free trials will be charged immediately. The membership will not auto-renew.") if product.is_recurring_billing
      fill_in "Recipient email address", with: gift[:email]
      fill_in "A personalized message (optional)", with: gift[:note]
    end

    fill_in "Business VAT ID (optional)", with: vat_id if vat_id.present?
    fill_in "Business ABN ID (optional)", with: abn_id if abn_id.present?
    fill_in "Business MVA ID (optional)", with: mva_id if mva_id.present?
    fill_in "Business GST ID (optional)", with: gst_id if gst_id.present?
    fill_in "Business QST ID (optional)", with: qst_id if qst_id.present?
    fill_in "Business CN ID (optional)", with: cn_id if cn_id.present?
    fill_in "Business IRD ID (optional)", with: ird_id if ird_id.present?
    fill_in "Business SST ID (optional)", with: sst_id if sst_id.present?
    fill_in "Business VSK ID (optional)", with: vsk_id if vsk_id.present?
    fill_in "Business TRN ID (optional)", with: trn_id if trn_id.present?
    fill_in "Business UNP ID (optional)", with: unp_id if unp_id.present?
    fill_in "Business RUT ID (optional)", with: rut_id if rut_id.present?
    fill_in "Business NIT ID (optional)", with: nit_id if nit_id.present?
    fill_in "Business CPJ ID (optional)", with: cpj_id if cpj_id.present?
    fill_in "Business RUC ID (optional)", with: ruc_id if ruc_id.present?
    fill_in "Business TN ID (optional)", with: tn_id if tn_id.present?
    fill_in "Business TIN ID (optional)", with: tin_id if tin_id.present?
    fill_in "Business RFC ID (optional)", with: rfc_id if rfc_id.present?
    fill_in "Business INN ID (optional)", with: inn_id if inn_id.present?
    fill_in "Business PIB ID (optional)", with: pib_id if pib_id.present?
    fill_in "Business BRN ID (optional)", with: brn_id if brn_id.present?
    fill_in "Business VKN ID (optional)", with: vkn_id if vkn_id.present?
    fill_in "Business EDRPOU ID (optional)", with: edrpou_id if edrpou_id.present?
    fill_in "Business MST ID (optional)", with: mst_id if mst_id.present?
    fill_in "Business KRA PIN (optional)", with: kra_pin_id if kra_pin_id.present?
    fill_in "Business FIRS TIN (optional)", with: firs_tin_id if firs_tin_id.present?
    fill_in "Business TRA TIN (optional)", with: tra_tin if tra_tin.present?
    fill_in "Business VAT Number (optional)", with: oman_vat_number if oman_vat_number.present?

    select country, from: "Country" if country.present?

    if address.present? || product.is_physical || product.require_shipping?
      address = {} if address.nil?
      fill_in "Full name", with: "Gumhead Moneybags"
      fill_in "Street address", with: address[:street] || "1640 17th St"
      fill_in "City", with: address[:city] || "San Francisco"

      country_value = find_field("Country").value

      if country_value == "US"
        select address[:state] || "CA", from: "State"
      elsif country_value == "CA"
        select address[:state] || "QC", from: "Province"
      else
        fill_in "County", with: address[:state]
      end

      fill_in country_value == "US" ? "ZIP code" : "Postal", with: address[:zip_code] || "94107"
    else
      fill_in "ZIP code", with: zip_code if zip_code.present? && !is_free
    end

    if offer_code.present?
      fill_in "Discount code", with: offer_code
      click_on "Apply"
      expect(page).to have_selector("[aria-label='Discount code']", text: offer_code)
    end

    custom_fields.each do |field|
      case field[:type]
      when "terms"
        check "I accept"
      when "checkbox"
        check field[:name]
      when "text"
        fill_in field[:name], with: "Not nothing"
      end
    end

    if logged_in_user&.id == product.user.id
      expect(page).to have_alert("This will be a test purchase as you are the creator of at least one of the products. Your payment method will not be charged.")
    elsif logged_in_user&.credit_card.present? && logged_in_user.credit_card.charge_processor_id != PaypalChargeProcessor.charge_processor_id
      expect(page).to have_command("Use a different card?")
      expect(page).to have_selector("[aria-label='Saved credit card']", text: logged_in_user.credit_card.visual)
    elsif !credit_card.nil? && !is_free
      fill_in_credit_card(**credit_card)
    end
  end

  def check_out(product, error: nil, email: "test@gumroad.com", is_free: false, gift: nil, sca: nil, should_verify_address: false, cart_item_count: 1, logged_in_user: nil, **params, &block)
    fill_checkout_form(product, email:, is_free:, logged_in_user:, gift:, **params)

    block.call if block_given?

    expect do
      click_on is_free ? "Get" : "Pay", exact: true

      if should_verify_address
        if page.has_text?("We are unable to verify your shipping address. Is your address correct?", wait: 5)
          click_on "Yes, it is"
        elsif page.has_text?("You entered this address:", wait: 5) && page.has_text?("We recommend using this format:", wait: 5)
          click_on "No, continue"
        end
      end

      within_sca_frame { click_on sca ? "Complete" : "Fail" } unless sca.nil?

      if error.present?
        expect(page).to have_alert(text: error) if error != true
      else
        if gift.present? || product.is_in_preorder_state
          # Specific cases where we show the receipt instead of the product content
          expect(page).to have_text("Your purchase was successful!")
          expect(page).to have_text(logged_in_user&.email&.downcase || email&.downcase)
        else
          # The alert show/hide timing can cause specs to be flaky
          expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to #{logged_in_user&.email&.downcase || email&.downcase}", visible: :all)
        end

        expect(page).to have_text("You bought this for #{gift[:email] || gift[:name]}") if gift&.dig(:email).present? || gift&.dig(:name).present?

        expect(page).to have_text(product.name)

        if logged_in_user.present? || User.alive.where(email:).exists?
          expect(page).to_not have_text("Create an account to access all of your purchases in one place")
        else
          expect(page).to have_text("Create an account to access all of your purchases in one place")
        end
      end
    end.to change { product.preorder_link.present? ? product.sales.preorder_authorization_successful.count : product.sales.successful.count }.by(error.blank? && logged_in_user&.id != product.user.id && (product.not_free_trial_enabled || gift.present?) ? cart_item_count : 0)
      .and change { product.preorder_link.present? ? product.sales.preorder_authorization_failed.count : product.sales.failed.count }.by(error.present? && error != true ? 1 : 0)
      .and change { product&.subscriptions&.count }.by(error.blank? && product.is_recurring_billing ? 1 : 0)
  end
end

def fill_in_credit_card(number: "4242424242424242", expiry: StripePaymentMethodHelper::EXPIRY_MMYY, cvc: "123", zip_code: nil)
  within_fieldset "Card information" do
    within_frame do
      fill_in "Card number", with: number, visible: false if number.present?
      fill_in "MM / YY", with: expiry, visible: false if expiry.present?
      fill_in "CVC", with: cvc, visible: false if cvc.present?
      fill_in "ZIP", with: zip_code, visible: false if zip_code.present?
    end
  end
  fill_in "Name on card", with: "Gumhead Moneybags"
end

def within_sca_frame(&block)
  expect(page).to have_selector("iframe[src^='https://js.stripe.com/v3/three-ds-2-challenge']", wait: 240)

  within_frame(page.find("[src^='https://js.stripe.com/v3/three-ds-2-challenge']")) do
    within_frame("challengeFrame", &block)
  end
end

def within_cart_item(name, &block)
  within find("h4", text: name, match: :first).ancestor("[role=listitem]"), &block
end

def complete_purchase(product, **params)
  add_to_cart(product, **params)
  check_out(product)
end

def have_cart_item(name)
  have_selector("[role=listitem] h4", text: name)
end

private
  VARIANT_LABELS = {
    Link::NATIVE_TYPE_CALL => "Duration",
    Link::NATIVE_TYPE_COFFEE => "Amount",
    Link::NATIVE_TYPE_MEMBERSHIP => "Tier",
    Link::NATIVE_TYPE_PHYSICAL => "Variant",
  }.freeze

  def variant_label(product)
    VARIANT_LABELS[product.native_type] || "Version"
  end
