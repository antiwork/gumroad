# frozen_string_literal: true

require("spec_helper")

describe("Download Page", type: :system, js: true) do
  describe "open in app" do
    before do
      @product = create(:product, user: create(:user))
      create(:product_file, link_id: @product.id, url: "https://s3.amazonaws.com/gumroad-specs/specs/nyt.pdf").analyze
      create(:product_file, link_id: @product.id, url: "https://s3.amazonaws.com/gumroad-specs/specs/nyt.pdf").analyze
    end

    it "allows the user to create an account and show instructions to get the app" do
      purchase = create(:purchase_with_balance, link: @product, email: "user@testing.com")
      url_redirect = purchase.url_redirect

      visit("/d/#{url_redirect.token}")
      select_disclosure "Open in app" do
        expect(page).to have_text("Download from the App Store")
      end

      vcr_turned_on do
        VCR.use_cassette("Open in app-create account with not compromised password") do
          with_real_pwned_password_check do
            fill_in("Your password", with: SecureRandom.hex(24))
            click_on("Create")
          end
        end
      end
    end

    it "displays warning while creating an account with a compromised password" do
      purchase = create(:purchase_with_balance, link: @product, email: "user@testing.com")
      url_redirect = purchase.url_redirect

      visit("/d/#{url_redirect.token}")

      vcr_turned_on do
        VCR.use_cassette("Open in app-create account with compromised password") do
          with_real_pwned_password_check do
            fill_in("Your password", with: "password")
            click_on("Create")

            expect(page).to have_text("Password has previously appeared in a data breach as per haveibeenpwned.com and should never be used. Please choose something harder to guess.")
          end
        end
      end
    end

    it "shows the instructions to get the app immediately if logged in" do
      user = create(:user)
      login_as(user)
      purchase = create(:purchase_with_balance, link: @product, email: user.email, purchaser_id: user.id)
      url_redirect = purchase.url_redirect

      visit("/d/#{url_redirect.token}")

      select_disclosure "Open in app" do
        expect(page).to have_text("Download from the App Store")
        expect(page).to(have_link("App Store"))
        expect(page).to(have_link("Play Store"))
      end
    end
  end

  describe "discord integration" do
    let(:user_id) { "user-0" }
    let(:integration) { create(:discord_integration) }
    let(:product) { create(:product, active_integrations: [integration]) }
    let(:purchase) { create(:purchase, link: product) }
    let(:url_redirect) { create(:url_redirect, purchase:) }

    describe "Join Discord" do
      it "shows the join discord button if integration is present on purchased product" do
        visit("/d/#{url_redirect.token}")

        expect(page).to have_button "Join Discord"
      end

      it "does not show the join discord button if integration is not present on purchased product" do
        product.product_integrations.first.mark_deleted!
        visit("/d/#{url_redirect.token}")

        expect(page).to_not have_button "Join Discord"
      end

      it "adds customer to discord if oauth successful", billy: true do
        # TODO: Use the below commented out line instead, after removing the :custom_domain_download feature flag (curtiseinsmann)
        proxy.stub("https://www.discord.com:443/api/oauth2/authorize").and_return(redirect_to: oauth_redirect_integrations_discord_index_url(code: "test_code", host: UrlService.domain_with_protocol))
        # proxy.stub("https://www.discord.com:443/api/oauth2/authorize").and_return(redirect_to: oauth_redirect_integrations_discord_index_url(code: "test_code", host: product.user.subdomain_with_protocol))

        WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
          to_return(status: 200,
                    body: { access_token: "test_access_token" }.to_json,
                    headers: { content_type: "application/json" })

        WebMock.stub_request(:get, "#{Discordrb::API.api_base}/users/@me").
          with(headers: { "Authorization" => "Bearer test_access_token" }).
          to_return(status: 200,
                    body: { username: "gumbot", id: user_id }.to_json,
                    headers: { content_type: "application/json" })

        WebMock.stub_request(:put, "#{Discordrb::API.api_base}/guilds/0/members/#{user_id}").to_return(status: 201)

        visit("/d/#{url_redirect.token}")

        expect do
          click_button "Join Discord"
          expect_alert_message "You've been added to the Discord server #Gaming!"
          expect(page).to have_button "Leave Discord"
          expect(page).to_not have_button "Join Discord"
        end.to change { PurchaseIntegration.count }.by(1)

        purchase_discord_integration = PurchaseIntegration.last
        expect(purchase_discord_integration.discord_user_id).to eq(user_id)
        expect(purchase_discord_integration.integration).to eq(integration)
        expect(purchase_discord_integration.purchase).to eq(purchase)
      end

      it "shows error if oauth fails while adding customer to discord", billy: true do
        # TODO: Use the below commented out line instead, after removing the :custom_domain_download feature flag (curtiseinsmann)
        proxy.stub("https://www.discord.com:443/api/oauth2/authorize").and_return(redirect_to: oauth_redirect_integrations_discord_index_url(error: "error_message", host: UrlService.domain_with_protocol))
        # proxy.stub("https://www.discord.com:443/api/oauth2/authorize").and_return(redirect_to: oauth_redirect_integrations_discord_index_url(error: "error_message", host: product.user.subdomain_with_protocol))

        visit("/d/#{url_redirect.token}")

        expect do
          click_button "Join Discord"
          expect_alert_message "Could not join the Discord server, please try again."
          expect(page).to have_button "Join Discord"
          expect(page).to_not have_button "Leave Discord"
        end.to change { PurchaseIntegration.count }.by(0)
      end

      it "shows error if adding customer to discord fails", billy: true do
        # TODO: Use the below commented out line instead, after removing the :custom_domain_download feature flag (curtiseinsmann)
        proxy.stub("https://www.discord.com:443/api/oauth2/authorize").and_return(redirect_to: oauth_redirect_integrations_discord_index_url(code: "test_code", host: UrlService.domain_with_protocol))
        # proxy.stub("https://www.discord.com:443/api/oauth2/authorize").and_return(redirect_to: oauth_redirect_integrations_discord_index_url(code: "test_code", host: product.user.subdomain_with_protocol))

        WebMock.stub_request(:post, DISCORD_OAUTH_TOKEN_URL).
          to_return(status: 200,
                    body: { access_token: "test_access_token" }.to_json,
                    headers: { content_type: "application/json" })

        WebMock.stub_request(:get, "#{Discordrb::API.api_base}/users/@me").
          with(headers: { "Authorization" => "Bearer test_access_token" }).
          to_return(status: 200,
                    body: { username: "gumbot", id: user_id }.to_json,
                    headers: { content_type: "application/json" })

        WebMock.stub_request(:put, "#{Discordrb::API.api_base}/guilds/0/members/#{user_id}").to_return(status: 403)

        visit("/d/#{url_redirect.token}")

        expect do
          click_button "Join Discord"
          expect_alert_message "Could not join the Discord server, please try again."
          expect(page).to have_button "Join Discord"
          expect(page).to_not have_button "Leave Discord"
        end.to change { PurchaseIntegration.count }.by(0)
      end
    end

    describe "Leave Discord" do
      let!(:purchase_integration) { create(:purchase_integration, integration:, purchase:, discord_user_id: user_id) }

      it "shows the leave discord button if integration is activated" do
        visit("/d/#{url_redirect.token}")

        expect(page).to have_button "Leave Discord"
      end

      it "does not show the leave discord button if integration is not active" do
        purchase_integration.mark_deleted!

        visit("/d/#{url_redirect.token}")

        expect(page).to_not have_button "Leave Discord"
      end

      it "removes customer from discord" do
        WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/guilds/0/members/#{user_id}").to_return(status: 204)

        visit("/d/#{url_redirect.token}")

        expect do
          click_button "Leave Discord"
          expect_alert_message "You've left the Discord server #Gaming."
          expect(page).to_not have_button "Leave Discord"
          expect(page).to have_button "Join Discord"
        end.to change { purchase.live_purchase_integrations.count }.by(-1)
      end

      it "shows error if removing customer from Discord fails" do
        WebMock.stub_request(:delete, "#{Discordrb::API.api_base}/guilds/0/members/#{user_id}").to_return(status: 200)

        visit("/d/#{url_redirect.token}")

        expect do
          click_button "Leave Discord"
          expect_alert_message "Could not leave the Discord server."
          expect(page).to have_button "Leave Discord"
          expect(page).to_not have_button "Join Discord"
        end.to change { purchase.live_purchase_integrations.count }.by(0)
      end
    end
  end

  describe "add to library, if it was made anonymously but the user is currently logged in" do
    before do
      @user = create(:user)
      login_as(@user)

      product = create(:product, user: create(:user))
      create(:product_file, link_id: product.id, url: "https://s3.amazonaws.com/gumroad-specs/specs/nyt.pdf").analyze
      create(:product_file, link_id: product.id, url: "https://s3.amazonaws.com/gumroad-specs/specs/nyt.pdf").analyze
      @purchase = create(:purchase_with_balance, link: product, email: @user.email, purchaser_id: nil)
      url_redirect = @purchase.url_redirect
      visit("/d/#{url_redirect.token}")
    end

    it "adds purchase to library" do
      expect(page).to have_button("Add to library")
      click_button("Add to library")
      wait_for_ajax

      expect(@purchase.reload.purchaser).to eq @user
    end
  end

  describe "Community button" do
    let(:seller) { create(:user) }
    let(:user) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let!(:community) { create(:community, resource: product, seller:) }
    let(:purchase) { create(:purchase_with_balance, seller:, link: product, purchaser: user) }
    let(:url_redirect) { purchase.url_redirect }

    before do
      Feature.activate_user(:communities, seller)

      login_as(user)
    end

    it "does not render the Community button if the product has no active community" do
      visit("/d/#{url_redirect.token}")

      expect(page).not_to have_text("Community")
    end

    it "renders the Community button if the product has an active community" do
      product.update!(community_chat_enabled: true)

      visit("/d/#{url_redirect.token}")

      expect(page).to have_link("Community", href: community_path(seller.external_id, community.external_id))
    end
  end

  describe "installments" do
    before do
      allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)
      @user = create(:user, name: "John Doe")
      @post = create(:installment, name: "Thank you!", link: nil, seller: @user)
      @post.product_files << create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter2.mp4")
      @url_redirect = create(:installment_url_redirect, installment: @post)

      product_files_archive = @post.product_files_archives.create
      product_files_archive.product_files = @post.product_files
      product_files_archive.save!
      product_files_archive.mark_in_progress!
      product_files_archive.mark_ready!
    end

    it "renders the download page properly" do
      # Regular streamable files can be both watched and downloaded
      visit("/d/#{@url_redirect.token}")

      expect(page).to have_text("Thank you!")
      expect(page).to have_text("By John Doe")
      expect(page).to have_text("chapter2")
      expect(page).to have_link("Watch")
      expect(page).to have_link("Download", exact: true)
      expect(page).to have_disclosure("Download all")

      # Stream-only files can only be watched and not downloaded
      @post.product_files.first.update!(stream_only: true)

      visit("/d/#{@url_redirect.token}")

      expect(page).to have_text("chapter2")
      expect(page).to have_link("Watch")
      expect(page).not_to have_link("Download", exact: true)
      expect(page).not_to have_disclosure("Download all")
    end
  end

  describe "physical" do
    before do
      allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)
      @product = create(:physical_product)
      @purchase = create(:physical_purchase, link: @product)
      @url_redirect = create(:url_redirect, purchase: @purchase)
    end

    it "correctly renders the download page for a physical product with no files" do
      visit "/d/#{@url_redirect.token}"
      expect(page).not_to have_selector("[role=tree][aria-label=Files]")
      expect(page).not_to have_button("Download all")
    end
  end

  describe "membership" do
    before do
      @purchase = create(:membership_purchase)
      @url_redirect = create(:url_redirect, purchase: @purchase)
      @manage_membership_url = Rails.application.routes.url_helpers.manage_subscription_url(@purchase.subscription.external_id, host: "#{PROTOCOL}://#{DOMAIN}")
    end

    it "displays a link to manage membership if active" do
      visit "/d/#{@url_redirect.token}"
      select_disclosure "Membership" do
        button = find("a.button[href='#{@manage_membership_url}']")
        expect(button).to have_text "Manage"
      end
    end

    context "for inactive membership" do
      before { @purchase.subscription.update!(cancelled_at: 1.minute.ago) }

      it "displays a link to restart membership if inactive" do
        visit "/d/#{@url_redirect.token}"
        select_disclosure "Membership" do
          button = find("a.button[href='#{@manage_membership_url}']")
          expect(button).to have_text "Restart"
        end
      end

      context "when subscriber should lose access after cancellation" do
        before { @purchase.link.update!(block_access_after_membership_cancellation: true) }

        it "redirects to the inactive membership page" do
          visit "/d/#{@url_redirect.token}"
          expect(page).to have_current_path(url_redirect_membership_inactive_page_path(@url_redirect.token))
        end

        it "includes a Manage Membership link if the subscription is restartable" do
          allow_any_instance_of(Subscription).to receive(:alive_or_restartable?).and_return(true)
          visit "/d/#{@url_redirect.token}"
          button = find("a.button[href='#{@manage_membership_url}']")
          expect(button).to have_text "Manage membership"
        end

        it "includes a Resubscribe link if the subscription is not restartable" do
          allow_any_instance_of(Subscription).to receive(:alive_or_restartable?).and_return(false)
          visit "/d/#{@url_redirect.token}"
          button = find("a.button[href='#{@purchase.link.long_url}']")
          expect(button).to have_text "Resubscribe"
        end
      end
    end
  end

  describe "installment plans" do
    let(:purchase_with_installment_plan) { create(:installment_plan_purchase) }
    let(:subscription) { purchase_with_installment_plan.subscription }
    let(:url_redirect) { create(:url_redirect, purchase: purchase_with_installment_plan) }
    let(:manage_installment_plan_path) { manage_subscription_path(subscription.external_id) }

    context "active" do
      it "displays a link to manage installment plan" do
        visit "/d/#{url_redirect.token}"
        select_disclosure "Installment plan" do
          expect(page).to have_link("Manage", href: /#{Regexp.quote(manage_installment_plan_path)}/)
        end
      end
    end

    context "paid in full" do
      before { subscription.end_subscription! }

      it "shows a message that it has been paid in full" do
        visit "/d/#{url_redirect.token}"
        select_disclosure "Installment plan" do
          expect(page).to have_text "This installment plan has been paid in full."
        end
      end
    end

    context "failed" do
      before { subscription.unsubscribe_and_fail! }

      it "cuts off access to the product and includes a link to update payment method" do
        visit "/d/#{url_redirect.token}"

        expect(page).to have_text("Your installment plan is inactive")
        expect(page).to have_link("Update payment method", href: /#{Regexp.quote(manage_installment_plan_path)}/)
      end
    end

    context "cancelled by seller" do
      before { subscription.cancel!(by_seller: true) }

      it "cuts off access to the product and includes a link to update payment method" do
        visit "/d/#{url_redirect.token}"

        expect(page).to have_text("Your installment plan is inactive")
      end
    end
  end

  describe "membership with untitled tier" do
    it "uses the product name if tier's name is Untitled" do
      product = create(:membership_product, name: "my membership")
      tier = create(:variant, :with_product_file, variant_category: product.tier_category, name: "Untitled")
      purchase = create(:membership_purchase, link: product, variant_attributes: [tier])
      url_redirect = create(:url_redirect, purchase:)

      visit "/d/#{url_redirect.token}"
      expect(page).to have_title "my membership"
      expect(page).to_not have_content "Untitled"
    end
  end

  describe("new user") do
    before :each do
      link = create(:product_with_pdf_file)
      @purchase = create(:purchase, link:, email: "user@testing.com")
      @url_redirect = create(:url_redirect, link:, purchase: @purchase)
      visit("/d/#{@url_redirect.token}")
    end

    it("fails to sign me up") do
      fill_in("Your password", with: "123")
      click_on("Create")
      expect(page).to have_alert(text: "Password is too short (minimum is 4 characters)")
      expect(page).to_not have_button("Add to library")

      expect(User.exists?(email: "user@testing.com")).to(be(false))
    end

    it("signs me up and takes me to library") do
      fill_in("Your password", with: "123456")
      click_on("Create")
      wait_for_ajax
      expect(page).to_not have_text("Create an account to access all of your purchases in one place")
      expect(User.exists?(email: "user@testing.com")).to(be(true))
      user = User.last
      expect(Purchase.last.purchaser_id).to eq user.id
    end
  end

  describe "single video" do
    it "doesn't allow the file to be downloaded if it's streaming only" do
      product = create(:product)
      product.product_files << create(:streamable_video, stream_only: true)
      url_redirect = create(:url_redirect, link: product, purchase: nil)
      allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)

      visit("/d/#{url_redirect.token}")
      expect(page).not_to have_selector("button", exact_text: "Download")
    end

    it "doesn't display the download option for a rental" do
      product = create(:product)
      product.product_files << create(:streamable_video)
      url_redirect = create(:url_redirect, link: product, purchase: nil, is_rental: true)
      allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)

      visit("/d/#{url_redirect.token}")
      expect(page).not_to have_selector("button", exact_text: "Download")
    end
  end

  it "allows resending the receipt" do
    url_redirect = create(:url_redirect)
    allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)

    visit("/d/#{url_redirect.token}")
    select_disclosure "Receipt" do
      click_on "Resend receipt"
    end
    expect(page).to have_alert(text: "Receipt resent")
    expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(url_redirect.purchase.id).on("critical")
  end

  describe "archive actions" do
    before :each do
      @user = create(:user)
    end

    context "when unauthenticated" do
      it "doesn't shows archive button" do
        purchase = create(:purchase, purchaser: @user)
        create(:url_redirect, purchase:)
        Link.import(refresh: true, force: true)

        visit purchase.url_redirect.download_page_url
        expect(page).not_to have_button "Archive"
      end
    end

    context "when authenticated" do
      before :each do
        login_as @user
      end

      it "allows archiving" do
        purchase = create(:purchase, purchaser: @user)
        create(:url_redirect, purchase:)
        Link.import(refresh: true, force: true)

        visit purchase.url_redirect.download_page_url

        select_disclosure "Library" do
          click_on "Archive from library"
        end

        wait_for_ajax
        select_disclosure "Library" do
          expect(page).to have_button "Unarchive from library"
        end
      end

      it "allows unarchiving" do
        purchase = create(:purchase, purchaser: @user, is_archived: true)
        create(:url_redirect, purchase:)
        Link.import(refresh: true, force: true)

        visit purchase.url_redirect.download_page_url

        select_disclosure "Library" do
          click_on "Unarchive from library"
        end

        wait_for_ajax
        select_disclosure "Library" do
          expect(page).to have_button "Archive from library"
        end
      end

      it "doesn't shows when there is no purchase" do
        product = create(:product)
        url_redirect = create(:url_redirect, link: product, purchase: nil)

        visit url_redirect.download_page_url
        expect(page).to_not have_disclosure "Library"
      end
    end
  end

  describe "external links as files" do
    before do
      @url_redirect = create(:url_redirect)
      @product = @url_redirect.referenced_link
      @product.product_files << create(:product_file, link: @product, url: "https://gumroad.com", filetype: "link", display_name: "Gumroad – Sell what you know and see what sticks")
      login_as(@url_redirect.purchase.purchaser)
      Link.import(refresh: true)
    end

    it "shows Open button for external links" do
      visit("/d/#{@url_redirect.token}")
      expect(page).to have_link("Open", exact: true)
    end

    it "does not show the Download button for external links" do
      visit("/d/#{@url_redirect.token}")
      expect(page).to_not have_link("Download", exact: true)
    end

    it "Open button absent for non external-link product files" do
      @product.product_files.delete_all
      create(:non_listenable_audio, :analyze, link: @product)
      allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
      visit("/d/#{@url_redirect.token}")
      expect(page).to_not have_link("Open", exact: true)
    end

    it "redirects to the external url on clicking Open" do
      visit("/d/#{@url_redirect.token}")
      new_window = window_opened_by { click_on "Open" }
      within_window new_window do
        expect(page).to have_current_path("https://gumroad.com")
      end
    end

    it "redirects to the external url on clicking the name" do
      visit("/d/#{@url_redirect.token}")
      new_window = window_opened_by { click_on "Gumroad – Sell what you know and see what sticks" }
      within_window new_window do
        expect(page).to have_current_path("https://gumroad.com")
      end
    end
  end

  describe "seller with no name and username" do
    before do
      @user = create(:user, name: nil, username: nil)
      @product = create(:product, user: @user)
      @purchase = create(:purchase, email: "test@abc.com", link: @product)
      @url_redirect = create(:url_redirect, purchase: @purchase)
    end

    it "renders the page when the seller's URL is nil" do
      visit("/d/#{@url_redirect.token}")
      expect(page).to have_content(@product.name)
    end
  end

  describe "thank you note text" do
    it "does not render custom receipt text even if it exists" do
      custom_receipt_text = "Thanks for your purchase! https://example.com"
      product = create(:product, custom_receipt: custom_receipt_text)
      purchase = create(:purchase, email: "test@tynt.com", link: product)
      url_redirect = create(:url_redirect, purchase:)

      visit url_redirect.download_page_url

      expect(page).to_not have_text(custom_receipt_text)
    end

    it "does not render a paragraph if there is no custom receipt text" do
      product = create(:product)
      purchase = create(:purchase, email: "test@tynt.com", link: product)
      url_redirect = create(:url_redirect, purchase:)

      visit url_redirect.download_page_url

      expect(page).to_not have_selector("p")
    end
  end

  it "plays videos in the order they are shown on the download page for an installment" do
    video_blob = ActiveStorage::Blob.create_and_upload!(io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "sample.mov"), "video/quicktime"), filename: "sample.mov", key: "test/sample.mov")
    allow_any_instance_of(UrlRedirect).to receive(:html5_video_url_and_guid_for_product_file).and_return([video_blob.url, ""])

    product = create(:product)
    purchase = create(:purchase, link: product)
    url_redirect = create(:url_redirect, link: product, purchase:)
    post = create(:published_installment, seller: product.user, link: product, shown_on_profile: false)
    create(:creator_contacting_customers_email_info_sent, purchase: purchase, installment: post)
    post.product_files << create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter2.mp4", position: 1, created_at: 2.day.ago)
    post.product_files << create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/1/original/chapter1.mp4", position: 0, created_at: 1.day.ago)
    post.product_files << create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/4/original/chapter4.mp4", position: 3, created_at: 1.hour.ago)
    post.product_files << create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/3/original/chapter3.mp4", position: 2, created_at: 12.hours.ago)

    visit("/d/#{url_redirect.token}")

    within "[aria-label=Posts]" do
      within find("[role=listitem] h4", text: post.displayed_name).ancestor("[role=listitem]") do
        click_on "View"
      end
    end
    expect(page).to have_section post.displayed_name
    click_on "View content"
    expect(find_all("[role='treeitem'] h4").map(&:text)). to match_array(["chapter1", "chapter2", "chapter3", "chapter4"])
    within(find_file_row!(name: "chapter1")) do
      click_on "Watch"
    end
    page.driver.browser.switch_to.window(page.driver.browser.window_handles.last)
    click_on "More Videos"
    expect(page).to_not have_button("1. chapter1")
    expect(page).to have_button("Next Upchapter2")
    expect(page).to have_button("3. chapter3")
    expect(page).to have_button("4. chapter4")
    click_on "Previous"
    expect(page).to have_button("1. chapter1")
  end

  describe "email confirmation" do
    let(:product) { create(:product) }
    let(:purchase) { create(:purchase, link: product) }
    let(:url_redirect) { create(:url_redirect, link: product, purchase:) }

    before do
      visit(confirm_page_path(id: url_redirect.token, destination: "download_page"))
    end

    it "redirects to the download page after confirming email" do
      expect(page).to have_text("You've viewed this product a few times already")
      expect(page).to_not have_text("Liked it? Give it a rating")
      expect(page).to_not have_disclosure("Receipt")
      expect(page).to_not have_text("Create an account to access all of your purchases in one place")
      fill_in "Email address", with: purchase.email
      click_on "Confirm email"
      expect(page).to_not have_text("You've viewed this product a few times already")
      expect(page).to have_text("Liked it? Give it a rating")
      expect(page).to have_disclosure("Receipt")
      expect(page).to have_text("Create an account to access all of your purchases in one place")
      expect(page).to have_text(product.name)
    end

    it "renders the same page if the email is invalid" do
      expect(page).to have_text("You've viewed this product a few times already")
      fill_in "Email address", with: "invalid"
      click_on "Confirm email"
      expect(page).to have_alert(text: "Wrong email. Please try again.")
      expect(page).to have_text("You've viewed this product a few times already")
    end
  end

  describe "bundle product" do
    let(:seller) { create(:named_seller) }
    let(:purchase) { create(:purchase, seller:, link: create(:product, :bundle, user: seller)) }

    before { purchase.create_artifacts_and_send_receipt! }

    it "links to the bundle receipt" do
      visit purchase.product_purchases.first.url_redirect.download_page_url
      select_disclosure "Receipt"
      expect(page).to have_link("View receipt", href: receipt_purchase_url(purchase.external_id, email: purchase.email, host: Capybara.app_host))

      click_on "Resend receipt"
      expect(page).to have_alert(text: "Receipt resent")
      expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(purchase.id).on("critical")
    end
  end

  describe "post-purchase custom fields" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product) }
    let!(:url_redirect) { create(:url_redirect, link: product, purchase:) }
    let(:short_answer) { create(:custom_field, field_type: CustomField::TYPE_TEXT, name: "Short Answer", seller:, products: [product], is_post_purchase: true) }
    let(:long_answer) { create(:custom_field, field_type: CustomField::TYPE_LONG_TEXT, name: "Long Answer", seller:, products: [product], is_post_purchase: true) }
    let(:file_upload) { create(:custom_field, field_type: CustomField::TYPE_FILE, name: nil, seller:, products: [product], is_post_purchase: true) }

    before do
      create(:product_rich_content,
             entity: product,
             description: [
               {
                 "type" => RichContent::SHORT_ANSWER_NODE_TYPE,
                 "attrs" => {
                   "id" => short_answer.external_id,
                   "label" => "Short Answer"
                 }
               },
               {
                 "type" => RichContent::LONG_ANSWER_NODE_TYPE,
                 "attrs" => {
                   "id" => long_answer.external_id,
                   "label" => "Long Answer"
                 }
               },
               {
                 "type" => RichContent::FILE_UPLOAD_NODE_TYPE,
                 "attrs" => { "id" => file_upload.external_id,
                 }
               }
             ]
      )
    end

    it "allows completing post-purchase custom fields" do
      visit url_redirect.download_page_url

      short_answer_field = find_field("Short Answer")
      short_answer_field.fill_in with: "This is a short answer"
      short_answer_field.native.send_keys(:tab)
      wait_for_ajax
      expect(page).to have_alert(text: "Response saved!")

      long_answer_field = find_field("Long Answer")
      long_answer_field.fill_in with: "This is a longer answer with multiple sentences. It can contain more detailed information."
      long_answer_field.native.send_keys(:tab)
      wait_for_ajax
      expect(page).to have_alert(text: "Response saved!")

      expect(page).to have_text("Files must be smaller than 10 MB")
      attach_file("Upload files", file_fixture("smilie.png"), visible: false)
      wait_for_ajax
      expect(page).to have_alert(text: "Files uploaded successfully!")
      expect(page).to have_text("smilie")
      expect(page).to have_text("PNG")
      expect(page).to have_text("98.1 KB")

      purchase.reload
      expect(purchase.purchase_custom_fields.count).to eq(3)
      text_field = purchase.purchase_custom_fields.find_by(field_type: CustomField::TYPE_TEXT)
      expect(text_field.value).to eq("This is a short answer")
      expect(text_field.custom_field_id).to eq(short_answer.id)
      expect(text_field.purchase_id).to eq(purchase.id)
      expect(text_field.name).to eq("Short Answer")

      long_text_field = purchase.purchase_custom_fields.find_by(field_type: CustomField::TYPE_LONG_TEXT)
      expect(long_text_field.value).to eq("This is a longer answer with multiple sentences. It can contain more detailed information.")
      expect(long_text_field.custom_field_id).to eq(long_answer.id)
      expect(long_text_field.purchase_id).to eq(purchase.id)
      expect(long_text_field.name).to eq("Long Answer")

      file_field = purchase.purchase_custom_fields.find_by(field_type: CustomField::TYPE_FILE)
      expect(file_field.files).to be_attached
      expect(file_field.files.first.filename.to_s).to eq("smilie.png")
      expect(file_field.custom_field_id).to eq(file_upload.id)
      expect(file_field.purchase_id).to eq(purchase.id)
      expect(file_field.name).to eq(CustomField::FILE_FIELD_NAME)
      expect(file_field.value).to eq("")

      refresh

      short_answer_field = find_field("Short Answer", with: "This is a short answer")
      short_answer_field.fill_in with: "Updated short answer"
      short_answer_field.native.send_keys(:tab)
      wait_for_ajax
      expect(page).to have_alert(text: "Response saved!")

      long_answer_field = find_field("Long Answer", with: "This is a longer answer with multiple sentences. It can contain more detailed information.")
      long_answer_field.fill_in with: "This is an updated longer answer. It now contains different information."
      long_answer_field.native.send_keys(:tab)
      wait_for_ajax
      expect(page).to have_alert(text: "Response saved!")

      expect(page).to have_text("smilie")
      expect(page).to have_text("PNG")
      expect(page).to have_text("98.1 KB")
      attach_file("Upload files", file_fixture("test.png"), visible: false)
      wait_for_ajax
      expect(page).to have_alert(text: "Files uploaded successfully!")
      expect(page).to have_text("test")
      expect(page).to have_text("PNG")
      expect(page).to have_text("98.1 KB")

      purchase.reload
      expect(purchase.purchase_custom_fields.count).to eq(3)

      expect(text_field.reload.value).to eq("Updated short answer")

      expect(long_text_field.reload.value).to eq("This is an updated longer answer. It now contains different information.")

      file_field.reload
      expect(file_field.files.count).to eq(2)
      expect(file_field.files.last.filename.to_s).to eq("test.png")
    end
  end

  describe "calls" do
    let(:call) do
      create(
        :call,
        :skip_validation,
        start_time: DateTime.parse("January 1 2024 10:00"),
        end_time: DateTime.parse("January 1 2024 11:00")
      ).tap { _1.purchase.create_url_redirect! }
    end

    it "renders the call details" do
      visit call.purchase.url_redirect.download_page_url

      expect(page).to have_text("10:00 - 11:00 UTC")
      expect(page).to have_text("Monday, January 1, 2024")
      expect(page).to have_text("Call link https://zoom.us/j/gmrd", normalize_ws: true)
    end

    context "when the call has start and end times on different days" do
      let(:call_over_two_days) do
        create(
          :call,
          :skip_validation,
          start_time: DateTime.parse("January 1 2024 10:00"),
          end_time: DateTime.parse("January 2 2024 11:00")
        ).tap { _1.purchase.create_url_redirect! }
      end

      it "displays the call details" do
        visit call_over_two_days.purchase.url_redirect.download_page_url

        expect(page).to have_text("10:00 - 11:00 UTC")
        expect(page).to have_text("Monday, January 1, 2024 - Tuesday, January 2, 2024")
      end
    end

    context "when the call has no url" do
      before { call.update!(call_url: nil) }

      it "does not display the Call link" do
        visit call.purchase.url_redirect.download_page_url
        expect(page).not_to have_text("Call link")
      end
    end
  end

  context "when associated with a completed commission" do
    let(:commission) { create(:commission, status: Commission::STATUS_COMPLETED) }

    before do
      commission.files.attach(file_fixture("smilie.png"))
      commission.files.attach(file_fixture("test.pdf"))
      commission.deposit_purchase.create_url_redirect!
    end

    it "renders the commission files" do
      visit commission.deposit_purchase.url_redirect.download_page_url
      expect(page).to have_selector("[role='tab'][aria-selected='true']", text: "Downloads")

      expect(page).to have_text("test")
      expect(page).to have_text("PDF")
      expect(page).to have_text("8.1 KB")
      expect(page).to have_link("Download", href: commission.files.first.url)

      expect(page).to have_text("smilie")
      expect(page).to have_text("PNG")
      expect(page).to have_text("98.1 KB")
      expect(page).to have_link("Download", href: commission.files.last.url)
    end

    context "when the commission is not completed" do
      before { commission.update!(status: Commission::STATUS_IN_PROGRESS) }

      it "does not render the commission files" do
        visit commission.deposit_purchase.url_redirect.download_page_url

        expect(page).to_not have_text("Downloads")
        expect(page).to_not have_text("test")
        expect(page).to_not have_text("smilie")
      end
    end
  end

  describe "more like this" do
    let(:product) { create(:product, name: "Product") }
    let!(:other_product) { create(:product, user: product.user, name: "Other Product") }
    let!(:affiliate_product) { create(:product, name: "Affiliate Product") }
    let!(:affiliate) { create(:direct_affiliate, seller: affiliate_product.user, products: [affiliate_product], affiliate_user: product.user) }
    let!(:global_affiliate_product) { create(:product, name: "Global Affiliate Product") }

    it "recommends the correct set of products" do
      SalesRelatedProductsInfo.update_sales_counts(product_id: product.id, related_product_ids: [affiliate_product.id], increment: 1000)
      SalesRelatedProductsInfo.update_sales_counts(product_id: product.id, related_product_ids: [global_affiliate_product.id], increment: 1000)
      rebuild_srpis_cache
      allow_any_instance_of(Link).to receive(:recommendable?).and_return(true)

      content = create(:product_rich_content, entity: product, description: [{ "type" => RichContent::MORE_LIKE_THIS_NODE_TYPE }])
      purchase = create(:purchase, link: product)
      url_redirect = create(:url_redirect, link: product, purchase:)
      url_options = { layout: "profile", recommended_by: "more_like_this", recommender_model_name: "sales" }

      visit url_redirect.download_page_url
      expect(page).to have_text("Customers who bought this product also bought")
      expect(page).to have_link("Other Product", href: other_product.long_url(**url_options))
      expect(page).to_not have_text("Affiliate Product")
      expect(page).to_not have_text("Global Affiliate Product")

      content.update!(description: [{ "type" => RichContent::MORE_LIKE_THIS_NODE_TYPE, "attrs" => { "recommendationType" => "directly_affiliated_products" } }])
      visit url_redirect.download_page_url
      expect(page).to have_text("Customers who bought this product also bought")
      expect(page).to have_link("Other Product", href: other_product.long_url(**url_options))
      expect(page).to have_link("Affiliate Product", href: affiliate_product.long_url(**url_options, affiliate_id: affiliate.external_id_numeric))
      expect(page).to_not have_text("Global Affiliate Product")

      content.update!(description: [{ "type" => RichContent::MORE_LIKE_THIS_NODE_TYPE, "attrs" => { "recommendationType" => "gumroad_affiliates_products" } }])
      visit url_redirect.download_page_url
      expect(page).to have_text("Customers who bought this product also bought")
      expect(page).to have_link("Other Product", href: other_product.long_url(**url_options))
      expect(page).to have_link("Affiliate Product", href: affiliate_product.long_url(**url_options, affiliate_id: affiliate.external_id_numeric))
      expect(page).to have_link("Global Affiliate Product", href: global_affiliate_product.long_url(**url_options, affiliate_id: product.user.global_affiliate.external_id_numeric))
    end
  end

  describe "stamped PDF download" do
    it "shows a flash message when a stamped PDF is missing" do
      product = create(:product)
      create(:readable_document, link: product, pdf_stamp_enabled: true)
      purchase = create(:purchase, link: product)
      url_redirect = create(:url_redirect, purchase: purchase)
      url_redirect.update!(is_done_pdf_stamping: true)

      visit url_redirect.download_page_url
      click_on "Download"

      expect(page).to have_current_path(url_redirect.download_page_url)
      expect(page).to have_text("We are preparing the file for download. You will receive an email when it is ready.")
    end
  end
end
