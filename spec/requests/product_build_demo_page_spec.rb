# frozen_string_literal: true

require "spec_helper"

describe "Web build demo page", type: :system, js: true do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, name: "Clicker", price_cents: 0) }
  let(:s3) { Aws::S3::Client.new }
  let(:game_html) do
    <<~HTML
      <!doctype html>
      <html><head><title>Clicker</title><script type="module" src="game.mjs"></script></head>
      <body><p id="count">Loading</p><button id="add">Add click</button></body></html>
    HTML
  end
  let(:game_script) do
    <<~JS
      const show = () => { document.getElementById("count").textContent = `Clicks: ${localStorage.getItem("clicks") || 0}`; };
      document.getElementById("add").addEventListener("click", () => {
        localStorage.setItem("clicks", String(Number(localStorage.getItem("clicks") || 0) + 1));
        show();
      });
      show();
    JS
  end

  before do
    zip = Zip::OutputStream.write_buffer do |out|
      out.put_next_entry("index.html")
      out.write(game_html)
      out.put_next_entry("game.mjs")
      out.write(game_script)
    end.string
    build = create(:product_build, product:, number: 1, byte_size: zip.bytesize)
    s3.put_object(bucket: S3_BUCKET, key: build.storage_key, body: zip)
    create(:rich_content, entity: product, description: [])
    build.promote!
    ProductBuilds::UnpackSiteService.perform(build)
    Feature.activate_user(:product_build_player, seller)
    Feature.activate_user(:product_build_demo, seller)
  end

  after do
    s3.list_objects_v2(bucket: S3_BUCKET, prefix: "builds/#{product.id}/").contents.each do |object|
      s3.delete_object(bucket: S3_BUCKET, key: object.key)
    end
  end

  it "plays the build signed out, saves nothing, and links to the product in a new tab" do
    visit("/demo/#{product.external_id}")

    expect(page).to have_selector("h1", text: "Clicker")
    within_frame(find("iframe[title='Clicker'][sandbox='allow-scripts allow-pointer-lock']")) do
      expect(page).to have_text("Clicks: 0")
      2.times { click_button("Add click") }
      expect(page).to have_text("Clicks: 2")
    end
    expect(ProductBuildSave.count).to eq(0)

    product_page = window_opened_by { click_link("Get it on Gumroad") }
    within_window(product_page) do
      expect(page).to have_current_path(short_link_path(product.unique_permalink))
    end

    refresh
    within_frame(find("iframe[title='Clicker']")) do
      expect(page).to have_text("Clicks: 0")
    end
  end

  it "plays the build the seller chose as the demo of a paid product, not the one buyers get" do
    product.update!(price_cents: 500)
    zip = Zip::OutputStream.write_buffer do |out|
      out.put_next_entry("index.html")
      out.write("<!doctype html><html><head><title>Clicker demo</title></head><body><p>Demo: try 3 clicks</p></body></html>")
    end.string
    demo = create(:product_build, product:, number: 2, byte_size: zip.bytesize)
    s3.put_object(bucket: S3_BUCKET, key: demo.storage_key, body: zip)
    demo.select_as_demo!
    ProductBuildUnpackJob.drain

    visit("/demo/#{product.external_id}")

    within_frame(find("iframe[title='Clicker']")) do
      expect(page).to have_text("Demo: try 3 clicks")
    end
    expect(product.product_builds.live.sole.number).to eq(1)
  end
end
