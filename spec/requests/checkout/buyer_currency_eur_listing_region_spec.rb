# frozen_string_literal: true

require "spec_helper"

# iDEAL/Bancontact force the whole Payment Element into EUR, so whether they are offered decides
# the currency a EUR listing is charged in. These specs follow one buy-now checkout from the price
# in CheckoutController#show's props, through the Element it mounts, to the intent prepare creates.
describe "checkout currency for a EUR listing, by buyer region", type: :request do
  let(:seller) { create(:user, check_merchant_account_is_linked: true, disable_buyer_local_currency: false) }
  let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }
  let!(:product) { create(:product, user: seller, price_currency_type: Currency::EUR, price_cents: 15_00) }
  let(:currency_rates) { Redis::Namespace.new(:currencies, redis: $redis) }
  let(:us_ip) { "104.28.0.1" }
  let(:nl_ip) { "145.52.0.1" }
  let(:unplaceable_ip) { "10.9.9.9" }
  let(:seller_features) do
    [
      Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME,
      Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME,
      :buyer_local_currency,
      Checkout::BuyerCurrencyEligibility::FEATURE_NAME,
      :checkout_local_method_ideal,
      :checkout_local_method_bancontact,
    ]
  end

  def geoip_result(country_name, country_code)
    GeoIp::Result.new(country_name:, country_code:, region_name: nil, city_name: nil, postal_code: nil, latitude: nil, longitude: nil)
  end

  before do
    allow_any_instance_of(ActionDispatch::Request).to receive(:host).and_return(VALID_REQUEST_HOSTS.first)
    allow(Stripe).to receive(:api_key).and_return("sk_live_currency")
    allow(GeoIp).to receive(:lookup).and_call_original
    allow(GeoIp).to receive(:lookup).with(us_ip).and_return(geoip_result("United States", "US"))
    allow(GeoIp).to receive(:lookup).with(nl_ip).and_return(geoip_result("Netherlands", "NL"))
    allow(GeoIp).to receive(:lookup).with(unplaceable_ip).and_return(nil)
    # 1 USD = 0.8 EUR, so the EUR 15.00 listing converts to US$18.75.
    currency_rates.set("EUR", "0.8")
    connect_account.update!(stripe_capabilities_snapshot: {
                              "capabilities" => { "link_payments" => "active", "ideal_payments" => "active", "bancontact_payments" => "active" },
                              "refreshed_at" => Time.current.iso8601,
                            })
    seller_features.each { Feature.activate_user(_1, seller) }
  end

  after do
    seller_features.each { Feature.deactivate_user(_1, seller) }
    currency_rates.del("EUR")
  end

  def checkout_page_props(ip:)
    get "/checkout", params: { product: product.unique_permalink }, headers: { "X-Inertia" => "true", "REMOTE_ADDR" => ip }
    expect(response).to be_successful
    JSON.parse(response.body).fetch("props")
  end

  def displayed_currency(props)
    props.dig("checkout", "add_products").sole.dig("product", "buyer_currency_display")
  end

  # Submits what the browser sends after mounting from checkout_payment. The ConfirmationToken
  # comes from Stripe, so its retrieve is stubbed and the deferred intent create is captured.
  def prepare_intent(ip:, elements_options:)
    params = {
      line_items: [{ uid: "unique-id-0", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 }],
      email: "buyer@example.com",
      cc_zipcode: "94117",
      purchase: { full_name: "Buyer", street_address: "1 Main St", country: "US", state: "CA", city: "San Francisco", zip_code: "94117" },
      browser_guid: SecureRandom.uuid,
      ip_address: ip,
      session_id: SecureRandom.hex,
      is_mobile: false,
      payment_element_mount_currency: elements_options.fetch("currency"),
      payment_method_list_token: elements_options.fetch("payment_method_list_token"),
    }
    order, = Order::CreateService.new(params:).perform
    preview = Stripe::StripeObject.construct_from(type: "card", card: { country: "US" })
    allow(Stripe::ConfirmationToken).to receive(:retrieve)
      .and_return(Stripe::StripeObject.construct_from(payment_method_preview: preview))
    create_args = nil
    allow(StripeDeferredPaymentIntent).to receive(:create) do |**kwargs|
      create_args = kwargs
      instance_double(StripeChargeIntent, id: "pi_region", client_secret: "pi_region_secret")
    end

    responses = Order::PreparePaymentIntentService.new(order:, params:, confirmation_token: "ctoken_region").perform
    expect(responses["unique-id-0"][:success]).to eq(true)
    [order, create_args]
  end

  def expect_listed_euro_checkout(props, ip:)
    elements_options = props.dig("checkout_payment", "elements_options")
    expect(elements_options).to include("currency" => Currency::EUR, "presentment_amount_cents" => 15_00)
    expect(elements_options["listed_currency_display"]).to include("currency" => Currency::EUR)
    expect(elements_options["payment_method_types"]).to include("ideal", "bancontact")

    order, create_args = prepare_intent(ip:, elements_options:)

    expect(create_args).to include(currency: Currency::EUR, amount_cents: 15_00, stripe_fx_quote_id: nil)
    expect(order.charges.sole.charge_presentment).to have_attributes(presentment_currency: Currency::EUR, presentment_total_cents: 15_00)
  end

  it "shows, mounts, and charges a US buyer the converted US dollar price" do
    props = checkout_page_props(ip: us_ip)

    display = displayed_currency(props)
    expect(display).to include("display_mode" => "buyer_local", "buyer_currency_shown" => Currency::USD, "buyer_local_price_cents" => 18_75)
    elements_options = props.dig("checkout_payment", "elements_options")
    expect(elements_options).to include("currency" => Currency::USD, "presentment_amount_cents" => nil, "listed_currency_display" => nil)
    expect(elements_options["payment_method_types"]).not_to include("ideal", "bancontact")

    order, create_args = prepare_intent(ip: us_ip, elements_options:)

    purchase = order.purchases.sole.reload
    expect(purchase.price_cents).to eq(display.fetch("buyer_local_price_cents"))
    expect(create_args).to include(currency: Currency::USD, amount_cents: purchase.total_transaction_cents, stripe_fx_quote_id: nil)
    expect(order.charges.sole.amount_cents).to eq(create_args[:amount_cents])
    expect(order.charges.sole.charge_presentment).to be_nil
    expect(purchase.purchase_presentment).to be_nil
  end

  it "keeps the listed euro checkout for a buyer in the Netherlands" do
    props = checkout_page_props(ip: nl_ip)

    expect(displayed_currency(props)).to include("display_mode" => "default", "buyer_currency_shown" => Currency::EUR)
    expect_listed_euro_checkout(props, ip: nl_ip)
  end

  it "keeps the listed euro checkout for a buyer GeoIP cannot place, who is shown the listing as-is" do
    props = checkout_page_props(ip: unplaceable_ip)

    expect(displayed_currency(props)).to include("display_mode" => "default", "buyer_currency_shown" => Currency::EUR)
    expect_listed_euro_checkout(props, ip: unplaceable_ip)
  end

  # The signed page-load list and the reported mount currency win at prepare
  # (gumroad-private#1528), so the charge follows the Element the buyer paid from.
  it "charges the euro Element a Dutch page load mounted even when the order arrives from a US IP" do
    expect_listed_euro_checkout(checkout_page_props(ip: nl_ip), ip: us_ip)
  end
end
