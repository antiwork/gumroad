# frozen_string_literal: true

# THROWAWAY QA capture for antiwork/gumroad#7919. Never commit.
require "spec_helper"
require "shared_examples/authorize_called"

SHOT_DIR = "/tmp/g7919".freeze

describe("PR 7919 QA capture", type: :system, js: true,
         mobile_view: ENV.fetch("SHOT_TAG", "").start_with?("mobile")) do
  include ProductEditPageHelpers
  include ProductFileListHelpers

  let(:tag) { ENV.fetch("SHOT_TAG", "desktop") }
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product_with_pdf_file, user: seller, size: 1024) }
  let(:file) { product.product_files.alive.first }

  include_context "with switching account to user as admin for seller"

  # This box's chromedriver rejects the repo's named "iPhone 8" device, so register an explicit
  # 375px mobile driver for the mobile pass only (same host-resolver arg the repo's driver uses).
  Capybara.register_driver :pr7919_mobile_chrome do |app|
    options = Selenium::WebDriver::Chrome::Options.new
    options.add_emulation(device_metrics: { width: 375, height: 812, pixelRatio: 1, touch: true, mobile: true })
    options.add_preference("intl.accept_languages", "en-US")
    options.logging_prefs = { driver: "DEBUG" }
    options.args << "--host-resolver-rules=MAP *.test.gumroad.com 127.0.0.1,MAP test.gumroad.com 127.0.0.1" unless BUILDING_ON_CI
    Capybara::Selenium::Driver.new(
      app, browser: :chrome,
           http_client: Selenium::WebDriver::Remote::Http::Default.new(open_timeout: 120, read_timeout: 120),
           options:
    )
  end

  # A stale `vite dev --mode test` from another worktree owns :3037 on this shared box, so the
  # app's dev-server proxy would serve THAT checkout's source. Consume the static manifest instead.
  before do
    driven_by :pr7919_mobile_chrome if ENV.fetch("SHOT_TAG", "").start_with?("mobile")
    allow(ViteRuby.instance).to receive(:run_proxy?).and_return(false)
  end

  def shoot(name)
    FileUtils.mkdir_p(SHOT_DIR)
    path = File.join(SHOT_DIR, "#{tag}-#{name}.png")
    page.save_screenshot(path)
    puts "SHOT #{path} innerWidth=#{page.evaluate_script("window.innerWidth")}"
  end

  def open_content_tab
    create(:rich_content, entity: product,
                          description: [{ "type" => "fileEmbed",
                                          "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }])
    visit edit_link_path(product.unique_permalink) + "/content"
    embed = find_embed(name: file.display_name)
    embed.find("button[aria-label='Edit']").click
    expect(embed).to have_selector("[role='switch']", wait: 15)
    embed
  end

  def download_switch(embed)
    embed.find(:xpath, ".//label[contains(., 'Disable file downloads')]//input[@role='switch']")
  end

  it "captures the dialog naming the buyer count, and cancel leaving downloads on" do
    3.times { create(:purchase, link: product, seller: seller) }
    embed = open_content_tab
    download_switch(embed).click
    expect(page).to have_selector("[role='dialog']", text: "3 existing buyers will lose", wait: 15)
    shoot("01-dialog-with-buyers")
    within_modal "Disable downloads for existing buyers?" do
      click_on "No, cancel"
    end
    expect(page).not_to have_selector("[role='dialog']")
    expect(download_switch(embed)).not_to be_checked
    shoot("02-cancelled-downloads-still-on")
  end

  it "captures no dialog when no buyer can reach the file" do
    embed = open_content_tab
    download_switch(embed).click
    sleep 1
    expect(page).not_to have_selector("[role='dialog']")
    shoot("03-no-dialog-zero-buyers")
  end
end
