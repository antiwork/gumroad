# frozen_string_literal: true

require "spec_helper"

describe "Download page web build player", type: :system, js: true do
  let(:seller) { create(:user) }
  let(:buyer) { create(:user) }
  let(:product) { create(:product, user: seller, name: "Clicker") }
  let(:purchase) { create(:purchase, link: product, purchaser: buyer) }
  let!(:url_redirect) { create(:url_redirect, link: product, purchase:) }
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
  let(:build) do
    zip = Zip::OutputStream.write_buffer do |out|
      out.put_next_entry("index.html")
      out.write(game_html)
      out.put_next_entry("game.mjs")
      out.write(game_script)
    end.string
    build = create(:product_build, product:, number: 1, byte_size: zip.bytesize)
    s3.put_object(bucket: S3_BUCKET, key: build.storage_key, body: zip)
    build
  end

  before do
    create(:rich_content, entity: product, description: [])
    build.promote!
    ProductBuilds::UnpackSiteService.perform(build)
    Feature.activate_user(:product_build_player, seller)
    login_as(buyer)
  end

  after do
    s3.list_objects_v2(bucket: S3_BUCKET, prefix: "builds/#{product.id}/").contents.each do |object|
      s3.delete_object(bucket: S3_BUCKET, key: object.key)
    end
  end

  def play
    visit("/d/#{url_redirect.token}")
    click_button("Play")
    expect(page).to have_selector("iframe[sandbox='allow-scripts allow-pointer-lock']")
  end

  it "plays the build in the page and keeps the buyer's progress across a reload" do
    play
    within_frame(find("iframe[title='Clicker build 1.zip']")) do
      expect(page).to have_text("Clicks: 0")
      3.times { click_button("Add click") }
      expect(page).to have_text("Clicks: 3")
    end
    wait_until_true { ProductBuildSave.find_by(purchase:)&.data == { "clicks" => "3" } }

    play
    within_frame(find("iframe[title='Clicker build 1.zip']")) do
      expect(page).to have_text("Clicks: 3")
    end
  end

  it "keeps the download next to Play, and closes the game" do
    visit("/d/#{url_redirect.token}")
    expect(page).to have_link("Download")
    expect(page).to have_text("Web build v1")

    click_button("Play")
    expect(page).to have_button("Full screen")
    click_button("Close")
    expect(page).not_to have_selector("iframe[title='Clicker build 1.zip']")
    expect(page).to have_button("Play")
  end

  it "offers no Play action while the player is off for the seller" do
    Feature.deactivate_user(:product_build_player, seller)

    visit("/d/#{url_redirect.token}")

    expect(page).to have_text("Web build v1")
    expect(page).to have_link("Download")
    expect(page).not_to have_button("Play")
  end
end
