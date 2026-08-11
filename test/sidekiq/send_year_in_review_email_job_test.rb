# frozen_string_literal: true

require "test_helper"

# Ported from spec/sidekiq/send_year_in_review_email_job_spec.rb (#5801).
#
# The job builds a seller's year-in-review email out of Elasticsearch: sales and
# earnings come from aggregations over the purchase index, views from the
# page-view index. Those numbers ARE the subject here, so this is one of the few
# files that opts into a real cluster (see test/support/real_elasticsearch_bridge.rb)
# rather than the harness's stubbed client. The CI job runs Elasticsearch as of #6205.
#
# What stays stubbed, matching the spec: the OpenAI call behind the "things you
# could buy" section, the annual-payout CSV export, and User#rank.
class SendYearInReviewEmailJobTest < ActiveSupport::TestCase
  include RealElasticsearchBridge

  BUY_LIST_RESPONSE = {
    "choices" => [
      {
        "message" => {
          "content" => "1. A nice desk lamp\n2. A hardcover notebook\n3. A cozy throw blanket\n4. A set of headphones\n5. A gourmet coffee kit"
        }
      }
    ]
  }.freeze

  setup do
    # The email layout links a Vite-built stylesheet, and premailer inlines it by
    # loading that file off disk — which means the assets have to have been built.
    # The RSpec lane runs in an image that has them; this suite runs on a bare
    # runner, and building Vite assets to test email copy would be minutes of CI
    # time for nothing. Nothing here asserts on styling, so hand premailer empty CSS.
    Premailer::Rails::CSSHelper.stubs(:css_for_url).returns("")

    install_real_elasticsearch!([Purchase, ProductPageView])
    OpenAI::Client.stubs(:new).returns(stub("OpenAI::Client", chat: BUY_LIST_RESPONSE))
    Exports::Payouts::Annual.any_instance.stubs(:perform).returns(
      csv_file: Rack::Test::UploadedFile.new(Rails.root.join("spec/support/fixtures/followers_import.csv")),
      total_amount: 1_000_00
    )
  end

  teardown { restore_fake_elasticsearch! }

  # --- no payouts for the selected year --------------------------------------

  test "perform sends no email when the seller has no payouts for that year" do
    date = Date.new(2021, 2, 22)
    seller = seller_with_annual_report(year: date.year - 1, created_at: (date - 1.year).to_time)
    travel_to(date) { 12.times { create_payment_with_purchase(seller, date - 1.year) } }

    assert_no_difference -> { ActionMailer::Base.deliveries.count } do
      SendYearInReviewEmailJob.new.perform(seller.id, date.year)
    end
  end

  # --- payouts exist ---------------------------------------------------------

  test "perform sends no email when the seller made only affiliate sales" do
    date = Date.new(2022, 2, 22)
    seller = seller_with_annual_report(year: date.year, created_at: (date - 1.year).to_time)
    create_payment_completed(user: seller, amount_cents: 100_00, payout_period_end_date: date, created_at: date)

    assert_no_difference -> { ActionMailer::Base.deliveries.count } do
      SendYearInReviewEmailJob.new.perform(seller.id, date.year)
    end
  end

  test "perform shows stats for the seller's single product" do
    date = Date.new(2022, 2, 22)
    seller = seller_with_annual_report(year: date.year, created_at: (date - 1.year).to_time)
    User.any_instance.stubs(:rank).returns(2)
    single_product_sale(seller, date)

    assert_difference -> { ActionMailer::Base.deliveries.count }, 1 do
      SendYearInReviewEmailJob.new.perform(seller.id, date.year)
    end

    mail = ActionMailer::Base.deliveries.last
    assert_equal [seller.email], mail.to
    assert_equal "Your 2022 in review", mail.subject
    body = sanitized_body(mail)
    assert_includes body, "Views 2"
    assert_includes body, "Sales 1"
    assert_includes body, "Unique customers 1"
    assert_includes body, "Products sold 1"
    assert_includes body, "You ranked #2 among all creators"
    assert_includes body, "Your top product"
    assert_match(/Product 1 \( \S+ \) -+ Views 2 Sales 1 Total 1K/, body)
    assert_includes body, "You earned a total of $1,000"
    assert_includes body, "You sold products in 1 country"
    assert_not_includes body, "Elsewhere"
    assert_includes body, "United States 2 1 $1K"
    assert_report_link(mail, seller, date)
  end

  test "perform renders the AI-generated buy list" do
    date = Date.new(2022, 2, 22)
    seller = seller_with_annual_report(year: date.year, created_at: (date - 1.year).to_time)
    User.any_instance.stubs(:rank).returns(2)
    single_product_sale(seller, date)

    assert_difference -> { ActionMailer::Base.deliveries.count }, 1 do
      SendYearInReviewEmailJob.new.perform(seller.id, date.year)
    end

    body = sanitized_body(ActionMailer::Base.deliveries.last)
    assert_includes body, "Hey, can you suggest some things I could buy with my Gumroad earnings"
    ["A nice desk lamp", "A hardcover notebook", "A cozy throw blanket", "A set of headphones", "A gourmet coffee kit"].each do |suggestion|
      assert_includes body, suggestion
    end
  end

  test "perform tells a 1099-eligible US seller their form is ready" do
    date = Date.new(2022, 2, 22)
    seller = seller_with_annual_report(year: date.year, created_at: (date - 1.year).to_time)
    permalinks = generate_data_for(seller, date, products_count: 10)
    User.any_instance.stubs(:eligible_for_1099?).returns(true)

    assert_difference -> { ActionMailer::Base.deliveries.count }, 1 do
      SendYearInReviewEmailJob.new.perform(seller.id, date.year)
    end

    mail = ActionMailer::Base.deliveries.last
    assert_equal [seller.email], mail.to
    assert_us_seller_stats(mail, seller, permalinks, date)
    assert_includes sanitized_body(mail), "Your 1099 form is available for download"
  end

  test "perform sends the email to an explicit recipient instead of the seller" do
    date = Date.new(2022, 2, 22)
    seller = seller_with_annual_report(year: date.year, created_at: (date - 1.year).to_time)
    permalinks = generate_data_for(seller, date, products_count: 10)
    User.any_instance.stubs(:eligible_for_1099?).returns(true)

    assert_difference -> { ActionMailer::Base.deliveries.count }, 1 do
      SendYearInReviewEmailJob.new.perform(seller.id, date.year, "gumbot@gumroad.com")
    end

    mail = ActionMailer::Base.deliveries.last
    assert_equal ["gumbot@gumroad.com"], mail.to
    assert_us_seller_stats(mail, seller, permalinks, date)
    assert_includes sanitized_body(mail), "Your 1099 form is available for download"
  end

  test "perform tells a US seller who is not 1099-eligible that they do not qualify" do
    date = Date.new(2022, 2, 22)
    seller = seller_with_annual_report(year: date.year, created_at: (date - 1.year).to_time)
    permalinks = generate_data_for(seller, date, products_count: 10)

    assert_difference -> { ActionMailer::Base.deliveries.count }, 1 do
      SendYearInReviewEmailJob.new.perform(seller.id, date.year)
    end

    mail = ActionMailer::Base.deliveries.last
    assert_equal [seller.email], mail.to
    assert_us_seller_stats(mail, seller, permalinks, date)
    assert_includes sanitized_body(mail), "You do not qualify for a 1099 this year."
  end

  test "perform omits the 1099 section entirely for a seller outside the US" do
    date = Date.new(2022, 2, 22)
    seller = seller_with_annual_report(year: date.year, created_at: (date - 1.year).to_time, country: "Singapore")
    permalinks = generate_data_for(seller, date)
    top_products = seller.products.where(unique_permalink: permalinks.first(5))
    top_product_names = top_products.pluck(:name)

    # Mimic no product views, then add exactly one from Romania.
    recreate_model_index(ProductPageView)
    travel_to(date) do
      create_payment_with_purchase(seller, date, product: top_products.first, amount_cents: 100_00, ip_country: "Romania")
      add_page_view(top_products.first, Time.current.iso8601, country: "Romania")
    end
    refresh_page_views!
    index_model_records(Purchase)

    assert_difference -> { ActionMailer::Base.deliveries.count }, 1 do
      SendYearInReviewEmailJob.new.perform(seller.id, date.year)
    end

    mail = ActionMailer::Base.deliveries.last
    assert_equal [seller.email], mail.to
    assert_equal "Your 2022 in review", mail.subject
    body = sanitized_body(mail)
    assert_includes body, "Views 1"
    assert_includes body, "Sales 13"
    assert_includes body, "Unique customers 13"
    assert_includes body, "Products sold #{permalinks.size}"
    top_product_names.each do |name|
      assert_match(/#{name} \( \S+ \) -+ Views \d+ Sales \d+ Total \d+/, body)
    end
    assert_includes body, "You earned a total of $1,300"
    assert_includes body, "You sold products in 2 countries"
    assert_not_includes body, "United States"
    assert_includes body, "Romania 1 1 $100"
    assert_includes body, "Elsewhere 0 12 $1.2K"
    assert_report_link(mail, seller, date)
    assert_not_includes body, "You do not qualify for a 1099 this year."
    assert_not_includes body, "Your 1099 form is available for download"
  end

  private
    # Like Mail::Body#sanitized (spec/support/mail_body_extensions.rb), but
    # unfolds quoted-printable soft breaks ("=\r\n") first — they land at
    # positions that depend on the random test subdomain length.
    def sanitized_body(mail)
      ActionView::Base.full_sanitizer
        .sanitize(mail.body.encoded.gsub("=\r\n", ""))
        .gsub("\r\n", " ")
        .gsub(/\s{2,}/, " ")
    end

    # The download link for the seller's annual report. Asserted against the
    # decoded text part rather than sanitized_body: the sanitizer strips the
    # anchor's href from the HTML part, so only the text part carries the URL.
    def assert_report_link(mail, seller, date)
      assert_includes mail.text_part.decoded, seller.financial_annual_report_url_for(year: date.year)
    end

    def seller_with_annual_report(year:, created_at:, country: "United States")
      seller = create_user_with_compliance_info(country:, name: "Seller", created_at:)
      attach_annual_report(seller, year:)
    end

    # Indexes one page view for a product (mirrors spec/support/product_page_view_helpers.rb).
    # Writes straight to the index rather than through the app so the timestamp
    # and country can be dictated.
    #
    # Deliberately does NOT wait for the write to become searchable: these are
    # called up to 24 times per test, and `refresh: "wait_for"` on each one made
    # this file take 156s instead of 22s. Call refresh_page_views! once when the
    # data is in place instead — the job only reads them at perform time.
    def add_page_view(product, timestamp = Time.current.iso8601, **extra_body)
      extra_body[:referrer_domain] = extra_body[:referrer_domain].presence || "direct"
      EsClient.index(
        index: ProductPageView.index_name,
        body: { product_id: product.id, seller_id: product.user_id, timestamp: }.merge(extra_body)
      )
    end

    # Makes every page view written so far searchable. The RSpec original got this
    # per-write from its :elasticsearch_wait_for_refresh tag.
    def refresh_page_views!
      ProductPageView.__elasticsearch__.refresh_index!
    end

    # One product, one sale of $1,000 from the US, two views — the "sold only one
    # product" fixture.
    def single_product_sale(seller, date)
      recreate_model_index(ProductPageView)
      travel_to(date) do
        product = create_product(user: seller, name: "Product 1")
        create_payment_with_purchase(seller, date, product:, amount_cents: 1_000_00, ip_country: "United States")
        2.times { add_page_view(product, Time.current.iso8601, country: "United States") }
      end
      refresh_page_views!
      index_model_records(Purchase)
    end

    # 12 sales in the report year and 12 the year before, spread over
    # `products_count` products, with two views per sale in the report year.
    # Returns the permalinks of products that sold in the report year, best first
    # — the order the email lists them in.
    def generate_data_for(seller, date, products_count: 8)
      recreate_model_index(ProductPageView)

      products = Array.new(products_count) { |i| create_product(user: seller, name: "Product #{i + 1}") }
      sales_for_report_year = products.to_h { |product| [product.unique_permalink, 0] }

      travel_to(date - 1.year) do
        12.times do
          payment_data = create_payment_with_purchase(seller, date - 1.year, product: products.sample, amount_cents: 100_00)
          add_page_view(payment_data[:purchase].link)
        end
      end

      travel_to(date) do
        12.times do
          product = products.sample
          payment_data = create_payment_with_purchase(seller, date, product:, amount_cents: 100_00)
          2.times { add_page_view(product) }
          sales_for_report_year[product.unique_permalink] += payment_data[:payment].amount_cents
        end
      end

      refresh_page_views!
      index_model_records(Purchase)

      sales_for_report_year.filter { |_, total| total.nonzero? }
                           .sort_by { |permalink, total| [-total, permalink] }
                           .map(&:first)
    end

    # The stats block every US-seller example asserts: 12 sales at $100 across
    # `permalinks.size` products, 24 views, all attributed to "Elsewhere" because
    # these sales carry no country.
    def assert_us_seller_stats(mail, seller, permalinks, date)
      assert_equal "Your 2022 in review", mail.subject
      body = sanitized_body(mail)
      assert_includes body, "Views 24"
      assert_includes body, "Sales 12"
      assert_includes body, "Unique customers 12"
      assert_includes body, "Products sold #{permalinks.size}"
      seller.products.where(unique_permalink: permalinks.first(5)).pluck(:name).each do |name|
        assert_match(/#{name} \( \S+ \) -+ Views \d+ Sales \d+ Total \d+/, body)
      end
      assert_includes body, "You earned a total of $1,200"
      assert_includes body, "You sold products in 1 country"
      assert_not_includes body, "United States"
      assert_includes body, "Elsewhere 24 12 $1.2K"
      assert_report_link(mail, seller, date)
    end
end
