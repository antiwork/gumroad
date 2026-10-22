# frozen_string_literal: true

require "spec_helper"

# The narrowest desktop width, where a maximum-length title wraps onto the most lines beside the sidebar.
Capybara.register_driver :reviews_layout_lg_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  docker_browser_args.each { |arg| options.args << arg } if ENV["IN_DOCKER"] == "true"
  options.add_emulation(device_metrics: { width: 1024, height: 900, pixelRatio: 1, touch: false })
  options.add_preference("intl.accept_languages", "en-US")
  test_host_resolver_args.each { |arg| options.args << arg }

  # Same WebDriver timeouts as the shared drivers in spec/support/capybara_driver.rb.
  http_client = Selenium::WebDriver::Remote::Http::Default.new(open_timeout: 120, read_timeout: 120)

  Capybara::Selenium::Driver.new(app, browser: :chrome, http_client:, options:)
end

# Headed Chrome under automation leaves fullscreen within a moment for any element, so fullscreen runs headless.
Capybara.register_driver :reviews_layout_lg_headless_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  (ENV["IN_DOCKER"] == "true" ? docker_browser_args : ["--headless=new"]).each { |arg| options.args << arg }
  options.add_emulation(device_metrics: { width: 1024, height: 900, pixelRatio: 1, touch: false })
  options.add_preference("intl.accept_languages", "en-US")
  test_host_resolver_args.each { |arg| options.args << arg }

  http_client = Selenium::WebDriver::Remote::Http::Default.new(open_timeout: 120, read_timeout: 120)

  Capybara::Selenium::Driver.new(app, browser: :chrome, http_client:, options:)
end

# A real window resize (no device emulation) hides the old reviews slot before the resize event, as browsers do.
Capybara.register_driver :reviews_layout_window_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  (ENV["IN_DOCKER"] == "true" ? docker_browser_args : ["--headless=new"]).each { |arg| options.args << arg }
  options.args << "--window-size=1280,900"
  options.add_preference("intl.accept_languages", "en-US")
  test_host_resolver_args.each { |arg| options.args << arg }

  http_client = Selenium::WebDriver::Remote::Http::Default.new(open_timeout: 120, read_timeout: 120)

  Capybara::Selenium::Driver.new(app, browser: :chrome, http_client:, options:)
end

describe "Product page reviews layout", type: :system, js: true do
  # Sub-pixel rounding only: a stretched row or a misplaced area moves a block by a padded section or more.
  let(:tolerance) { 1 }
  # The title must end well below the sidebar, or the example would not reach the tall-title layout.
  let(:min_title_overhang) { 20 }
  # Capitals wrap onto the most lines, so the title clearly outgrows even a minimal sidebar.
  let(:max_length_name) { ("SYNTHETIC SKETCHING WORKSHOP FOR GESTURE, PERSPECTIVE, SHADING AND COMPOSITION " * 4)[0, 255] }

  let(:seller) { create(:named_seller) }
  let(:description) { "A synthetic course description about practising sketches." }
  let(:product) do
    create(:product, user: seller, price_cents: 1_500, description: "<p>#{description}</p>",
                     name: "Synthetic Sketching Course for Practising Gesture, Perspective, Shading and Composition")
  end

  # A $0 price becomes pay-what-you-want and shows a "$0+" tag, so a product without a price row has options instead.
  def remove_the_price_row
    create(:variant, variant_category: create(:variant_category, link: product, title: "Edition"), name: "Standard")
  end

  def expect_no_price_row = expect(article).to(have_no_css(":scope > [class*='grid-area:price']"))

  def create_reviews(count)
    count.times do |index|
      purchase = create(:purchase, link: product, full_name: "Synthetic Reviewer #{index}")
      create(:product_review, purchase:, rating: 5 - (index % 3), message: "Synthetic review #{index}")
    end
  end

  # Other products' reviews give the seller a creator rating for the product page.
  def give_seller_a_creator_rating
    Feature.activate_user(:seller_reputation_summary, seller)
    2.times { create(:product_review_stat, link: create(:product, user: seller), reviews_count: 6, ratings_of_five_count: 6) }
    seller.warm_reputation_snapshot
  end

  def box(element)
    element.evaluate_script("this.getBoundingClientRect().toJSON()").symbolize_keys
  end

  def article = find("article")
  def grid_item(element) = element.find(:xpath, "./ancestor::*[parent::article][1]")
  def title_box = find("h1[itemprop=name]").find(:xpath, "./ancestor::header[1]")
  def controls_box = article.find_link("I want this!").find(:xpath, "./ancestor::section[parent::section[parent::article]][1]")
  def description_box = grid_item(article.find("p", text: description))
  def ratings_box = find("h3", text: "Ratings").find(:xpath, "./ancestor::section[1]")
  def creator_rating_box = find("section[aria-label='Creator rating']")

  def next_paint = page.evaluate_async_script("requestAnimationFrame(() => requestAnimationFrame(arguments[0]))")

  def resize_viewport(width)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 900, deviceScaleFactor: 1, mobile: false)
    next_paint
  end

  # Animation frame callbacks run right before each paint, so this sees every frame the page draws from the start.
  FIRST_PAINT_PROBE = <<~JS
    window.reviewsProbe = { framesWithReviews: 0, paintedInControls: false };
    const check = () => {
      const heading = [...document.querySelectorAll("article h3")].find((h) => h.textContent.trim() === "Ratings");
      if (heading) {
        window.reviewsProbe.framesWithReviews++;
        if (heading.closest('[class*="grid-area:controls"]')) window.reviewsProbe.paintedInControls = true;
      }
      requestAnimationFrame(check);
    };
    requestAnimationFrame(check);
  JS

  def expect_the_desktop_sidebar(top_of_controls:, first_review_box:)
    title = box(title_box)
    controls = box(controls_box)
    reviews = box(first_review_box)
    details = box(description_box)
    title_padding = title_box.evaluate_script("parseFloat(getComputedStyle(this).paddingBottom)")

    expect(controls[:top]).to be_within(tolerance).of(top_of_controls)
    expect(reviews[:top]).to be_within(tolerance).of(controls[:bottom])
    expect(reviews[:left]).to be_within(tolerance).of(controls[:left])
    expect(reviews[:width]).to be_within(tolerance).of(controls[:width])
    expect(details[:top]).to be_within(tolerance).of(title[:bottom])
    expect(details[:right]).to be_within(tolerance).of(controls[:left])
    expect(title[:bottom] - box(find("h1[itemprop=name]"))[:bottom]).to be_within(tolerance).of(title_padding)
  end

  context "on desktop" do
    it "keeps many reviews right under the controls and the description right under the title" do
      create_reviews(12)
      give_seller_a_creator_rating

      visit short_link_path(product)

      expect(page).to have_selector("[aria-label='Ratings histogram']")
      expect_the_desktop_sidebar(top_of_controls: box(grid_item(find("[itemprop=offers]")))[:bottom], first_review_box: ratings_box)
      expect(box(creator_rating_box)[:top]).to be_within(tolerance).of(box(ratings_box)[:bottom])
    end

    it "keeps the reviews under the controls when a long description makes the left column taller" do
      create_reviews(2)
      product.update!(description: "<p>#{description}</p>" + "<p>Another synthetic paragraph about drawing practice.</p>" * 60)

      visit short_link_path(product)

      expect(page).to have_selector("[aria-label='Ratings histogram']")
      expect(box(description_box)[:height]).to be > box(controls_box)[:height] + box(ratings_box)[:height]
      expect_the_desktop_sidebar(top_of_controls: box(grid_item(find("[itemprop=offers]")))[:bottom], first_review_box: ratings_box)
    end

    it "keeps the reviews under the controls under a sale banner" do
      create_reviews(4)
      seller.offer_codes.create!(code: "sketch30", amount_percentage: 30, universal: true, auto_apply: true, sale_label: "Spring sale")

      visit short_link_path(product)

      expect(page).to have_selector("[data-testid='sale-banner']", text: "Spring sale")
      expect_the_desktop_sidebar(top_of_controls: box(grid_item(find("[data-testid='sale-banner']")))[:bottom], first_review_box: ratings_box)
    end

    it "starts the controls beside the title when there is no price" do
      remove_the_price_row
      create_reviews(4)

      visit short_link_path(product)

      expect(page).to have_selector("[aria-label='Ratings histogram']")
      expect_no_price_row
      expect_the_desktop_sidebar(top_of_controls: box(title_box)[:top], first_review_box: ratings_box)
    end

    it "puts the creator rating right under the controls when the product has no reviews" do
      give_seller_a_creator_rating

      visit short_link_path(product)

      expect(creator_rating_box).to have_text("This product has no reviews yet.")
      expect(page).to have_no_selector("[aria-label='Ratings histogram']")
      expect_the_desktop_sidebar(top_of_controls: box(grid_item(find("[itemprop=offers]")))[:bottom], first_review_box: creator_rating_box)
    end
  end

  context "on a 1024px desktop with a maximum-length title" do
    before { driven_by :reviews_layout_lg_chrome }

    it "keeps the reviews right under a short sidebar when the title is taller than it" do
      product.update!(name: max_length_name)
      remove_the_price_row
      create_reviews(3)

      visit short_link_path(product)

      expect(page).to have_selector("[aria-label='Ratings histogram']")
      expect_no_price_row
      expect(box(title_box)[:bottom]).to be > box(controls_box)[:bottom] + min_title_overhang
      expect_the_desktop_sidebar(top_of_controls: box(title_box)[:top], first_review_box: ratings_box)
    end

    it "keeps the reviews right under the controls below a price" do
      product.update!(name: max_length_name)
      create_reviews(3)

      visit short_link_path(product)

      expect(page).to have_selector("[aria-label='Ratings histogram']")
      expect_the_desktop_sidebar(top_of_controls: box(grid_item(find("[itemprop=offers]")))[:bottom], first_review_box: ratings_box)
    end
  end

  context "when the window crosses 1024px" do
    before { driven_by :reviews_layout_lg_chrome }

    it "moves the loaded reviews and the keyboard focus on Load more between the sidebar and the end of the page" do
      create_reviews(25)

      visit short_link_path(product)
      expect(page).to have_text(/Synthetic review \d/, count: 10)
      ratings_box.execute_script("this.dataset.probe = 'same-node'")
      find_button("Load more").execute_script("this.focus()")
      page.send_keys(:enter)
      expect(page).to have_text(/Synthetic review \d/, count: 20)
      find_button("Load more").execute_script("this.focus()")

      resize_viewport(1023)
      expect(box(ratings_box)[:top]).to be >= box(description_box)[:bottom] - tolerance
      expect(ratings_box["data-probe"]).to eq("same-node")
      expect(page.evaluate_script("document.activeElement.textContent.trim()")).to eq("Load more")
      page.send_keys(:enter)
      expect(page).to have_text(/Synthetic review \d/, count: 25)

      resize_viewport(1024)
      expect(box(ratings_box)[:top]).to be_within(tolerance).of(box(controls_box)[:bottom])
      expect(ratings_box["data-probe"]).to eq("same-node")
      expect(page).to have_text(/Synthetic review \d/, count: 25)
    ensure
      resize_viewport(1024)
    end

    # A review video's fullscreen control has the same effect: fullscreen grows the viewport past lg.
    it "keeps a fullscreen element inside the reviews in fullscreen, and drawn, while the window crosses lg" do
      driven_by :reviews_layout_lg_headless_chrome
      create_reviews(3)

      visit short_link_path(product)
      expect(page).to have_selector("[aria-label='Ratings histogram']")
      resize_viewport(1023)
      ratings_box.execute_script("this.dataset.probe = 'same-node'")
      page.execute_script(<<~JS)
        const button = document.createElement("button");
        button.id = "fullscreen-probe";
        button.textContent = "Fullscreen ratings";
        button.onclick = () => document.querySelector("[data-probe='same-node']").requestFullscreen();
        document.body.prepend(button);
      JS
      find_button("Fullscreen ratings").click
      wait_for_valid("document.fullscreenElement?.dataset.probe === 'same-node'")

      resize_viewport(1024)
      expect(page.evaluate_script("document.fullscreenElement?.dataset.probe")).to eq("same-node")
      expect(page.evaluate_script("document.fullscreenElement.getClientRects().length")).to be > 0

      page.execute_script("document.exitFullscreen()")
      wait_for_valid("document.fullscreenElement === null")
      next_paint
      expect(box(ratings_box)[:top]).to be_within(tolerance).of(box(controls_box)[:bottom])
      expect(ratings_box["data-probe"]).to eq("same-node")
    ensure
      page.execute_script("document.fullscreenElement && document.exitFullscreen()")
      resize_viewport(1024)
    end
  end

  context "when the browser window is resized across lg" do
    before { driven_by :reviews_layout_window_chrome }

    it "keeps keyboard focus on Load more both ways" do
      create_reviews(25)

      visit short_link_path(product)
      expect(page).to have_text(/Synthetic review \d/, count: 10)
      find_button("Load more").execute_script("this.focus()")

      page.current_window.resize_to(810, 1080)
      next_paint
      expect(box(ratings_box)[:top]).to be >= box(description_box)[:bottom] - tolerance
      expect(page.evaluate_script("document.activeElement.textContent.trim()")).to eq("Load more")

      page.current_window.resize_to(1280, 900)
      next_paint
      expect(box(ratings_box)[:top]).to be_within(tolerance).of(box(controls_box)[:bottom])
      expect(page.evaluate_script("document.activeElement.textContent.trim()")).to eq("Load more")
      page.send_keys(:enter)
      expect(page).to have_text(/Synthetic review \d/, count: 20)
    end
  end

  context "below the lg breakpoint", :tablet_view do
    # The tablet driver sends a desktop user agent, like iPadOS Safari, while drawing the stacked layout.
    it "never paints the reviews inside the buy controls, even on the first frame" do
      create_reviews(3)
      probe = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: FIRST_PAINT_PROBE)

      visit short_link_path(product)
      expect(page).to have_selector("[aria-label='Ratings histogram']")
      next_paint

      result = page.evaluate_script("window.reviewsProbe")
      expect(result["framesWithReviews"]).to be > 0
      expect(result["paintedInControls"]).to be(false)
    ensure
      page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: probe["identifier"]) if probe
    end

    it "shows a new buyer the buy controls, then the description, then the reviews" do
      create_reviews(12)
      give_seller_a_creator_rating

      visit short_link_path(product)

      expect(page).to have_selector("[aria-label='Ratings histogram']")
      expect(box(controls_box)[:bottom]).to be <= box(description_box)[:top] + tolerance
      expect(box(description_box)[:bottom]).to be <= box(ratings_box)[:top] + tolerance
      expect(box(ratings_box)[:bottom]).to be <= box(creator_rating_box)[:top] + tolerance
    end

    it "shows the creator rating after the description when the product has no reviews" do
      give_seller_a_creator_rating

      visit short_link_path(product)

      expect(creator_rating_box).to have_text("This product has no reviews yet.")
      expect(box(controls_box)[:bottom]).to be <= box(description_box)[:top] + tolerance
      expect(box(description_box)[:bottom]).to be <= box(creator_rating_box)[:top] + tolerance
    end

    it "keeps a returning buyer's description and access card above Purchase again and the reviews" do
      create_reviews(3)
      buyer = create(:user)
      create(:purchase, link: product, purchaser: buyer, email: buyer.email)
      login_as buyer

      visit short_link_path(product)

      purchase_again = box(article.find_link("Purchase again"))
      access_card = article.find(:xpath, %q{.//*[normalize-space(text())="You've purchased this product"]})
      expect(box(access_card)[:bottom]).to be <= purchase_again[:top]
      expect(box(description_box)[:bottom]).to be <= purchase_again[:top]
      expect(purchase_again[:bottom]).to be <= box(ratings_box)[:top]
    end
  end
end
