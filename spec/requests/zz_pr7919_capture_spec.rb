# frozen_string_literal: true

# THROWAWAY capture spec — never commit. Drives the real product editor on the branch and shoots
# the read-only confirmation dialog (gumroad-private#2918).
require "spec_helper"
require "shared_examples/authorize_called"

SHOT_DIR = "/tmp/gp2918".freeze

describe("gp2918 read-only confirmation capture", type: :system, js: true) do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product_with_pdf_file, user: seller, size: 1024) }
    let(:tag) { ENV.fetch("SHOT_TAG", "after") }

    before :each do
      # The editor only renders a file row when the file is embedded in the rich content.
      create(:rich_content, entity: product,
                            description: [{ "type" => "fileEmbed",
                                            "attrs" => { "id" => product.product_files.first.external_id, "uid" => SecureRandom.uuid } }])
      product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE,
                                                                one_item_rate_cents: 0,
                                                                multiple_items_rate_cents: 0)
    end

  include_context "with switching account to user as admin for seller"

  def shoot(name)
    FileUtils.mkdir_p(SHOT_DIR)
    path = File.join(SHOT_DIR, "#{tag}-#{name}.png")
    page.save_screenshot(path)
    puts "SHOT #{path} innerWidth=#{page.evaluate_script('window.innerWidth')}"
  end

  def open_file_row
    visit edit_link_path(product.unique_permalink) + "/content"
    expect(page).to have_css("#app", wait: 20)
    sleep 3
    puts "DEBUG_HAS_NAME=#{page.html.include?("Display Name")}"
    puts "DEBUG_HAS_EMBED=#{page.has_css?(".embed", wait: 5)}"
    puts "DEBUG_TEXT=#{page.text.to_s[0, 1200].inspect}"
    shot_dir = File.join(SHOT_DIR)
    FileUtils.mkdir_p(shot_dir)
    page.save_screenshot(File.join(shot_dir, "#{tag}-00-debug-page.png"))
    embed = find_embed(name: "Display Name")
    page.execute_script("arguments[0].scrollIntoView({block: 'center'})", embed.native)
    sleep 0.5
    within embed do
      click_on "Edit"
    end
  end

  it "asks before turning downloads off for a file that has buyers" do
    3.times { create(:purchase, link: product, seller:, purchase_state: "successful") }
    puts "DEBUG_SERVICE=#{ProductFileBuyerCountsService.new(product: product.reload).counts_by_external_id.inspect}"

    open_file_row
    expect(page).to have_text("Disable file downloads", wait: 15)
    props = page.evaluate_script("document.getElementById('app').dataset.page")
    puts "DEBUG_PROPS_HAS_KEY=#{props.to_s.include?("existing_buyers_count")}"
    puts "DEBUG_PROPS_SLICE=#{props.to_s[/existing_buyers_count.{0,60}/].inspect}"
    idx = props.to_s.index("existing_buyers_count").to_i
    puts "DEBUG_CTX=#{props.to_s[[idx - 260, 0].max, 340].inspect}"
    puts "DEBUG_REACT_ROOT=#{page.evaluate_script("Object.keys(document.getElementById('app')).filter(function(k){return k.indexOf('__react')===0}).join(',')")}"
    puts "DEBUG_SCRIPTS=#{page.evaluate_script("Array.prototype.slice.call(document.querySelectorAll('script[src]')).map(function(e){return e.src}).join(' ')").inspect}"
    shoot("01-row-before-toggle")

    # A coordinate click via WebDriver lands on the styled label and toggles the input without
    # React's handler seeing it; click the input itself from JS instead.
    page.execute_script(<<~JS)
      (function () {
        var label = Array.prototype.slice.call(document.querySelectorAll(".embed label"))
          .find(function (el) { return el.textContent.indexOf("Disable file downloads") !== -1; });
        window.__gp2918_found_label = Boolean(label);
        var input = label && label.querySelector("input[role=switch]");
        if (input) { input.click(); }
      })();
    JS
    sleep 1
    puts "DEBUG_LABEL_FOUND=#{page.evaluate_script("String(window.__gp2918_found_label)")}"

    sleep 2
    begin
      logs = page.evaluate_script("JSON.stringify(window.__gp2918 ?? null)")
      puts "DEBUG_HANDLER=#{logs}"
    rescue StandardError => e
      puts "DEBUG_LOGS_ERR=#{e.class}"
    end
    puts "DEBUG_DIALOG=#{page.has_text?("existing buyers will lose download access", wait: 5)}"
    puts "DEBUG_DIALOG_DOM=#{page.evaluate_script("document.querySelectorAll('[role=dialog]').length")}"
    puts "DEBUG_BODY_TAIL=#{page.evaluate_script("document.body.innerText.slice(-200)").inspect}"
    puts "DEBUG_SWITCH_CHECKED=#{page.has_checked_field?("Disable file downloads (buyers read it in the browser instead)")}"
    expect(page).to have_text("3 existing buyers will lose download access to this file", wait: 15)
    shoot("02-confirmation-dialog")

    click_on "No, cancel"
    expect(page).to_not have_text("3 existing buyers will lose download access to this file", wait: 15)
    shoot("03-cancelled-still-downloadable")
  end

  it "turns downloads off without asking for a file that has no buyers" do
    open_file_row
    expect(page).to have_text("Disable file downloads", wait: 15)

    within find_embed(name: "Display Name") do
      check("Disable file downloads (buyers read it in the browser instead)")
    end

    sleep 1
    expect(page).to_not have_text("existing buyers will lose download access", wait: 5)
    shoot("04-no-buyers-no-dialog")
  end
end