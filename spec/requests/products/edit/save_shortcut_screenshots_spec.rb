# frozen_string_literal: true

require "spec_helper"
require "fileutils"

describe("Product Editor Save Shortcut Screenshots", type: :system, js: true) do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product, user: seller, name: "Screenshot Product", price_cents: 1000) }

  include_context "with switching account to user as admin for seller"

  def shots_base
    base = ENV["SCREENSHOT_OUT"].presence || Rails.root.join("tmp", "artifacts").to_s
    FileUtils.mkdir_p(base)
    base
  end

  def shot(name)
    path = File.join(shots_base, name)
    page.save_screenshot(path, full: true)
  end

  def hover_save_button
    save_btn = find(:button, "Save changes")
    save_btn.hover
  end

  it "captures flag-ON screenshots (tooltip hint and save confirmation)" do
    visit edit_link_path(product.unique_permalink)

    # Tooltip with shortcut hint (flag ON)
    hover_save_button
    # small pause to allow tooltip to render
    sleep 0.5
    shot("save-tooltip-enabled.png")

    # Save confirmation after Ctrl+S
    fill_in("Name", with: "Screenshot Product v2")
    unfocus
    find("body").send_keys([:control, "s"]) # headless linux: use Ctrl+S
    expect(page).to have_alert(text: "Changes saved!")
    shot("save-toast-after-cmds.png")
  end

  it "rebuilds assets with PRODUCT_EDITOR_SAVE_SHORTCUT=false and captures flag-OFF screenshots" do
    # Rebuild assets for test with flag OFF
    Dir.chdir(Rails.root) do
      # Ensure we only rebuild once per run
      marker = Rails.root.join("tmp", "flag_off_build_done")
      unless File.exist?(marker)
        system({ "PRODUCT_EDITOR_SAVE_SHORTCUT" => "false", "RAILS_ENV" => "test" }, "bin/shakapacker") or raise "shakapacker build failed"
        FileUtils.touch(marker)
      end
    end

    # New page load should use the updated manifest with flag OFF
    visit edit_link_path(product.unique_permalink)

    # Hover Save - tooltip should not include shortcut hint when flag is OFF
    hover_save_button
    sleep 0.5
    shot("save-tooltip-disabled-flag-off.png")

    # Also verify aria-keyshortcuts is absent and capture DOM as HTML for verification
    save_btn = find(:button, "Save changes")
    expect(save_btn["aria-keyshortcuts"]).to be_nil
    File.write(File.join(shots_base, "save-button-flag-off.html"), save_btn.native.path.to_html)
  end
end
