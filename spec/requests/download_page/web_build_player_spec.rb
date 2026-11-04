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

  def open_player
    visit("/d/#{url_redirect.token}")
    window_opened_by { click_link("Play") }
  end

  it "opens the build in its own tab and keeps the buyer's progress across a reload" do
    player = open_player
    within_window(player) do
      expect(page).to have_selector("iframe[title='Clicker'][sandbox='allow-scripts allow-pointer-lock']")
      within_frame(find("iframe[title='Clicker']")) do
        expect(page).to have_text("Clicks: 0")
        3.times { click_button("Add click") }
        expect(page).to have_text("Clicks: 3")
      end
    end
    wait_until_true { ProductBuildSave.find_by(purchase:)&.data == { "clicks" => "3" } }

    within_window(player) do
      refresh
      within_frame(find("iframe[title='Clicker']")) do
        expect(page).to have_text("Clicks: 3")
      end
    end
  end

  context "with a build that keeps its progress in IndexedDB" do
    let(:game_script) do
      <<~JS
        const request = indexedDB.open("progress", 1);
        request.onupgradeneeded = () => request.result.createObjectStore("values");
        request.onsuccess = () => {
          const db = request.result;
          const show = (clicks) => { document.getElementById("count").textContent = `Clicks: ${clicks}`; };
          const read = db.transaction("values").objectStore("values").get("clicks");
          read.onsuccess = () => show(read.result || 0);
          document.getElementById("add").addEventListener("click", () => {
            const store = db.transaction("values", "readwrite").objectStore("values");
            const current = store.get("clicks");
            current.onsuccess = () => {
              store.put((current.result || 0) + 1, "clicks");
              show((current.result || 0) + 1);
            };
          });
        };
      JS
    end

    it "keeps the buyer's progress across a reload" do
      player = open_player
      within_window(player) do
        within_frame(find("iframe[title='Clicker']")) do
          expect(page).to have_text("Clicks: 0")
          2.times { click_button("Add click") }
          expect(page).to have_text("Clicks: 2")
        end
      end
      wait_until_true do
        snapshot = ProductBuildSave.find_by(purchase:)&.data&.dig(ProductBuilds::PlayerDocument::INDEXEDDB_SAVE_KEY)
        snapshot && JSON.parse(snapshot)["databases"].sole["stores"].sole["records"] == [["clicks", 2]]
      end

      within_window(player) do
        refresh
        within_frame(find("iframe[title='Clicker']")) do
          expect(page).to have_text("Clicks: 2")
        end
      end
    end
  end

  it "keeps a change made right before leaving the player" do
    within_window(open_player) do
      within_frame(find("iframe[title='Clicker']")) do
        click_button("Add click")
        expect(page).to have_text("Clicks: 1")
      end
      click_link("Back to content")
    end

    wait_until_true { ProductBuildSave.find_by(purchase:)&.data == { "clicks" => "1" } }
  end

  describe "the content page actions" do
    let!(:readme) { create(:non_readable_document, link: product, display_name: "Read me") }

    def box(element) = page.evaluate_script("arguments[0].getBoundingClientRect().toJSON()", element)

    def expect_play_first_actions
      expect(page).to have_text("Web app, version 1")
      play = find_link("Play", href: "/d/#{url_redirect.token}/play")
      expect(play[:target]).to eq("_blank")
      build_actions = play.find(:xpath, "..")
      expect(build_actions.all(:link).map(&:text)).to eq(["Play", "Download"])
      download = build_actions.find_link("Download")
      readme_download = all(:link, exact_text: "Download").find { _1 != download }
      expect(page).not_to have_selector("iframe")

      expect(box(play)["top"]).to eq(box(download)["top"])
      expect(box(play)["right"]).to be <= box(download)["left"]
      expect(box(download)["right"]).to be_within(1).of(box(build_actions)["right"])

      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 900, deviceScaleFactor: 1, mobile: true)
      actions = box(build_actions)
      expect(box(play)["bottom"]).to be <= box(download)["top"]
      [box(play), box(download)].each do |action|
        expect(action["left"]).to be_within(1).of(actions["left"])
        expect(action["width"]).to be_within(1).of(actions["width"])
      end
      expect(box(readme_download)["width"]).to be < actions["width"] / 2
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end

    it "puts Play before Download in a rich content file embed, full width on phones" do
      content = product.alive_rich_contents.sole
      content.update!(description: [{ "type" => "fileEmbed", "attrs" => { "id" => readme.external_id, "uid" => SecureRandom.uuid } }] + content.description)

      visit("/d/#{url_redirect.token}")

      expect(page).to have_text("Read me")
      expect(page).not_to have_selector("[role='tree'][aria-label='Files']")
      expect_play_first_actions
    end

    it "puts Play before Download in the file list, full width on phones" do
      product.alive_rich_contents.each(&:mark_deleted!)

      visit("/d/#{url_redirect.token}")

      expect(page).to have_selector("[role='tree'][aria-label='Files']", text: "Read me")
      expect_play_first_actions
    end
  end

  it "shows the game's name, Full screen, and a way back to the content on the player page" do
    within_window(open_player) do
      expect(page).to have_selector("h1", text: "Clicker")
      expect(page).to have_button("Full screen")
      click_link("Back to content")
      expect(page).to have_current_path("/d/#{url_redirect.token}")
    end
  end

  context "inside the mobile app's player" do
    let(:oauth_application) { create(:oauth_application, owner: buyer) }
    let(:access_token) { create("doorkeeper/access_token", application: oauth_application, resource_owner_id: buyer.id, scopes: "mobile_api") }
    let(:game_script) do
      <<~JS
        document.getElementById("count").textContent = `Referrer: ${document.referrer || "none"}`;
      JS
    end

    before { visit("/d/#{url_redirect.token}/play?display=mobile_app&access_token=#{access_token.token}&mobile_token=#{Api::Mobile::BaseController::MOBILE_TOKEN}") }

    it "shows only the build, under the app's own header" do
      expect(page).to have_selector("iframe[title='Clicker']")
      expect(page).not_to have_link("Back to content")
      expect(page).not_to have_selector("h1", text: "Clicker")
      expect(page).not_to have_selector("[role='menubar']")
    end

    it "keeps the app's access token in the page's URL out of the build's reach" do
      within_frame(find("iframe[title='Clicker']")) do
        expect(page).to have_text("Referrer: none")
      end
    end
  end

  it "offers no Play action while the player is off for the seller" do
    Feature.deactivate_user(:product_build_player, seller)

    visit("/d/#{url_redirect.token}")

    expect(page).to have_text("Web app, version 1")
    expect(page).to have_link("Download")
    expect(page).not_to have_link("Play")
  end
end
