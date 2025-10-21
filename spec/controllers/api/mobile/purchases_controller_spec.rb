# frozen_string_literal: true

require "spec_helper"
require "shared_examples/paginated_api"

describe Api::Mobile::PurchasesController do
  before do
    @user = create(:user)
    @purchaser = create(:user)
    @app = create(:oauth_application, owner: @user)
    @params = {
      mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
      access_token: create("doorkeeper/access_token", application: @app, resource_owner_id: @purchaser.id, scopes: "mobile_api").token
    }
  end

  describe "GET index" do
    before do
      @mobile_friendly_pdf_product = create(:product, user: @user)
      create(:product_file, link_id: @mobile_friendly_pdf_product.id,
                            url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/23b2d41ac63a40b5afa1a99bf38a0982/original/nyt.pdf")
      @mobile_friendly_movie_product = create(:product, user: @user)
      create(:product_file, link_id: @mobile_friendly_movie_product.id, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter2.mp4")
      @mobile_friendly_mp3_product = create(:product, user: @user)
      create(:product_file, link_id: @mobile_friendly_mp3_product.id, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/magic.mp3")
      @subscription_product = create(:membership_product, subscription_duration: "monthly", user: @user)

      @mobile_zip_file_product = create(:product, user: @user)
      create(:product_file, link_id: @mobile_zip_file_product.id, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/test.zip")
    end

    describe "successful response format" do
      it "returns product and file data" do
        product = create(:product, user: @user, name: "The Works of Edgar Gumstein", description: "A collection of works spanning 1984 — 1994")
        create(:product_file, link: product, description: "A song", url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/magic.mp3")
        purchase = create(:purchase_with_balance, link: product, purchaser: @purchaser, seller: @user, is_rental: true)

        get :index, params: @params

        expect(response).to match_json_schema("api/mobile/purchases")
        expect(response.parsed_body).to include(success: true, user_id: @purchaser.external_id)
        expect(response.parsed_body[:products][0]).to include(name: "The Works of Edgar Gumstein",
                                                              description: "A collection of works spanning 1984 — 1994",
                                                              url_redirect_external_id: purchase.url_redirect.external_id,
                                                              url_redirect_token: purchase.url_redirect.token,
                                                              purchase_id: purchase.external_id,
                                                              has_rich_content: true,
                                                              purchase_email: purchase.email)
        expect(response.parsed_body[:products][0][:file_data][0]).to include(name_displayable: "magic", description: "A song")
      end
    end

    it "returns the product files in the correct order based on how they appear in the rich content" do
      product = create(:product, user: @user)
      page1_content = create(:product_rich_content, entity: product)
      page2_content = create(:product_rich_content, entity: product)

      file1 = create(:listenable_audio, display_name: "Summer times", link: product, position: 0)
      file2 = create(:product_file, display_name: "Extras", link: product, position: 1, created_at: 2.days.ago)
      file3 = create(:readable_document, display_name: "Tricks", link: product, position: 2)
      file4 = create(:streamable_video, display_name: "Watch: How do I make music?", link: product, position: 3, created_at: 1.day.ago)
      file5 = create(:listenable_audio, display_name: "Move on", link: product, position: 4, created_at: 3.days.ago)

      page1_content.update!(description: [
                              { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Page 1 content" }] },
                              { "type" => "image", "attrs" => { "src" => "https://example.com/album.jpg", "link" => nil } },
                              { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
                              { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "World" }] },
                              { "type" => "blockquote", "content" => [
                                { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Inside blockquote" }] },
                                { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
                              ] },
                              { "type" => "orderedList", "content" => [
                                { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ordered list item 1" }] }] },
                                { "type" => "listItem", "content" => [
                                  { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ordered list item 2" }] },
                                  { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
                                ] },
                                { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ordered list item 3" }] }] },
                              ] },
                            ])
      page2_content.update!(description: [
                              { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Page 2 content" }] },
                              { "type" => "bulletList", "content" => [
                                { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Bullet list item 1" }] }] },
                                { "type" => "listItem", "content" => [
                                  { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Bullet list item 2" }] },
                                  { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
                                ] },
                                { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Bullet list item 3" }] }] },
                              ] },
                              { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Lorem ipsum" }] },
                              { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
                            ])

      create(:purchase_with_balance, link: product, purchaser: @purchaser, seller: @user)

      get :index, params: @params

      expect(response.parsed_body["products"][0]["file_data"].map { _1["name_displayable"] }).to eq(["Extras", "Move on", "Summer times", "Watch: How do I make music?", "Tricks"])
    end

    it "includes thumbnail url if available" do
      product = create(:product, user: @user, name: "The Works of Edgar Gumstein", description: "A collection of works spanning 1984 — 1994")
      thumbnail = create(:thumbnail, product:)
      product.reload
      create(:purchase_with_balance, link: product, purchaser: @purchaser, seller: @user, is_rental: true)

      get :index, params: @params

      expect(response).to match_json_schema("api/mobile/purchases")
      expect(response.parsed_body[:products][0][:thumbnail_url]).to eq(thumbnail.url)
    end

    it "displays subscription products" do
      # Alive Subscription
      subscription = create(:subscription, link: @subscription_product, user: @purchaser)
      subscription_purchase = create(:purchase, link: @subscription_product,
                                                subscription:,
                                                is_original_subscription_purchase: true,
                                                purchaser: @purchaser)
      create(:url_redirect, purchase: subscription_purchase)
      # Dead Subscription
      dead_sub_link = create(:membership_product, subscription_duration: "yearly", user: @user)
      dead_subscription = create(:subscription, link: dead_sub_link, user: @purchaser)
      dead_subscription_purchase = create(:purchase, link: dead_sub_link,
                                                     subscription: dead_subscription,
                                                     is_original_subscription_purchase: true,
                                                     purchaser: @purchaser)
      create(:url_redirect, purchase: dead_subscription_purchase)
      dead_subscription.cancel_effective_immediately!

      # Both subscriptions should appear in the response

      get :index, params: @params
      expect(response.parsed_body).to eq({ success: true,
                                           products: [subscription_purchase.json_data_for_mobile, dead_subscription_purchase.json_data_for_mobile],
                                           user_id: @purchaser.external_id }.as_json(api_scopes: ["mobile_api"]))
    end

    it "does not return unsuccessful purchases" do
      created_at_minute_advance = 0
      purchases = [@mobile_friendly_pdf_product, @mobile_friendly_movie_product, @mobile_zip_file_product, @mobile_friendly_mp3_product].map do |product|
        created_at_minute_advance += 10
        purchase = create(:purchase_with_balance, link: product, purchaser: @purchaser, seller: @user)
        purchase.update_attribute("created_at", created_at_minute_advance.minutes.from_now)
        purchase
      end

      purchases.first.update_attribute(:stripe_refunded, true)
      purchases.last.update_attribute(:chargeback_date, Time.current)

      get :index, params: @params

      expect(response.parsed_body).to eq({
        success: true,
        products: purchases[1..2].sort_by(&:created_at).map { |purchase| purchase.json_data_for_mobile },
        user_id: @purchaser.external_id
      }.as_json(api_scopes: ["mobile_api"]))
    end

    it "does not return purchases that are expired rentals" do
      @mobile_friendly_movie_product.update!(rental_price_cents: 0)
      purchase = create(:purchase_with_balance, link: @mobile_friendly_movie_product, purchaser: @purchaser, seller: @user, is_rental: true)
      purchase.url_redirect.update!(is_rental: true, rental_first_viewed_at: 10.days.ago)
      ExpireRentalPurchasesWorker.new.perform

      get :index, params: @params

      expect(response.parsed_body).to eq({
        success: true,
        products: [],
        user_id: @purchaser.external_id
      }.as_json(api_scopes: ["mobile_api"]))
    end

    it "does not include purchases that are deleted by the buyer" do
      create(:purchase_with_balance, link: @mobile_friendly_movie_product, purchaser: @purchaser, seller: @user, is_deleted_by_buyer: true)

      get :index, params: @params

      expect(response.parsed_body).to eq({
        success: true,
        products: [],
        user_id: @purchaser.external_id
      }.as_json(api_scopes: ["mobile_api"]))
    end

    it "returns purchases that are archived" do
      @mobile_friendly_movie_product.update!(rental_price_cents: 0)
      archived_purchase = create(:purchase_with_balance, link: @mobile_friendly_movie_product, purchaser: @purchaser, seller: @user,
                                                         is_rental: true, is_archived: true)

      get :index, params: @params

      expect(response.parsed_body).to eq({
        success: true,
        products: [archived_purchase.json_data_for_mobile],
        user_id: @purchaser.external_id
      }.as_json(api_scopes: ["mobile_api"]))
    end

    it "does not accept tokens without the mobile_api scope" do
      [@mobile_friendly_pdf_product, @mobile_friendly_movie_product, @mobile_zip_file_product, @mobile_friendly_mp3_product].map do |product|
        create(:purchase_with_balance, link: product, purchaser: @purchaser, seller: @user)
      end
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @purchaser.id, scopes: "edit_products")

      get :index, params: { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: token.token }

      expect(response.code).to eq("403")
      expect(response.body).to be_blank
    end

    it "responds with an empty list on error" do
      allow_any_instance_of(Purchase).to receive(:json_data_for_mobile).and_raise(StandardError.new("error"))
      create(:purchase, purchaser: @purchaser)
      expect(Bugsnag).to receive(:notify).once

      get :index, params: @params

      expect(response.parsed_body).to eq({
        success: true,
        products: [],
        user_id: @purchaser.external_id
      }.as_json)
    end

    describe "show all products" do
      it "displays products without files in the api" do
        created_at_minute_advance = 0
        fileless_product = create(:physical_product, name: "physical product", user: @user)
        purchases = [@mobile_friendly_pdf_product, @mobile_friendly_movie_product, @mobile_zip_file_product, fileless_product].map do |product|
          created_at_minute_advance += 10
          purchase = if product.is_physical
            create(:physical_purchase, link: product, purchaser: @purchaser, seller: @user)
          else
            create(:purchase, link: product, purchaser: @purchaser, seller: @user)
          end
          purchase.update_attribute("created_at", created_at_minute_advance.minutes.from_now)
          purchase
        end

        get :index, params: @params

        expect(response.parsed_body).to eq({ success: true,
                                             products: purchases.sort_by(&:created_at)
                                                       .map { |purchase| purchase.json_data_for_mobile }.compact,
                                             user_id: @purchaser.external_id }.as_json(api_scopes: ["mobile_api"]))
      end

      it "includes mobile unfriendly products" do
        created_at_minute_advance = 0
        fileless_product = create(:physical_product, name: "not mobile_friendly", user: @user)
        purchases = [@mobile_friendly_pdf_product, @mobile_friendly_movie_product, @mobile_zip_file_product, fileless_product].map do |product|
          created_at_minute_advance += 10
          purchase = if product.is_physical
            create(:physical_purchase, link: product, purchaser: @purchaser, seller: @user)
          else
            create(:purchase, link: product, purchaser: @purchaser, seller: @user)
          end
          purchase.update_attribute("created_at", created_at_minute_advance.minutes.from_now)
          purchase
        end

        get :index, params: @params

        expect(response.parsed_body).to eq({ success: true,
                                             products: purchases.sort_by(&:created_at).map(&:json_data_for_mobile).compact,
                                             user_id: @purchaser.external_id }.as_json(api_scopes: ["mobile_api"]))
      end

      it "includes preorder products", :vcr do
        created_at_minute_advance = 0
        purchases = [@mobile_friendly_pdf_product, @mobile_friendly_movie_product, @mobile_zip_file_product].map do |product|
          created_at_minute_advance += 10
          purchase = create(:purchase_with_balance, link: product, purchaser: @purchaser, seller: @user)
          purchase.update_attribute("created_at", created_at_minute_advance.minutes.from_now)
          purchase
        end
        product = create(:product, price_cents: 600, is_in_preorder_state: true, name: "preorder link")
        create(:product_file, link_id: product.id, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/preorder.zip")
        preorder_link = create(:preorder_link, link: product, release_at: 2.days.from_now)
        good_card = build(:chargeable)
        authorization_purchase = create(:purchase,
                                        link: preorder_link.link,
                                        chargeable: good_card,
                                        purchase_state: "in_progress",
                                        is_preorder_authorization: true,
                                        created_at: 50.minutes.from_now,
                                        purchaser: @purchaser)
        preorder = preorder_link.build_preorder(authorization_purchase)
        preorder.authorize!
        preorder.mark_authorization_successful!
        purchases << authorization_purchase

        get :index, params: @params

        expect(response.parsed_body).to eq({ success: true,
                                             products: purchases.sort_by(&:created_at)
                                                  .map { |purchase| purchase.json_data_for_mobile }.compact,
                                             user_id: @purchaser.external_id }.as_json(api_scopes: ["mobile_api"]))
      end

      it "paginates results when pagination params are given" do
        created_at_minute_advance = 0
        purchases = [@mobile_friendly_pdf_product, @mobile_friendly_movie_product, @mobile_zip_file_product].map do |product|
          create(:purchase_with_balance, link: product, purchaser: @purchaser, seller: @user,
                                         created_at: (created_at_minute_advance += 10).minutes.from_now)
        end

        get :index, params: @params.merge(page: 1, per_page: 2)

        expect(response.parsed_body).to eq({ success: true,
                                             products: purchases.sort_by(&:created_at).map(&:json_data_for_mobile).compact.first(2),
                                             user_id: @purchaser.external_id }.as_json(api_scopes: ["mobile_api"]))
      end
    end
  end

  describe "POST archive" do
    it "archives a product" do
      purchase = create(:purchase_with_balance, purchaser: @purchaser)

      post :archive, params: @params.merge(id: purchase.external_id)

      expect(response.parsed_body).to eq({ success: true, product: purchase.reload.json_data_for_mobile }.as_json)
      expect(purchase.reload.is_archived).to eq(true)
    end

    it "archives a refunded subscription" do
      subscription = create(:subscription, original_purchase: create(:refunded_purchase, purchaser: @purchaser))
      purchase = subscription.original_purchase

      post :archive, params: @params.merge(id: purchase.external_id)

      expect(response.parsed_body).to eq({ success: true, product: purchase.reload.json_data_for_mobile }.as_json)
      expect(purchase.reload.is_archived).to eq(true)
    end

    it "does not archive an unsuccessful purchase" do
      purchase = create(:purchase, purchaser: @purchaser, purchase_state: "failed")

      post :archive, params: @params.merge(id: purchase.external_id)

      expect(response.parsed_body).to eq({ success: false, message: "Could not find purchase" }.as_json)
      expect(purchase.reload.is_archived).to eq false
    end

    describe "subscription purchases" do
      let(:purchase) { create(:membership_purchase, purchaser: @purchaser) }

      it "archives a live subscription purchase" do
        post :archive, params: @params.merge(id: purchase.external_id)

        expect(response.parsed_body).to eq({ success: true, product: purchase.reload.json_data_for_mobile }.as_json)
        expect(purchase.reload.is_archived).to eq true
      end

      it "archives a lapsed subscription purchase" do
        purchase.subscription.update!(cancelled_at: 1.day.ago)

        post :archive, params: @params.merge(id: purchase.external_id)

        expect(response.parsed_body).to eq({ success: true, product: purchase.reload.json_data_for_mobile }.as_json)
        expect(purchase.reload.is_archived).to eq true
      end
    end

    context "when the purchase doesn't belong to the purchaser" do
      it "returns a 404 response" do
        purchase = create(:purchase_with_balance, purchaser: create(:user))
        post :archive, params: @params.merge(id: purchase.external_id)

        expect(response).to have_http_status :not_found
        expect(response.parsed_body).to eq({ success: false, message: "Could not find purchase" }.as_json)
      end
    end
  end

  describe "POST unarchive" do
    it "unarchives an archived product" do
      purchase = create(:purchase_with_balance, purchaser: @purchaser)
      purchase.is_archived = true
      purchase.save!

      post :unarchive, params: @params.merge(id: purchase.external_id)

      expect(response.parsed_body).to eq({ success: true, product: purchase.reload.json_data_for_mobile }.as_json)
      expect(purchase.reload.is_archived).to eq(false)
    end

    it "unarchives a refunded subscription" do
      subscription = create(:subscription, original_purchase: create(:refunded_purchase, purchaser: @purchaser, is_archived: true))
      purchase = subscription.original_purchase

      post :unarchive, params: @params.merge(id: purchase.external_id)

      expect(response.parsed_body).to eq({ success: true, product: purchase.reload.json_data_for_mobile }.as_json)
      expect(purchase.reload.is_archived).to eq(false)
    end

    it "does not unarchive an unsuccessful purchase" do
      purchase = create(:purchase, purchaser: @purchaser, purchase_state: "failed", is_archived: true)

      post :unarchive, params: @params.merge(id: purchase.external_id)

      expect(response.parsed_body).to eq({ success: false, message: "Could not find purchase" }.as_json)
      expect(purchase.reload.is_archived).to eq true
    end

    describe "subscription purchases" do
      let(:purchase) { create(:membership_purchase, purchaser: @purchaser, is_archived: true) }

      it "archives a live subscription purchase" do
        post :unarchive, params: @params.merge(id: purchase.external_id)

        expect(response.parsed_body).to eq({ success: true, product: purchase.reload.json_data_for_mobile }.as_json)
        expect(purchase.reload.is_archived).to eq false
      end

      it "archives a lapsed subscription purchase" do
        purchase.subscription.update!(cancelled_at: 1.day.ago)

        post :unarchive, params: @params.merge(id: purchase.external_id)

        expect(response.parsed_body).to eq({ success: true, product: purchase.reload.json_data_for_mobile }.as_json)
        expect(purchase.reload.is_archived).to eq false
      end
    end

    context "when the purchase doesn't belong to the purchaser" do
      it "returns a 404 response" do
        purchase = create(:purchase_with_balance, purchaser: create(:user))
        post :unarchive, params: @params.merge(id: purchase.external_id)

        expect(response).to have_http_status :not_found
        expect(response.parsed_body).to eq({ success: false, message: "Could not find purchase" }.as_json)
      end
    end
  end

  describe "purchase_attributes" do
    it "returns details for a successful product" do
      purchase = create(:purchase, purchaser: @purchaser)

      get :purchase_attributes, params: @params.merge(id: purchase.external_id)

      expect(response.parsed_body).to eq({ success: true, product: purchase.json_data_for_mobile }.as_json)
    end

    it "does not return details for an unsuccessful product" do
      purchase = create(:purchase, purchaser: @purchaser, purchase_state: "failed")

      get :purchase_attributes, params: @params.merge(id: purchase.external_id)

      expect(response.parsed_body).to eq({ success: false, message: "Could not find purchase" }.as_json)
    end

    describe "subscription purchases" do
      let(:purchase) { create(:membership_purchase, purchaser: @purchaser) }

      it "returns details for a live subscription purchase" do
        get :purchase_attributes, params: @params.merge(id: purchase.external_id)

        expect(response.parsed_body).to eq({ success: true, product: purchase.reload.json_data_for_mobile }.as_json)
      end

      it "returns details for a lapsed subscription purchase" do
        purchase.subscription.update!(cancelled_at: 1.day.ago)

        get :purchase_attributes, params: @params.merge(id: purchase.external_id)

        expect(response.parsed_body).to eq({ success: true, product: purchase.reload.json_data_for_mobile }.as_json)
      end
    end

    context "when the purchase doesn't belong to the purchaser" do
      it "returns a 404 response" do
        purchase = create(:purchase_with_balance, purchaser: create(:user))
        get :purchase_attributes, params: @params.merge(id: purchase.external_id)

        expect(response).to have_http_status :not_found
        expect(response.parsed_body).to eq({ success: false, message: "Could not find purchase" }.as_json)
      end
    end
  end

  describe "GET search", :elasticsearch_wait_for_refresh do
    it "returns purchases for a given user" do
      purchase_1 = create(:purchase, purchaser: @purchaser)
      purchase_2 = create(:purchase, purchaser: @purchaser)
      create(:purchase)
      index_model_records(Purchase)

      get :search, params: @params

      expect(response).to match_json_schema("api/mobile/purchases")

      expect(response.parsed_body[:purchases][1][:purchase_id]).to eq(purchase_1.external_id)
      expect(response.parsed_body[:purchases][0][:purchase_id]).to eq(purchase_2.external_id)
    end

    it "returns aggregation based on sellers" do
      seller_1 = create(:named_user)
      seller_2 = create(:named_user)
      create(:purchase, purchaser: @purchaser, link: create(:product, user: seller_1))
      create(:purchase, purchaser: @purchaser, link: create(:product, user: seller_2))
      create(:purchase, purchaser: @purchaser, link: create(:product, user: seller_2))
      index_model_records(Purchase)

      get :search, params: @params

      expect(response).to match_json_schema("api/mobile/purchases")

      expect(response.parsed_body).to include(success: true, user_id: @purchaser.external_id)
      expect(response.parsed_body[:sellers]).to match_array([
                                                              { purchases_count: 1, id: seller_1.external_id, name: seller_1.name },
                                                              { purchases_count: 2, id: seller_2.external_id, name: seller_2.name }
                                                            ])
    end

    describe "filter by seller" do
      it "returns purchases for a given user and seller" do
        seller_1 = create(:named_user)
        seller_2 = create(:named_user)
        purchase_1 = create(:purchase, purchaser: @purchaser, link: create(:product, user: seller_1))
        create(:purchase, purchaser: @purchaser, link: create(:product, user: seller_2))
        create(:purchase, purchaser: @purchaser, link: create(:product, user: seller_2))
        index_model_records(Purchase)

        get :search, params: @params.merge(seller: seller_1.external_id)

        expect(response).to match_json_schema("api/mobile/purchases")
        expect(response.parsed_body).to include(success: true, user_id: @purchaser.external_id)
        expect(response.parsed_body[:purchases].size).to eq(1)
        expect(response.parsed_body[:purchases][0][:purchase_id]).to eq(purchase_1.external_id)
        expect(response.parsed_body[:sellers]).to match_array([{ purchases_count: 1, id: seller_1.external_id, name: seller_1.name }])

        # Can filter by multiple sellers
        get :search, params: @params.merge(seller: [seller_1.external_id, seller_2.external_id])

        expect(response).to match_json_schema("api/mobile/purchases")
        expect(response.parsed_body[:purchases].size).to eq(3)
      end
    end

    describe "filter by archived" do
      it "returns archived purchases for a given user" do
        seller_1 = create(:named_user)
        seller_2 = create(:named_user)
        purchase_1 = create(:purchase, purchaser: @purchaser, link: create(:product, user: seller_1), is_archived: true)
        purchase_2 = create(:purchase, purchaser: @purchaser, link: create(:product, user: seller_2))
        purchase_3 = create(:purchase, purchaser: @purchaser, link: create(:product, user: seller_2))
        index_model_records(Purchase)

        get :search, params: @params.merge(archived: "true")

        expect(response).to match_json_schema("api/mobile/purchases")
        expect(response.parsed_body).to include(success: true, user_id: @purchaser.external_id)
        expect(response.parsed_body[:purchases].size).to eq(1)
        expect(response.parsed_body[:purchases][0][:purchase_id]).to eq(purchase_1.external_id)

        get :search, params: @params.merge(archived: "false")

        expect(response).to match_json_schema("api/mobile/purchases")
        expect(response.parsed_body).to include(success: true, user_id: @purchaser.external_id)
        expect(response.parsed_body[:purchases].size).to eq(2)
        expect(response.parsed_body[:purchases][0][:purchase_id]).to eq(purchase_3.external_id)
        expect(response.parsed_body[:purchases][1][:purchase_id]).to eq(purchase_2.external_id)
      end
    end

    describe "query by product details" do
      it "returns purchases for a given user matching creator description" do
        seller_1 = create(:named_user, name: "Daniel")
        seller_2 = create(:named_user, name: "Julia")
        purchase_1 = create(:purchase, purchaser: @purchaser, link: create(:product, user: seller_1, name: "Profit & Loss"))
        purchase_2 = create(:purchase, purchaser: @purchaser, link: create(:product, user: seller_2))
        purchase_3 = create(:purchase, purchaser: @purchaser, link: create(:product, user: seller_2, description: "classic"))
        index_model_records(Purchase)

        get :search, params: @params.merge(q: "daniel")
        expect(response).to match_json_schema("api/mobile/purchases")
        expect(response.parsed_body).to include(success: true, user_id: @purchaser.external_id)
        expect(response.parsed_body[:purchases].size).to eq(1)
        expect(response.parsed_body[:purchases][0][:purchase_id]).to eq(purchase_1.external_id)

        get :search, params: @params.merge(q: "profit")
        expect(response.parsed_body[:purchases].size).to eq(1)
        expect(response.parsed_body[:purchases][0][:purchase_id]).to eq(purchase_1.external_id)

        get :search, params: @params.merge(q: "julia")
        expect(response.parsed_body[:purchases].size).to eq(2)
        expect(response.parsed_body[:purchases][0][:purchase_id]).to eq(purchase_3.external_id)
        expect(response.parsed_body[:purchases][1][:purchase_id]).to eq(purchase_2.external_id)

        get :search, params: @params.merge(q: "classic")
        expect(response.parsed_body[:purchases].size).to eq(1)
        expect(response.parsed_body[:purchases][0][:purchase_id]).to eq(purchase_3.external_id)
      end
    end

    describe "ordering" do
      it "returns purchases for a given user sorted by the requested order" do
        purchase_1 = create(:purchase, purchaser: @purchaser, link: create(:product, name: "money money money cash"))
        purchase_2 = create(:purchase, purchaser: @purchaser, link: create(:product, name: "money cash cash cash"))
        index_model_records(Purchase)

        # by default, the score is the most important
        get :search, params: @params.merge(q: "money")
        expect(response).to match_json_schema("api/mobile/purchases")
        expect(response.parsed_body).to include(success: true, user_id: @purchaser.external_id)
        expect(response.parsed_body[:purchases][0][:purchase_id]).to eq(purchase_1.external_id)
        expect(response.parsed_body[:purchases][1][:purchase_id]).to eq(purchase_2.external_id)

        get :search, params: @params.merge(q: "cash")
        expect(response).to match_json_schema("api/mobile/purchases")
        expect(response.parsed_body).to include(success: true, user_id: @purchaser.external_id)
        expect(response.parsed_body[:purchases][0][:purchase_id]).to eq(purchase_2.external_id)
        expect(response.parsed_body[:purchases][1][:purchase_id]).to eq(purchase_1.external_id)

        # specifically setting a date order works
        get :search, params: @params.merge(order: "date-asc")
        expect(response).to match_json_schema("api/mobile/purchases")
        expect(response.parsed_body).to include(success: true, user_id: @purchaser.external_id)
        expect(response.parsed_body[:purchases][0][:purchase_id]).to eq(purchase_1.external_id)
        expect(response.parsed_body[:purchases][1][:purchase_id]).to eq(purchase_2.external_id)

        get :search, params: @params.merge(order: "date-desc")
        expect(response).to match_json_schema("api/mobile/purchases")
        expect(response.parsed_body).to include(success: true, user_id: @purchaser.external_id)
        expect(response.parsed_body[:purchases][0][:purchase_id]).to eq(purchase_2.external_id)
        expect(response.parsed_body[:purchases][1][:purchase_id]).to eq(purchase_1.external_id)
      end
    end

    it_behaves_like "a paginated API" do
      before do
        @action = :search
        @response_key_name = "purchases"
        @records = create_list(:purchase, 2, purchaser: @purchaser)
        index_model_records(Purchase)
      end
    end
  end
end
