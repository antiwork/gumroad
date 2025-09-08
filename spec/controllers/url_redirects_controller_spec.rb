# frozen_string_literal: true

require "spec_helper"

describe UrlRedirectsController do
  render_views

  before do
    @product = create(:product_with_pdf_file)
    @url_redirect = create(:url_redirect, purchase: create(:purchase, email: "abCabC@abc.com", link: @product))
    @token = @url_redirect.token
    @url = @url_redirect.referenced_link.product_files.alive.first.url
  end

  describe "GET 'download_page'" do
    before do
      # TODO: Uncomment after removing the :custom_domain_download feature flag (curtiseinsmann)
      # @request.host = URI.parse(@product.user.subdomain_with_protocol).host
    end

    it "adds X-Robots-Tag response header to avoid page indexing" do
      get :download_page, params: { id: @token }
      expect(response.headers["X-Robots-Tag"]).to eq("noindex")
    end

    it "renders correctly" do
      get :download_page, params: { id: @token }
      expect(response).to be_successful
      expect(assigns(:hide_layouts)).to eq(true)
      expect(
        assigns(:react_component_props)
      ).to eq(
        UrlRedirectPresenter.new(
          url_redirect: @url_redirect,
          logged_in_user: nil
        ).download_page_with_content_props.merge(
          is_mobile_app_web_view: false,
          content_unavailability_reason_code: nil,
          add_to_library_option: "signup_form"
        )
      )
    end

    context "with access revoked for purchase" do
      before do
        @url_redirect.purchase.update!(is_access_revoked: true)
      end

      it "redirects to expired page" do
        expect do
          get :download_page, params: { id: @token }
        end.not_to change(ConsumptionEvent, :count)

        expect(response).to redirect_to(url_redirect_expired_page_path(id: @url_redirect.token))
      end
    end

    it "creates consumption event" do
      expect do
        get :download_page, params: { id: @token }
      end.to change(ConsumptionEvent, :count).by(1)

      expect(response).to be_successful
      event = ConsumptionEvent.last
      expect(event.event_type).to eq(ConsumptionEvent::EVENT_TYPE_VIEW)
      expect(event.product_file_id).to be_nil
      expect(event.url_redirect_id).to eq @url_redirect.id
      expect(event.purchase_id).not_to be_nil
      expect(event.link_id).to eq @product.id
      expect(event.platform).to eq Platform::WEB
    end

    context "when mobile view param is passed" do
      it "renders correctly" do
        get :download_page, params: { id: @token, display: "mobile_app" }
        expect(response).to be_successful
        expect(assigns(:react_component_props)[:is_mobile_app_web_view]).to eq(true)

        assert_select "h1", { text: @product.name, count: 0 }
        assert_select "h4", { text: "Liked it? Give it a rating:", count: 0 }
        assert_select "h4", { text: "Display Name", count: 1 }
        assert_select "a", { text: "Download", count: 1 }
      end
    end

    describe "licenses" do
      before do
        @seller = create(:user)
        @product = create(:product, user: @seller, is_licensed: true)
        @purchase = create(:purchase, link: @product, price_cents: 100, license: create(:license))
        @url_redirect = create(:url_redirect, purchase: @purchase)
        @token = @url_redirect.token
      end

      it "displays the license key for the purchase" do
        get :download_page, params: { id: @token }
        expect(response.body).to include @purchase.license.serial
      end
    end

    context "posts" do
      let(:url_redirect) { create(:url_redirect, purchase:) }
      let(:token) { url_redirect.token }
      let(:subject) { assigns(:react_component_props).dig(:content, :posts) }

      context "for products" do
        let(:seller) { create(:named_seller) }
        let(:user) { create(:user) }
        let(:product) { create(:product, user: seller, is_licensed: true) }
        let(:purchase) { create(:purchase, purchaser: user, email: user.email, link: product, price_cents: 100, license: create(:license)) }
        let(:installment_1) { create(:installment, link: purchase.link, published_at: Time.current) }

        before do
          create(:creator_contacting_customers_email_info, purchase:, installment: installment_1)
        end

        it "returns updates from that purchase" do
          get :download_page, params: { id: token }

          expect(response).to be_successful
          expect(response.body).to include(installment_1.displayed_name)
        end

        it "returns updates from those other purchases if they've bought the same product multiple times" do
          purchase_2 = create(:purchase, purchaser: user, email: user.email, link: purchase.link)
          installment_2 = create(:installment, link: purchase.link, published_at: Time.current)
          create(:creator_contacting_customers_email_info, purchase: purchase_2, installment: installment_2)

          purchase_3 = create(:purchase, purchaser: user, email: user.email, link: purchase.link)
          installment_3 = create(:installment, link: purchase.link, published_at: Time.current)
          create(:creator_contacting_customers_email_info, purchase: purchase_3, installment: installment_3)

          sign_in user
          get :download_page, params: { id: token }

          expect(response).to be_successful
          expect(response.body).to include(installment_1.displayed_name)
          expect(response.body).to include(installment_2.displayed_name)
          expect(response.body).to include(installment_3.displayed_name)
        end

        it "does not break if the user has been sent a post for a product they have not purchased" do
          # this should not occur, but has in the past
          installment_2 = create(:installment, published_at: Time.current)
          create(:creator_contacting_customers_email_info, purchase:, installment: installment_2)

          get :download_page, params: { id: token }

          expect(response).to be_successful
        end

        shared_examples "not returns post" do
          let(:installment_2) { create(:installment, link: product, published_at: Time.current) }
          before do
            create(:creator_contacting_customers_email_info, purchase: purchase_1, installment: installment_2)
          end

          it "does not return posts" do
            get :download_page, params: { id: token }
            expect(subject).to match_array(a_hash_including(name: installment_1.name))
          end
        end

        shared_examples "returns post" do
          let(:installment_2) { create(:installment, link: product, published_at: Time.current) }
          before do
            create(:creator_contacting_customers_email_info, purchase: purchase_1, installment: installment_2)
          end

          it "does return posts" do
            get :download_page, params: { id: token }
            expect(subject).to match_array(
              [
                a_hash_including(name: installment_1.name),
                a_hash_including(name: installment_2.name)
              ]
            )
          end
        end

        context "for not purchased products" do
          let(:purchase_1) { create(:purchase, link: product) }

          include_examples "not returns post"
        end

        context "for a failed product purchase" do
          let(:purchase_1) { create(:failed_purchase, purchaser: user, email: user.email, link: product) }

          include_examples "not returns post"
        end

        context "for a fully refunded product purchase" do
          let(:purchase_1) { create(:refunded_purchase, purchaser: user, email: user.email, link: product) }

          include_examples "not returns post"
        end

        context "for a chargedback product purchase" do
          let(:purchase_1) { create(:purchase, purchaser: user, email: user.email, link: product, chargeback_date: Time.current) }

          include_examples "not returns post"
        end

        context "for a gift sent purchase" do
          let(:purchase_1) { create(:purchase, purchaser: user, email: user.email, link: product, is_gift_sender_purchase: true) }

          include_examples "not returns post"
        end

        context "for a chargedback reversed purchase" do
          let(:purchase_1) { create(:purchase, purchaser: user, email: user.email, link: product, chargeback_date: Time.current, chargeback_reversed: true) }

          include_examples "returns post"
        end

        context "for a partially refunded purchase" do
          let(:purchase_1) { create(:purchase, purchaser: user, email: user.email, link: product, stripe_partially_refunded: true) }

          include_examples "returns post"
        end

        context "for a test purchase" do
          let(:purchase_1) { create(:test_purchase, purchaser: user, email: user.email, link: product) }

          include_examples "returns post"
        end

        context "for a received gift purchase" do
          let(:purchase_1) { create(:purchase, purchaser: user, email: user.email, link: product, is_gift_receiver_purchase: true) }

          include_examples "returns post"
        end
      end

      context "for subscriptions", :vcr do
        let(:product) { create(:subscription_product) }
        let(:subscription) { create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: product) }
        let(:purchase) do create(:purchase, link: product, email: subscription.user.email,
                                            is_original_subscription_purchase: true,
                                            subscription:, created_at: 2.days.ago) end
        let(:installment) { create(:installment, link: purchase.link, published_at: 1.day.ago) }

        before do
          create(:creator_contacting_customers_email_info_sent, purchase:, installment:, sent_at: 1.hour.ago)
        end

        it "returns posts" do
          get :download_page, params: { id: token }
          expect(subject).to match_array(a_hash_including(name: installment.name))
        end

        context "when it is deactivated" do
          let(:subscription) { create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: product, deactivated_at: Time.current) }

          context "and access is blocked on cancellation" do
            let(:product) { create(:subscription_product, block_access_after_membership_cancellation: true) }

            it "does not return posts" do
              get :download_page, params: { id: token }
              expect(subject).to be_empty
            end
          end

          context "when access not blocked on cancellation" do
            let(:product) { create(:subscription_product, block_access_after_membership_cancellation: false) }

            it "does return posts" do
              get :download_page, params: { id: token }
              expect(subject).to match_array(a_hash_including(name: installment.name))
            end
          end
        end
      end

      context "with a bundle purchase" do
        let(:purchase) { create(:purchase, link: create(:product, :bundle), is_bundle_purchase: true) }

        before do
          purchase.create_url_redirect!
        end

        it "redirects to the library page without creating consumption event" do
          expect do
            get :download_page, params: { id: purchase.url_redirect.token }
          end.not_to change(ConsumptionEvent, :count)
          expect(response).to redirect_to(library_url({ bundles: purchase.link.external_id }))
        end

        context "when the url_redirect doesn't belong to a product" do
          before do
            # This seems to be the case for (some) purchases that have is_bundle_purchase set to true
            # Production UrlRedirect record for reference: 314046200
            purchase.url_redirect.update!(link: nil)
          end

          it "redirects to the library page" do
            expect do
              get :download_page, params: { id: purchase.url_redirect.token }
            end.not_to change(ConsumptionEvent, :count)
            expect(response).to redirect_to(library_url({ bundles: purchase.link.external_id }))
          end
        end

        context "when the receipt parameter is present" do
          it "includes the purchase_id parameter when redirecting" do
            get :download_page, params: { id: purchase.url_redirect.token, receipt: true }
            expect(response).to redirect_to(library_url({ bundles: purchase.link.external_id, purchase_id: purchase.external_id }))
          end
        end
      end
    end

    describe "when user is signed in" do
      before do
        @user = create(:user, email: @url_redirect.purchase.email)
        sign_in @user
      end

      describe "with purchase purchaser is nil" do
        it "renders add to library" do
          get :download_page, params: { id: @token }
          expect(response.body).to include "Add to library"
        end
      end

      describe "with purchase purchaser set to signed in user" do
        before do
          @url_redirect.purchase.purchaser = @user
          @url_redirect.purchase.save!
        end

        it "does not render add to library" do
          get :download_page, params: { id: @token }
          expect(response.body).to_not include "Add to library"
        end
      end

      it "redirects to check purchaser if signed in user is not purchaser" do
        @url_redirect.purchase.purchaser = create(:user)
        @url_redirect.purchase.save!
        get :download_page, params: { id: @token }
        expect(response).to redirect_to "#{url_redirect_check_purchaser_path(@url_redirect.token)}?next=#{CGI.escape request.path}"
      end
    end

    describe "when user does not exist with purchase email" do
      it "renders signup form" do
        get :download_page, params: { id: @token }
        expect(response.body).to_not include "Access this product from anywhere, forever:"
        expect(response.body).to include "Create an account to access all of your purchases"
      end
    end

    it "increments the view count on the url_redirect" do
      expect { get :download_page, params: { id: @token } }.to change {
        @url_redirect.reload.uses
      }.by(1)
    end

    describe "installments" do
      before do
        @seller = create(:user)
        @product = create(:product, user: @seller)
        @seller_installment = create(:installment, seller: @seller, installment_type: "seller", link: nil)
        @seller_installment.product_files.create!(url: "https://s3.amazonaws.com/gumroad-specs/specs/magic.mp3")
        @url_redirect = create(:url_redirect, installment: @seller_installment, purchase: nil, link: @product)
        @token = @url_redirect.token
        allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)
        travel_to(Time.current)
      end

      it "renders the download page properly for a product installment with files" do
        get :download_page, params: { id: @token }
        expect(response.body).to include url_redirect_download_product_files_path(@url_redirect.token, { product_file_ids: [ProductFile.last.external_id] })
        expect(response.body).to_not have_selector(".product-related .preview-container")
      end

      it "renders the download page properly for a variant installment with files" do
        category = create(:variant_category, link: @product, title: "Color")
        variant = create(:variant, variant_category: category, name: "Blue")
        @url_redirect.update(link: @product)
        @seller_installment.update!(installment_type: Installment::VARIANT_TYPE, base_variant_id: variant.id)

        get :download_page, params: { id: @token }
        expect(response.body).to include url_redirect_download_product_files_path(@url_redirect.token, { product_file_ids: [ProductFile.last.external_id] })
        expect(response.body).to_not have_selector(".product-related .preview-container")
      end

      it "renders the download page properly for a follower installment with files" do
        @seller_installment.update!(installment_type: Installment::FOLLOWER_TYPE)

        get :download_page, params: { id: @token }
        expect(response.body).to include url_redirect_download_product_files_path(@url_redirect.token, { product_file_ids: [ProductFile.last.external_id] })
        expect(response.body).to_not have_selector(".product-related .preview-container")
      end

      it "renders the download page properly for an affiliate installment with files" do
        @seller_installment.update!(installment_type: Installment::AFFILIATE_TYPE)

        get :download_page, params: { id: @token }
        expect(response.body).to include url_redirect_download_product_files_path(@url_redirect.token, { product_file_ids: [ProductFile.last.external_id] })
        expect(response.body).to_not have_selector(".product-related .preview-container")
      end

      it "renders the download page properly for an audience installment with files" do
        @seller_installment.update!(installment_type: Installment::AUDIENCE_TYPE)

        get :download_page, params: { id: @token }
        expect(response.body).to include url_redirect_download_product_files_path(@url_redirect.token, { product_file_ids: [ProductFile.last.external_id] })
        expect(response.body).to_not have_selector(".product-related .preview-container")
      end

      it "renders the download page properly for a membership installment that used to have files and now does not" do
        @product.update!(is_recurring_billing: true)
        @url_redirect.update!(link: @product)
        @seller_installment.product_files.last.mark_deleted!

        get :download_page, params: { id: @token }
        expect(response.body).to include url_redirect_download_page_path(@token)
        expect(response.body).to_not have_selector(".product-related .preview-container")
      end

      it "returns a 404 if the url redirect is not found" do
        expect do
          get :download_page, params: { id: "some non-existent id" }
        end.to raise_error(ActionController::RoutingError)
      end

      it "returns 404 if the url redirect is for a membership installment that is now deleted" do
        @product.update!(is_recurring_billing: true)
        @url_redirect.update!(link: @product)
        @seller_installment.mark_deleted!

        expect do
          get :download_page, params: { id: @token }
        end.to raise_error(ActionController::RoutingError)
      end

      it "returns 404 if the url redirect is for a creator (not product) installment that is now deleted" do
        @seller_installment.mark_deleted!
        expect do
          get :download_page, params: { id: @token }
        end.to raise_error(ActionController::RoutingError)
      end

      it "404s if the url redirect is for a creator (not product) installment that used to have files and now does not" do
        @seller_installment.product_files.last.mark_deleted
        expect do
          get :download_page, params: { id: @token }
        end.to raise_error(ActionController::RoutingError)
      end

      it "renders the download page properly for a product installment without files that was purchased" do
        @url_redirect.update(link: @product, purchase: create(:purchase, link: @product))
        @seller_installment.product_files.last.mark_deleted
        @seller_installment.update!(installment_type: Installment::PRODUCT_TYPE, link: @product)

        get :download_page, params: { id: @token }
        expect(response.body).to include url_redirect_download_page_path(@token)
        expect(response.body).to_not have_selector(".product-related .preview-container")
      end

      it "renders the download page properly for a variant installment without files that was purchased" do
        category = create(:variant_category, link: @product, title: "Color")
        variant = create(:variant, variant_category: category, name: "Blue")
        @url_redirect.update(link: @product, purchase: create(:purchase, link: @product))
        @seller_installment.product_files.last.mark_deleted
        @seller_installment.update!(installment_type: Installment::VARIANT_TYPE, base_variant_id: variant.id)

        get :download_page, params: { id: @token }
        expect(response.body).to include url_redirect_download_page_path(@token)
        expect(response.body).to_not have_selector(".product-related .preview-container")
      end

      it "returns 404 error if the url redirect is for a product installment without files and was not purchased" do
        @url_redirect.update(link: @product)
        @seller_installment.product_files.last.mark_deleted
        @seller_installment.update!(installment_type: Installment::PRODUCT_TYPE)

        expect do
          get :download_page, params: { id: @token }
        end.to raise_error(ActionController::RoutingError)
      end

      it "returns 404 error if the url redirect is for a variant installment without files and was not purchased" do
        category = create(:variant_category, link: @product, title: "Color")
        variant = create(:variant, variant_category: category, name: "Blue")
        @url_redirect.update(link: @product)
        @seller_installment.product_files.last.mark_deleted
        @seller_installment.update!(installment_type: Installment::VARIANT_TYPE, base_variant_id: variant.id)

        expect do
          get :download_page, params: { id: @token }
        end.to raise_error(ActionController::RoutingError)
      end

      it "returns 404 error if the url redirect is for a follower installment without files" do
        @seller_installment.product_files.last.mark_deleted
        @seller_installment.update!(installment_type: Installment::FOLLOWER_TYPE)

        expect do
          get :download_page, params: { id: @token }
        end.to raise_error(ActionController::RoutingError)
      end

      it "returns 404 error if the url redirect is for an affiliate installment without files" do
        @seller_installment.product_files.last.mark_deleted
        @seller_installment.update!(installment_type: Installment::AFFILIATE_TYPE)

        expect do
          get :download_page, params: { id: @token }
        end.to raise_error(ActionController::RoutingError)
      end

      it "returns 404 error if the url redirect is for an audience installment without files" do
        @seller_installment.product_files.last.mark_deleted
        @seller_installment.update!(installment_type: Installment::AUDIENCE_TYPE)

        expect do
          get :download_page, params: { id: @token }
        end.to raise_error(ActionController::RoutingError)
      end

      it "returns 404 error if the url redirect is for a physical product installment that used to have files and now does not" do
        @product.is_physical = true
        # bypassing physical product validations.
        @product.update_column(:flags, @product.flags)
        @seller_installment.link = @product
        @seller_installment.save!
        @seller_installment.product_files.last.mark_deleted
        expect do
          get :download_page, params: { id: @token }
        end.to raise_error(ActionController::RoutingError)
      end
    end

    describe "streaming" do
      before do
        @product = create(:product_with_video_file)
        @url_redirect = create(:url_redirect, link: @product, purchase: nil)
      end

      it "only increments uses once" do
        expect { get :download_page, params: { id: @url_redirect.token } }.to change {
          @url_redirect.reload.uses
        }.by(1)
      end

      it "redirects to the expiration page if the rental has expired" do
        @url_redirect.update(is_rental: true, rental_first_viewed_at: 10.days.ago)
        @url_redirect.purchase = create(:purchase, is_rental: true)
        @url_redirect.save!
        ExpireRentalPurchasesWorker.new.perform
        get :stream, params: { id: @url_redirect.token }
        expect(response).to redirect_to(url_redirect_rental_expired_page_path(id: @url_redirect.token))
      end

      context "when 'product_file_id' is missing from the params" do
        before do
          @product.product_files << create(:product_file, link: @product)
          stub_const("UrlRedirect::GUID_GETTER_FROM_S3_URL_REGEX", /(specs)/)
        end

        it "assigns the first streamable product file to '@product_file' and renders the stream page correctly" do
          get :stream, params: { id: @url_redirect.token }

          expect(response).to have_http_status(:ok)
          expect(assigns(:product_file)).to eq(@product.product_files.first)
        end
      end

      context "when there are no streamable files" do
        before do
          @product.product_files.each(&:mark_deleted!)
        end

        it "raises 404 error" do
          expect do
            get :stream, params: { id: @url_redirect.token, product_file_id: @product.product_files.first.external_id }
          end.to raise_error(ActionController::RoutingError)
        end
      end

      it "creates consumption event" do
        @url_redirect.update!(purchase: create(:purchase, link: @product))
        expect do
          get :download_page, params: { id: @url_redirect.token }
        end.to change(ConsumptionEvent, :count).by(1)

        expect(response).to be_successful
        event = ConsumptionEvent.last
        expect(event.event_type).to eq(ConsumptionEvent::EVENT_TYPE_VIEW)
        expect(event.product_file_id).to be_nil
        expect(event.url_redirect_id).to eq @url_redirect.id
        expect(event.purchase_id).not_to be_nil
        expect(event.link_id).to eq @product.id
        expect(event.platform).to eq Platform::WEB
      end
    end

    describe "memberships" do
      it "redirects to the expiration page if the membership inactive" do
        product = create(:membership_product, price_cents: 100)
        subscription = create(:subscription, link: product, user: create(:user), failed_at: Time.current)
        purchase = create(:purchase, price_cents: 100, purchaser: subscription.user, link: product, subscription:, is_original_subscription_purchase: true)
        product.update_attribute(:block_access_after_membership_cancellation, true)
        url_redirect = create(:url_redirect, link: product, purchase:)

        sign_in subscription.user
        get :download_page, params: { id: url_redirect.token }
        expect(response).to redirect_to(url_redirect_membership_inactive_page_path(id: url_redirect.token))
      end

      it "does not redirect to login page if no user signed in" do
        product = create(:subscription_product, price_cents: 100)
        subscription = create(:subscription, link: product, user: create(:user), failed_at: Time.current)
        purchase = create(:purchase, price_cents: 100, purchaser: subscription.user, link: product, subscription:, is_original_subscription_purchase: true)
        product.update_attribute(:block_access_after_membership_cancellation, true)
        url_redirect = create(:url_redirect, link: product, purchase:)

        get :download_page, params: { id: url_redirect.token }
        expect(response).to_not redirect_to(login_url(next: request.path))
      end
    end

    describe "needs to be confirmed" do
      before do
        @url_redirect = create(:url_redirect, uses: 1, has_been_seen: true, purchase: create(:purchase, email: "abCabC@abc.com"))
        cookies.encrypted[:confirmed_redirect] = nil
        @request.remote_ip = "123.4.5.6"
      end

      it "redirects to confirm page with correct parameters" do
        get :download_page, params: { id: @url_redirect.token, display: "mobile_app" }
        expect(response).to redirect_to(confirm_page_path(id: @url_redirect.token, destination: "download_page", display: "mobile_app"))
      end
    end

    describe "coffee product" do
      let(:url_redirect) { create(:url_redirect, purchase: create(:purchase, link: create(:coffee_product))) }

      it "redirects to the coffee page and forwards the purchase_email parameter" do
        get :download_page, params: { id: url_redirect.token, purchase_email: "test@gumroad.com" }

        expect(response).to redirect_to(custom_domain_coffee_url(host: url_redirect.seller.subdomain_with_protocol, purchase_email: "test@gumroad.com"))
      end
    end
  end

  describe "GET download_archive" do
    it "redirects to the download URL for the requested installment archive when the format is HTML" do
      installment = create(:follower_installment, seller: create(:follower, follower_user_id: create(:user).id).user)
      token = create(:installment_url_redirect, installment:).token
      archive = installment.product_files_archives.new(product_files_archive_state: "ready")
      archive.set_url_if_not_present
      archive.save!

      allow(controller).to(
        receive(:signed_download_url_for_s3_key_and_filename)
          .with(archive.s3_key, archive.s3_filename)
          .and_return("https://example.com/the-entity-zip-url"))

      get :download_archive, format: :html, params: { id: token }

      expect(response).to redirect_to("https://example.com/the-entity-zip-url")
      expect(ConsumptionEvent.where(event_type: ConsumptionEvent::EVENT_TYPE_DOWNLOAD_ALL).count).to eq(1)
    end

    it "returns the download URL for the requested folder archive" do
      folder_id = SecureRandom.uuid
      folder_archive = @url_redirect.product_files_archives.new(folder_id:, product_files_archive_state: "ready")
      folder_archive.set_url_if_not_present
      folder_archive.save!

      get :download_archive, format: :json, params: { id: @token, folder_id: }

      expect(response).to have_http_status(:success)
      expect(response.parsed_body["url"]).to eq(url_redirect_download_archive_url(@token, folder_id:))
    end

    it "returns nil if the folder archive is not ready" do
      folder_id = SecureRandom.uuid
      folder_archive = @url_redirect.product_files_archives.new(folder_id:, product_files_archive_state: "queueing")
      folder_archive.set_url_if_not_present
      folder_archive.save!

      get :download_archive, format: :json, params: { id: @token, folder_id: }

      expect(response).to have_http_status(:success)
      expect(response.parsed_body["url"]).to be_nil
    end

    it "redirects to the download URL for the requested entity archive when the format is HTML" do
      entity_archive = @url_redirect.product_files_archives.new(product_files_archive_state: "ready")
      entity_archive.set_url_if_not_present
      entity_archive.save!

      allow(controller).to(
        receive(:signed_download_url_for_s3_key_and_filename)
          .with(entity_archive.s3_key, entity_archive.s3_filename)
          .and_return("https://example.com/the-entity-zip-url"))

      get :download_archive, format: :html, params: { id: @token }

      expect(response).to redirect_to("https://example.com/the-entity-zip-url")
      expect(ConsumptionEvent.where(event_type: ConsumptionEvent::EVENT_TYPE_DOWNLOAD_ALL).count).to eq(1)
      expect(ConsumptionEvent.where(event_type: ConsumptionEvent::EVENT_TYPE_FOLDER_DOWNLOAD).count).to eq(0)
    end

    it "redirects to the download URL for the requested folder archive when the format is HTML" do
      folder_id = SecureRandom.uuid
      folder_archive = @url_redirect.product_files_archives.new(folder_id:, product_files_archive_state: "ready")
      folder_archive.set_url_if_not_present
      folder_archive.save!

      allow(controller).to(
        receive(:signed_download_url_for_s3_key_and_filename)
          .with(folder_archive.s3_key, folder_archive.s3_filename)
          .and_return("https://example.com/the-folder-zip-url"))

      get :download_archive, format: :html, params: { id: @token, folder_id: }

      expect(response).to redirect_to("https://example.com/the-folder-zip-url")
      expect(ConsumptionEvent.where(event_type: ConsumptionEvent::EVENT_TYPE_DOWNLOAD_ALL).count).to eq(0)

      folder_events = ConsumptionEvent.where(event_type: ConsumptionEvent::EVENT_TYPE_FOLDER_DOWNLOAD)
      expect(folder_events.count).to eq(1)
      expect(folder_events.first.folder_id).to eq(folder_id)
    end
  end

  describe "GET download_product_files" do
    before do
      @product = create(:product, user: create(:user))
      @token = create(:url_redirect, purchase: create(:purchase, link: @product)).token
    end

    it "returns a 404 if no files exist" do
      expect { get :download_product_files, format: :json, params: { product_file_ids: [], id: @token } }.to raise_error(ActionController::RoutingError)
      expect { get :download_product_files, format: :json, params: { product_file_ids: ["non-existent"], id: @token } }.to raise_error(ActionController::RoutingError)
    end

    it "returns the file download info for all requested files" do
      file1 = create(:readable_document, link: @product, display_name: "file1")
      file2 = create(:streamable_video, link: @product, display_name: "file2")
      allow_any_instance_of(UrlRedirect).to receive(:signed_location_for_file).with(file1).and_return("https://example.com/file1.pdf")
      allow_any_instance_of(UrlRedirect).to receive(:signed_location_for_file).with(file2).and_return("https://example.com/file2.pdf")
      get :download_product_files, format: :json, params: { product_file_ids: [file1.external_id, "non-existent-id", file2.external_id], id: @token }

      expect(response).to have_http_status(:success)
      expect(response.parsed_body["files"]).to eq(@product.product_files.map { { "url" => "https://example.com/#{_1.display_name}.pdf", "filename" => _1.s3_filename } })
    end

    it "redirects to the first product file if the format is HTML" do
      file = create(:product_file, link: @product)
      expect_any_instance_of(UrlRedirect).to receive(:signed_location_for_file).with(file).and_return("https://example.com/file.srt")
      get :download_product_files, format: :html, params: { id: @token, product_file_ids: [file.external_id] }

      expect(response).to redirect_to("https://example.com/file.srt")
    end

    context "when a PDF must be stamped and stamped file is missing" do
      it "shows alert, enqueues job (critical, notify=true), and redirects to download page" do
        product_file = create(:readable_document, link: @product, pdf_stamp_enabled: true)
        url_redirect = UrlRedirect.find_by(token: @token)

        StampPdfForPurchaseJob.jobs.clear

        get :download_product_files, format: :html, params: { id: @token, product_file_ids: [product_file.external_id] }

        expect(response).to redirect_to(url_redirect.download_page_url)
        expect(flash[:alert]).to eq("We are preparing the file for download. You will receive an email when it is ready.")
        expect(StampPdfForPurchaseJob).to have_enqueued_sidekiq_job(url_redirect.purchase_id, true).on("critical")
      end
    end
  end

  describe "GET download_subtitle_file" do
    before do
      @product_file = @product.product_files.last
      @subtitle_file = create(:subtitle_file, product_file: @product_file)

      allow_any_instance_of(UrlRedirect).to(
        receive(:signed_download_url_for_s3_key_and_filename)
          .with(@subtitle_file.s3_key, @subtitle_file.s3_filename, is_video: true)
          .and_return("https://example.com/the-subtitle-url"))
    end

    it "redirects to the subtitle file URL" do
      get :download_subtitle_file, params: { id: @token, subtitle_file_id: @subtitle_file.external_id,
                                             product_file_id: @product_file.external_id }

      expect(response).to redirect_to("https://example.com/the-subtitle-url")
    end
  end

  describe "GET 'show'" do
    it "returns http success" do
      get :show, params: { id: @token }

      s3_path = @url.sub("https://s3.amazonaws.com/gumroad-specs", "")
      loc = response.location
      expect(loc.include?(FILE_DOWNLOAD_DISTRIBUTION_URL)).to be(true)
      expect(loc.include?(s3_path)).to be(true)
      expect(loc.include?("verify=")).to be(true)
    end

    it "marks the url_redirect as seen" do
      expect { get :show, params: { id: @url_redirect.token } }.to change { @url_redirect.reload.has_been_seen }.from(false).to(true)
    end

    it "creates consumption event" do
      expect do
        get :show, params: { id: @url_redirect.token }
      end.to change(ConsumptionEvent, :count).by(1)

      event = ConsumptionEvent.last
      expect(event.event_type).to eq(ConsumptionEvent::EVENT_TYPE_DOWNLOAD)
      expect(event.product_file_id).to be_nil
      expect(event.url_redirect_id).to eq @url_redirect.id
      expect(event.purchase_id).to eq @url_redirect.purchase_id
      expect(event.link_id).to eq @url_redirect.purchase.link_id
      expect(event.platform).to eq Platform::WEB
    end

    it "renders confirm if has been seen and no cookie" do
      @url_redirect = create(:url_redirect, uses: 1, has_been_seen: true,
                                            purchase: create(:purchase, email: "abCabC@abc.com", link: create(:product_with_pdf_file)))
      cookies.encrypted[:confirmed_redirect] = nil
      @request.remote_ip = "123.4.5.6"
      get :show, params: { id: @url_redirect.token }
      expect(response).to redirect_to(confirm_page_path(id: @url_redirect.token, destination: "show"))
    end

    it "does not render confirm if has_been_seen is false and no cookie and different ip" do
      @url_redirect = create(:url_redirect, uses: 5, has_been_seen: false,
                                            purchase: create(:purchase, email: "abCabC@abc.com", link: create(:product_with_pdf_file)))
      cookies.encrypted[:confirmed_redirect] = nil
      @request.remote_ip = "123.4.5.6"
      get :show, params: { id: @url_redirect.token }
      expect(response).to_not redirect_to(confirm_page_path(id: @url_redirect.token))
    end

    it "increments uses if purchaser is the same" do
      @user = create(:user)
      @purchase = create(:purchase, purchaser: @user, link: create(:product_with_pdf_file))
      @url_redirect = create(:url_redirect, purchase: @purchase)
      sign_in @user
      expect { get :show, params: { id: @url_redirect.token } }.to change { @url_redirect.reload.uses }.from(0).to(1)
    end

    it "increments uses if ip is the same" do
      @purchase = create(:purchase, ip_address: "123.0.0.1", link: create(:product_with_pdf_file))
      @url_redirect = create(:url_redirect, purchase: @purchase)
      @request.remote_ip = "123.0.0.1"
      expect { get :show, params: { id: @url_redirect.token } }.to change { @url_redirect.reload.uses }.from(0).to(1)
    end

    it "increments the uses if ip_address or purchaser don't match" do
      @purchase = create(:purchase, ip_address: "123.0.0.1", link: create(:product_with_pdf_file))
      @url_redirect = create(:url_redirect, purchase: @purchase)
      @request.remote_ip = "123.4.4.1"
      expect { get :show, params: { id: @url_redirect.token } }.to change { @url_redirect.reload.uses }.from(0).to(1)
    end

    it "404s if url id does not exist" do
      expect do
        get :show, params: { id: "monkey" }
      end.to raise_error(ActionController::RoutingError)
    end

    it "does not ask user to confirm if there is no purchase" do
      url_redirect = create(:url_redirect, purchase: nil, link: create(:product_with_video_file))
      3.times { get :show, params: { id: url_redirect.token } }
      expect(response).to_not render_template(:confirm)
    end

    describe "streaming" do
      it "renders correctly for stream-only files" do
        travel_to(Time.current) do
          @product = create(:product)
          product_file = create(:product_file,
                                url: "https://s3.amazonaws.com/gumroad-specs/attachments/43a5363194e74e9ee75b6203eaea6705/original/test.mp4",
                                filegroup: "video",
                                stream_only: true,
                                width: 1920,
                                height: 1080,
                                bitrate: 3000)
          @product.product_files << product_file
          @url_redirect = create(:url_redirect, link: @product, purchase: nil)
          allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)

          get :show, params: { id: @url_redirect.token }

          expect(response).to redirect_to @url_redirect.signed_location_for_file(@product.product_files.first)
        end
      end

      describe "hls" do
        before do
          @multifile_product = create(:product)
          @video_file_1 = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter2.mp4", is_transcoded_for_hls: true, display_name: "Chapter 2", position: 2)
          @multifile_product.product_files << @video_file_1
          @transcoded_video = create(:transcoded_video, link: @multifile_product, streamable: @video_file_1, original_video_key: @video_file_1.s3_key,
                                                        transcoded_video_key: "attachments/2_1/original/chapter2/hls/index.m3u8", is_hls: true,
                                                        state: "completed")
          @multifile_url_redirect = create(:url_redirect, link: @multifile_product, purchase: nil)
          allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)
        end

        it "sets the m3u8 playlist url and the original video url in sources for hls-transcoded video" do
          get :stream, params: { id: @multifile_url_redirect.token, product_file_id: @video_file_1.external_id }
          video_urls = assigns(:videos_playlist)[:playlist]

          expect(response).to be_successful
          expect(assigns(:hide_layouts)).to eq(true)
          expect(video_urls.size).to eq 1
          expect(video_urls[0][:sources][0]).to include "index.m3u8"
          expect(video_urls[0][:sources][1]).to include @video_file_1.s3_filename
          expect(assigns(:videos_playlist)[:index_to_play]).to eq 0
        end

        it "sets the smil url and the original video url in sources if the video is not HLS-transcoded yet" do
          @video_file_1.update(is_transcoded_for_hls: false)
          get :stream, params: { id: @multifile_url_redirect.token }
          video_urls = assigns(:videos_playlist)[:playlist]

          expect(response).to be_successful
          expect(assigns(:hide_layouts)).to eq(true)
          expect(video_urls.size).to eq 1
          expect(video_urls[0][:sources][0]).to include "stream.smil"
          expect(video_urls[0][:sources][1]).to include @video_file_1.s3_filename
          expect(assigns(:videos_playlist)[:index_to_play]).to eq 0
        end

        context "when the product has rich content" do
          it "sets the correct source urls for all video files in the product and returns the index of the file that should be played on load" do
            pdf_file = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachment/manual.pdf")
            video_file_2 = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4", position: 2)
            subtitle_file_en = create(:subtitle_file, language: "English", url: "https://s3.amazonaws.com/gumroad-specs/attachment/english.srt", product_file: video_file_2)
            subtitle_file_es = create(:subtitle_file, language: "Spanish", url: "https://s3.amazonaws.com/gumroad-specs/attachment/spanish.srt", product_file: video_file_2)
            video_file_3 = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter3.mp4", position: 1)
            @multifile_product.product_files << pdf_file
            @multifile_product.product_files << video_file_2
            @multifile_product.product_files << video_file_3
            create(:product_rich_content, entity: @multifile_product, description: [
                     { "type" => "fileEmbed", "attrs" => { "id" => video_file_2.external_id, "uid" => SecureRandom.uuid } },
                     { "type" => "fileEmbed", "attrs" => { "id" => @video_file_1.external_id, "uid" => SecureRandom.uuid } },
                     { "type" => "fileEmbed", "attrs" => { "id" => video_file_3.external_id, "uid" => SecureRandom.uuid } }
                   ])

            get :stream, params: { id: @multifile_url_redirect.token, product_file_id: video_file_2.external_id }

            video_urls = assigns(:videos_playlist)[:playlist]
            expect(response).to be_successful
            expect(video_urls.size).to eq 3
            expect(video_urls[0][:sources][0]).to include "stream.smil"
            expect(video_urls[0][:sources][1]).to include video_file_2.s3_filename
            expect(video_urls[0][:title]).to eq video_file_2.s3_display_name
            expect(video_urls[0][:tracks].size).to eq 2
            expect(video_urls[0][:tracks][0][:label]).to eq subtitle_file_en.language
            expect(video_urls[0][:tracks][1][:label]).to eq subtitle_file_es.language
            expect(video_urls[1][:sources][0]).to include "index.m3u8"
            expect(video_urls[1][:sources][1]).to include @video_file_1.s3_filename
            expect(video_urls[1][:title]).to eq @video_file_1.display_name
            expect(video_urls[2][:sources][0]).to include "stream.smil"
            expect(video_urls[2][:sources][1]).to include video_file_3.s3_filename
            expect(video_urls[2][:title]).to eq "chapter3"
            expect(assigns(:videos_playlist)[:index_to_play]).to eq 0
          end
        end

        it "sets the correct source urls for all video attachments of an installment and returns the index of the file that should be played on load" do
          pdf_file = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachment/manual.pdf")
          video_file_1 = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter2.mp4", is_transcoded_for_hls: true, display_name: "Chapter 2", position: 2)
          video_file_2 = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4", position: 1)
          subtitle_file_en = create(:subtitle_file, language: "English", url: "https://s3.amazonaws.com/gumroad-specs/attachment/english.srt", product_file: video_file_2)
          subtitle_file_fr = create(:subtitle_file, language: "Français", url: "https://s3.amazonaws.com/gumroad-specs/attachment/french.srt", product_file: video_file_2)
          video_file_3 = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter_2_no_spaces.mp4", display_name: "Chapter 2 No Spaces", position: 0)
          mp3_file = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/specs/magic.mp3")
          installment = create(:installment)
          installment.product_files << video_file_1 << video_file_2 << pdf_file << video_file_3 << mp3_file
          url_redirect = create(:installment_url_redirect, installment:)
          get :stream, params: { id: url_redirect.token, product_file_id: video_file_3.external_id }
          video_urls = assigns(:videos_playlist)[:playlist]
          expect(response).to be_successful
          expect(assigns(:hide_layouts)).to eq(true)
          expect(video_urls.size).to eq(3)
          expect(video_urls[2][:sources][0]).to include "index.m3u8"
          expect(video_urls[2][:sources][1]).to include video_file_1.s3_filename
          expect(video_urls[2][:title]).to eq video_file_1.display_name
          expect(video_urls[1][:sources][0]).to include "stream.smil"
          expect(video_urls[1][:sources][1]).to include video_file_2.s3_filename
          expect(video_urls[1][:title]).to eq video_file_2.s3_display_name
          expect(video_urls[1][:tracks].size).to eq 2
          expect(video_urls[1][:tracks][0][:label]).to eq subtitle_file_en.language
          expect(video_urls[1][:tracks][1][:label]).to eq subtitle_file_fr.language
          expect(video_urls[0][:sources][0]).to include "stream.smil"
          expect(video_urls[0][:sources][1]).to include video_file_3.s3_filename
          expect(video_urls[0][:title]).to eq video_file_3.display_name
          expect(assigns(:videos_playlist)[:index_to_play]).to eq 0
        end
      end

      describe "GET hls_playlist" do
        before do
          @multifile_product = create(:product)
          @file_1 = create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter2.mp4", is_transcoded_for_hls: true)
          @multifile_product.product_files << @file_1
          @transcoded_video = create(:transcoded_video, link: @multifile_product, streamable: @file_1, original_video_key: @file_1.s3_key,
                                                        transcoded_video_key: "attachments/2_1/original/chapter2/hls/index.m3u8",
                                                        is_hls: true, state: "completed")
          @multifile_url_redirect = create(:url_redirect, link: @multifile_product, purchase: nil)

          s3_new = double("s3_new")
          s3_bucket = double("s3_bucket")
          s3_object = double("s3_object")
          allow(Aws::S3::Resource).to receive(:new).and_return(s3_new)
          allow(s3_new).to receive(:bucket).and_return(s3_bucket)
          allow(s3_bucket).to receive(:object).and_return(s3_object)
          hls = "#EXTM3U\n#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=854x480,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=1191000\nhls_480p_.m3u8\n"
          hls += "#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=1280x720,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=2805000\nhls_720p_.m3u8\n"
          allow(s3_object).to receive(:get).and_return(double(body: double(read: hls)))
        end

        it "replaces the links to the playlists with signed urls" do
          travel_to(Date.parse("2014-01-27")) do
            get :hls_playlist, params: { id: @multifile_url_redirect.token, product_file_id: @file_1.id }
          end
          expect(response).to be_successful
          url = "#EXTM3U\n#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=854x480,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=1191000\n"
          url += "https://d1jmbc8d0c0hid.cloudfront.net/attachments/2_1/original/chapter2/hls/hls_480p_.m3u8?Expires=1390824000&"
          url += "Signature=Bfxuje0vDkMalfNebd5K4rRzZuSCUUP7R3d0LILa1P17fSU7jnd/I7dLrzlF2mQjhP4qO2IJnKnbnp9KfiU76eENu0L0b+Li/CgwWdtGFY4o162TN0TgWacERoaK6krAPlyeit32zoK4Ua5T34plvE7BfUlsrv8OHmr1dE75FEo=&"
          url += "Key-Pair-Id=APKAISH5PKOS7WQUJ6SA\n"
          url += "#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=1280x720,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=2805000\n"
          url += "https://d1jmbc8d0c0hid.cloudfront.net/attachments/2_1/original/chapter2/hls/hls_720p_.m3u8?Expires=1390824000&"
          url += "Signature=WBaT6Vq9r4HQohMAMOGVZuB9GgLa2xd232p9t57qAsvpcC8sCend3xvE9f/CBu/3GPOlVFlBPRLxYXG8xDhBFo2j7YegVyETNiQ5UoUIYyzWh9y5r0LXbplhtiiOEoeAgb+k+X/JSQB/blIrZ7D64AnYzhkfUdsI7gyqSO4+bAM=&"
          url += "Key-Pair-Id=APKAISH5PKOS7WQUJ6SA\n"
          expect(response.body).to eq url
        end

        it "urls encode the playlist urls" do
          @file_1.update_column(:url, "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter 2 of 5 (1280*720).mp4")
          @transcoded_video.update_column(:transcoded_video_key, "attachments/2_1/original/chapter 2 of 5 (1280*720)/hls/index.m3u8")
          travel_to(Date.parse("2014-01-27")) do
            get :hls_playlist, params: { id: @multifile_url_redirect.token, product_file_id: @file_1.id }
          end
          expect(response).to be_successful
          url = "#EXTM3U\n#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=854x480,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=1191000\n"
          url += "https://d1jmbc8d0c0hid.cloudfront.net/attachments/2_1/original/chapter+2+of+5+%281280%2A720%29/hls/hls_480p_.m3u8?Expires=1390824000&"
          url += "Signature=FfsrujMgokLB+hwcLP5Jrtj/t7I3vsOtsqYVqbRj6dwdL5kD4yHCi+x6nqp2h0K2Oc3Pc/vE6Hf6xzDB3GucUTD/c8Omv7YNGhDEaHgRkZF/UeIzQyStiXgFuhJDcV6BF7idGg2B67EV5lWT6Xvb/d80x8lx3+Fh2z0nNhHngf4=&"
          url += "Key-Pair-Id=APKAISH5PKOS7WQUJ6SA\n#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=1280x"
          url += "720,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=2805000\nhttps://d1jmbc8d0c0hid.cloudfront.net/attachments/2_1/original/chapter+2+of+5+"
          url += "%281280%2A720%29/hls/hls_720p_.m3u8?Expires=1390824000&"
          url += "Signature=gIpa3UtEum+imD2joAmK1Oe8qniRoWz0olqh4lLBaKCy0iPz9yTOJKl6hy8NfGw8sHBBzS7LGwazj1vm446eZfEEKERvdtP02B8pt4TfICihx4L2ercnP39OQIe7giLSbbSiw1lFT+GScYYZrTJQEjIbuemEzEBedp4WbUh0U+w=&"
          url += "Key-Pair-Id=APKAISH5PKOS7WQUJ6SA\n"
          expect(response.body).to eq url
        end

        it "escapes RFC 3986 2.2 reserved characters in the file name" do
          @file_1.update_column(:url, "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/me+you.mp4")
          @transcoded_video.update_column(:transcoded_video_key, "attachments/2_1/original/me+you/hls/index.m3u8")
          travel_to(Date.parse("2014-01-27")) do
            get :hls_playlist, params: { id: @multifile_url_redirect.token, product_file_id: @file_1.id }
          end
          expect(response).to be_successful
          file = "#EXTM3U\n#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=854x480,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=1191000\nhttps"
          file += "://d1jmbc8d0c0hid.cloudfront.net/attachments/2_1/original/me%2Byou/hls/hls_480p_.m3u8?Expires=1390824000&Signature="
          file += "wsbm5kN7vYjkVGbk/rn8qdSBZy7D6n4j/uSblT0tjxhj2IfOfoWrH5MnFxjXsDsD5qP0oosVA12dcBOXIa/zUc6hoZq0STKKyVvKY/GOYyMfxO+NzbNu"
          file += "/etWKjsncjbZt4kwEoh6BAPnRJjqBReK722RoTJ/EnPgLSpZGywTnSY=&Key-Pair-Id=APKAISH5PKOS7WQUJ6SA\n#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION"
          file += "=1280x720,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=2805000\nhttps://d1jmbc8d0c0hid.cloudfront.net/attachments/2_1/original/me"
          file += "%2Byou/hls/hls_720p_.m3u8?Expires=1390824000&Signature=gQhfUdJR15hBTYTKwXWIfkAlvAqCMrM9hBpOGHUJF1HSRaf5UeGyBjk4sotsAReT0SrIS8jU"
          file += "zt4SxOR/WPJ3H/Q2fYGEMd1T+f+4jmnEnBn4pQSULdWNO2zyZqP9S3ytaTILZn4OwNHFywRnxAZ6BX0D6Rm4kTuslaHgAlsrI6g=&Key-Pair-Id=APKAISH5PKOS7WQUJ6SA\n"
          expect(response.body).to eq file
        end

        it "sets the rental_first_viewed_at property" do
          @multifile_url_redirect.update!(is_rental: true)
          travel_to(Date.parse("2014-01-27")) do
            get :hls_playlist, params: { id: @multifile_url_redirect.token, product_file_id: @file_1.id }
          end
          expect(response).to be_successful
          expect(@multifile_url_redirect.reload.rental_first_viewed_at).to be_present
        end
      end
    end

    describe "GET smil" do
      let(:product_file) do
        create(
          :product_file,
          url: "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter2.mp4",
          is_transcoded_for_hls: true
        )
      end
      let!(:transcoded_video) do
        create(
          :transcoded_video,
          link: product,
          streamable: product_file,
          original_video_key: product_file.s3_key,
          transcoded_video_key: "attachments/2_1/original/chapter2/hls/index.m3u8",
          is_hls: true,
          state: "completed"
        )
      end
      let(:product) { create(:product, product_files: [product_file]) }
      let(:url_redirect) { create(:url_redirect, link: product, purchase: nil) }

      it "creates consumption event" do
        expect do
          get :smil, params: { id: url_redirect.token, product_file_id: product_file.external_id }
        end.to change(ConsumptionEvent, :count).by(1)
        expect(response).to be_successful

        event = ConsumptionEvent.last
        expect(event.event_type).to eq(ConsumptionEvent::EVENT_TYPE_WATCH)
        expect(event.product_file_id).to eq product_file.id
        expect(event.url_redirect_id).to eq url_redirect.id
        expect(event.purchase_id).to be(nil)
        expect(event.link_id).to eq product.id
        expect(event.platform).to eq Platform::WEB
      end
    end

    describe "multiple files" do
      before do
        @product = create(:product)
        ch1 = "https://s3.amazonaws.com/gumroad-specs/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4"
        ch2 = "https://s3.amazonaws.com/gumroad-specs/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter2.mp4"
        @product.product_files << create(:product_file, url: ch1)
        @product.product_files << create(:product_file, url: ch2)
        @product.save!
        @url_redirect = create(:url_redirect, link: @product, purchase: nil)
        allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)
        # TODO: Uncomment after removing the :custom_domain_download feature flag (curtiseinsmann)
        # @request.host = URI.parse(@product.user.subdomain_with_protocol).host
      end

      it "show the proper download page for multiple files" do
        get :download_page, params: { id: @url_redirect.token }
        expect(response).to be_successful
        expect(response.body).to include "chapter1"
        expect(response.body).to include "chapter2"
      end

      it "redirects to the correct url for downloading a specific file" do
        file = "attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4"
        url = "https://s3.amazonaws.com/gumroad-specs/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4?"
        url += "AWSAccessKeyId=AKIAIKFZLOLAPOKIC6EA&Expires=1386261022&Signature=FxVDOkutrgrGFLWXISp0JroWFLo%3D"
        url += "&response-content-disposition=attachment"
        allow_any_instance_of(UrlRedirect).to receive(:signed_download_url_for_s3_key_and_filename).with(file, "chapter1.mp4", { is_video: true }).and_return(url)
        get :download_product_files, params: { id: @url_redirect.token, product_file_ids: [@product.product_files.first.external_id] }
        expect(response).to redirect_to @url_redirect.signed_location_for_file(@product.product_files.first)
      end

      it "creates the proper consumption event" do
        get :download_product_files, params: { id: @url_redirect.token, product_file_ids: [@product.product_files.first.external_id] }
        expect(ConsumptionEvent.count).to eq 1
        event = ConsumptionEvent.last
        expect(event.product_file_id).to eq @product.product_files.first.id
        expect(event.url_redirect_id).to eq @url_redirect.id
        expect(event.purchase_id).to eq nil
        expect(event.event_type).to eq ConsumptionEvent::EVENT_TYPE_DOWNLOAD
        expect(event.platform).to eq Platform::WEB
      end

      describe "licenses" do
        before do
          @product = create(:product)
          ch1 = "https://s3.amazonaws.com/gumroad-specs/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4"
          ch2 = "https://s3.amazonaws.com/gumroad-specs/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter2.mp4"
          @product.product_files << create(:product_file, url: ch1)
          @product.product_files << create(:product_file, url: ch2)
          @product.is_licensed = true
          @product.save!
          @purchase = create(:purchase, link: @product, price_cents: 100, license: create(:license))
          @url_redirect = create(:url_redirect, link: @product, purchase: @purchase)
          @token = @url_redirect.token
        end

        it "displays license information" do
          get :download_page, params: { id: @url_redirect.token }
          expect(response).to be_successful
          expect(response.body).to include "chapter1"
          expect(response.body).to include "chapter2"
          expect(response.body).to include @purchase.license.serial
        end
      end
    end

    describe "unavailable" do
      describe "chargeback" do
        before do
          @purchase = create(:purchase, chargeback_date: Date.today)
          @url_redirect = create(:url_redirect, purchase: @purchase, link: @purchase.link)
        end

        it "404s" do
          expect do
            get :show, params: { id: @url_redirect.token }
          end.to raise_error(ActionController::RoutingError)
        end
      end

      describe "refund" do
        before do
          @purchase = create(:purchase, chargeback_date: Date.today)
          @url_redirect = create(:url_redirect, purchase: @purchase, link: @purchase.link)
        end

        it "404s" do
          expect do
            get :show, params: { id: @url_redirect.token }
          end.to raise_error(ActionController::RoutingError)
        end
      end
    end

    describe "chargeback reversed" do
      before do
        @purchase = create(:purchase, chargeback_date: Date.today, link: create(:product_with_pdf_file))
        @purchase.chargeback_reversed = true
        @purchase.save!
        @url_redirect = create(:url_redirect, purchase: @purchase, link: @purchase.link)
      end

      it "allows product to be accessed" do
        expect do
          expect do
            get :show, params: { id: @url_redirect.token }
            expect(response.code).to_not eq(404)
          end.to change  { @url_redirect.reload.has_been_seen }.from(false).to(true)
        end.to change { ConsumptionEvent.count }.by(1)
      end
    end
  end

  describe "GET 'confirm_page'" do
    before do
      @url_redirect = create(:url_redirect)
    end

    it "adds X-Robots-Tag response header to avoid page indexing" do
      get :confirm_page, params: { id: @url_redirect.token }
      expect(response.headers["X-Robots-Tag"]).to eq("noindex")
    end


    it "renders the confirm page correctly" do
      get :confirm_page, params: { id: @url_redirect.token }
      expect(response).to be_successful
      expect(assigns(:hide_layouts)).to eq(true)
      expect(assigns(:react_component_props)).to eq(UrlRedirectPresenter.new(url_redirect: @url_redirect, logged_in_user: nil).download_page_without_content_props(content_unavailability_reason_code: UrlRedirectPresenter::CONTENT_UNAVAILABILITY_REASON_CODES[:email_confirmation_required]).merge(
        is_mobile_app_web_view: false,
        content_unavailability_reason_code: UrlRedirectPresenter::CONTENT_UNAVAILABILITY_REASON_CODES[:email_confirmation_required],
        add_to_library_option: "none",
        confirmation_info: {
          id: @url_redirect.token,
          destination: nil,
          display: nil,
          email: nil,
        }
      ))
    end

    it "assigns the url_redirect correctly" do
      get :confirm_page, params: { id: @url_redirect.token }
      expect(assigns(:url_redirect)).to eq @url_redirect
    end

    context "when params[:destination] is set" do
      it "assigns @destination with params[:destination]" do
        get :confirm_page, params: { id: @url_redirect.token, destination: "stream" }

        expect(assigns(:react_component_props)[:confirmation_info][:destination]).to eq "stream"
      end
    end

    context "when params[:destination] is not set" do
      context "when the purchased product has rich content" do
        before do
          product = @url_redirect.purchase.link
          create(:rich_content, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello world" }] }])
        end

        it "assigns @destination with 'download_page'" do
          get :confirm_page, params: { id: @url_redirect.token }

          expect(assigns(:react_component_props)[:confirmation_info][:destination]).to eq "download_page"
        end
      end

      it "assigns @destination with nil value for an installment" do
        installment = create(:installment)
        installment.product_files << create(:product_file)
        url_redirect = create(:installment_url_redirect, installment:)

        get :confirm_page, params: { id: url_redirect.token }

        expect(assigns(:react_component_props)[:confirmation_info][:destination]).to be_nil
      end
    end
  end

  describe "POST 'confirm'" do
    describe "download page" do
      it "redirects and reset counter if email is correct" do
        post :confirm, params: { id: @token, email: @url_redirect.purchase.email, destination: "download_page" }
        expect(response).to redirect_to(url_redirect_download_page_path(@url_redirect.token))
      end
    end

    it "redirects and reset counter if email is correct" do
      post :confirm, params: { id: @token, email: @url_redirect.purchase.email }
      expect(response).to redirect_to(url_redirect_path(@url_redirect.token))
    end

    it "forwards the 'display' query parameter while redirecting" do
      post :confirm, params: { id: @token, email: @url_redirect.purchase.email, display: "mobile_app" }
      expect(response).to redirect_to(url_redirect_path(@url_redirect.token, display: "mobile_app"))
    end

    it "renders confirm again if the email address is bad" do
      post :confirm, params: { id: @token, email: "incorrect@email.com" }
      expect(response).to redirect_to confirm_page_path(id: @url_redirect.token)
    end

    it "ignores case" do
      post :confirm, params: { id: @token, email: "abcabc@abc.com" }
      expect(response).to redirect_to(url_redirect_path(@url_redirect.token))
      post :confirm, params: { id: @token, email: "abcABC@abc.com" }
      expect(response).to redirect_to(url_redirect_path(@url_redirect.token))
      post :confirm, params: { id: @token, email: "ABCabc@Abc.cOM" }
      expect(response).to redirect_to(url_redirect_path(@url_redirect.token))
    end

    it "ignores spaces" do
      post :confirm, params: { id: @token, email: "abcabc@abc.com " }
      expect(response).to redirect_to(url_redirect_path(@url_redirect.token))

      post :confirm, params: { id: @token, email: " abcabc@abc.com" }
      expect(response).to redirect_to(url_redirect_path(@url_redirect.token))

      post :confirm, params: { id: @token, email: "  abcabc@abc.com  " }
      expect(response).to redirect_to(url_redirect_path(@url_redirect.token))
    end

    it "does not raise an exception when the email is absent" do
      expect { post :confirm, params: { id: @token, email: nil } }.not_to raise_error
      expect(response).to redirect_to confirm_page_path(id: @url_redirect.token)
    end
  end

  describe "GET send_to_kindle" do
    let(:product) { create(:product_with_pdf_file) }
    let(:purchase) { create(:purchase, link: product) }
    let!(:url_redirect) { create(:url_redirect, link: product, purchase:) }
    let(:product_file) { product.product_files.alive.last }

    it "queues send_to_kindle for a valid kindle email and creates consumption event" do
      expect do
        expect do
          post :send_to_kindle, params: {
            id: url_redirect.token, file_external_id: product_file.external_id, email: "dude@kindle.com"
          }
        end.to change(ConsumptionEvent, :count).by(1)
      end.to have_enqueued_mail(CustomerMailer, :send_to_kindle).with("dude@kindle.com", product_file.id)

      event = ConsumptionEvent.last
      expect(event.event_type).to eq(ConsumptionEvent::EVENT_TYPE_READ)
      expect(event.product_file_id).to eq product_file.id
      expect(event.url_redirect_id).to eq url_redirect.id
      expect(event.purchase_id).to eq purchase.id
      expect(event.link_id).to eq product.id
      expect(event.platform).to eq Platform::WEB
    end

    describe "invalid kindle emails" do
      it "cannot create a user with a bad kindle email address" do
        expect do
          expect do
            expect do
              create(:user, kindle_email: "there_is_no_way_this_will_work@nonkindle.com")
            end.to raise_error(ActiveRecord::RecordInvalid, "Validation failed: Kindle email is invalid")
          end.to_not change { User.count }
        end.to_not change { ConsumptionEvent.count }
      end

      context "with invalid email address" do
        before do
          expect(CustomerMailer).to_not receive(:send_to_kindle)
        end

        context "when the email is not provided" do
          it "returns error" do
            expect do
              post(:send_to_kindle, params: { id: url_redirect.token, file_external_id: product_file.external_id })
            end.to_not change { ConsumptionEvent.count }
            expect(response.parsed_body["success"]).to be(false)
            expect(response.parsed_body["error"]).to eq("Please enter a valid Kindle email address")
          end
        end

        context "when the email provided is invalid" do
          it "returns error" do
            expect do
              post :send_to_kindle, params: {
                id: url_redirect.token,
                file_external_id: product_file.external_id,
                email: "I don't see this working either"
              }
            end.to_not change { ConsumptionEvent.count }
            expect(response.parsed_body["success"]).to be(false)
            expect(response.parsed_body["error"]).to eq("Please enter a valid Kindle email address")
          end
        end

        context "when the user is signed in" do
          before do
            sign_in create(:user)
          end

          it "returns the correct error" do
            expect do
              post :send_to_kindle, params: {
                id: url_redirect.token,
                file_external_id: product_file.external_id,
                email: "I don't see this working either"
              }
            end.to_not change { ConsumptionEvent.count }
            expect(response.parsed_body["success"]).to be(false)
            expect(response.parsed_body["error"]).to eq("Kindle email is invalid")
          end
        end
      end
    end
  end

  describe "reading" do
    describe "Product" do
      before do
        @product = create(:product_with_pdf_file)
        @purchase = create(:purchase, link: @product, purchaser: create(:user))
        @url_redirect = create(:url_redirect, purchase: @purchase)
        @token = @url_redirect.token
        # TODO: Uncomment after removing the :custom_domain_download feature flag (curtiseinsmann)
        # @request.host = URI.parse(@product.user.subdomain_with_protocol).host
      end

      context "when user is not signed in" do
        it "sets hide_layouts to true" do
          get :download_page, params: { id: @token }
          expect(response).to be_successful
          expect(assigns(:hide_layouts)).to eq(true)
          expect(response.body).to have_link(href: url_redirect_read_for_product_file_path(@token, @product.product_files.first.external_id))
        end
      end

      context "when user is signed in" do
        before do
          sign_in(@purchase.purchaser)
        end

        it "has a a read button for a PDF product file" do
          get :download_page, params: { id: @token }
          expect(response).to be_successful
          expect(assigns(:hide_layouts)).to eq(true)
          expect(response.body).to have_link(href: url_redirect_read_for_product_file_path(@token, @product.product_files.first.external_id))
        end

        it "can be read with proper file download URL" do
          get :read, params: { id: @token, product_file_id: @product.product_files.first.external_id }
          expect(response).to be_successful
          expect(assigns(:hide_layouts)).to eq(true)
          expect(assigns(:read_url)).to include("cache_group=read")
          expect(assigns(:read_url)).to include("staging-files.gumroad.com")
          expect(response.body).to have_selector("h1", text: "The Works of Edgar Gumstein")
        end

        it "creates the proper consumption event" do
          get :read, params: { id: @token, product_file_id: @product.product_files.first.external_id }
          expect(ConsumptionEvent.count).to eq 1
          event = ConsumptionEvent.last
          expect(event.product_file_id).to eq @product.product_files.first.id
          expect(event.url_redirect_id).to eq @url_redirect.id
          expect(event.purchase_id).to eq @url_redirect.purchase.id
          expect(event.link_id).to eq @product.id
          expect(event.event_type).to eq ConsumptionEvent::EVENT_TYPE_READ
          expect(event.platform).to eq Platform::WEB
        end

        it "redirects to library if something goes awry" do
          get :read, params: { id: "this is not my beautiful URL Redirect Token" }
          expect(response).to redirect_to(library_path)
        end

        it "redirects to library if no product file found" do
          readable_external_id = @product.product_files.first.external_id
          @product.product_files.delete_all

          get :read, params: { id: @token, product_file_id: readable_external_id }

          expect(response).to redirect_to(library_path)
        end

        it "redirects to home if something goes awry and not logged in" do
          sign_out User.last
          get :read, params: { id: "I don't even have a beautiful URL Redirect Token" }
          expect(response).to redirect_to(root_path)
        end

        it "gets current product file if replaced" do
          @product.product_files.each(&:mark_deleted)
          create(:product_file, link: @product, url: "https://s3.amazonaws.com/gumroad-specs/specs/nyt.pdf", filetype: "pdf")
          get(:read, params: { id: @url_redirect.token })
          expect(assigns(:read_url)).to include("nyt.pdf")
        end

        it "recovers from an S3 error" do
          expect(Aws::S3::Resource).to receive(:new).and_raise(ArgumentError)
          get(:read, params: { id: @token, product_file_id: @product.product_files.first.external_id })
          expect(response).to redirect_to("/library")
        end
      end
    end

    describe "Installment" do
      before do
        follower = create(:user)
        creator = create(:follower, follower_user_id: follower.id).user
        @post = create(:follower_installment, seller: creator)
        @token = create(:installment_url_redirect, installment: @post).token
        sign_in(follower)
        # TODO: Uncomment after removing the :custom_domain_download feature flag (curtiseinsmann)
        # @request.host = URI.parse(creator.subdomain_with_protocol).host
      end

      it "has a readable Product File for a PDF installment with no associated product" do
        get :download_page, params: { id: @token }
        url = url_redirect_read_for_product_file_path(@token, @post.product_files.first.external_id)
        expect(response.body).to have_link(href: url)
      end

      it "can be read" do
        get :read, params: { id: @token, product_file_id: @post.product_files.first.external_id }
        expect(response.body).to have_selector("h1", text: "A new file!")
      end
    end
  end

  describe "change_purchaser" do
    it "changes the purchaser to current user and redirect" do
      user = create(:user)

      expect do
        sign_in user
        post :change_purchaser, params: { id: @token, next: "/r/#{@token}", email: @url_redirect.purchase.email }
      end.to change { @url_redirect.purchase.reload.purchaser }.to(user)

      expect(response).to redirect_to("/r/#{@token}")
    end

    it "redirects to the check_purchaser page if the email is incorrect" do
      user = create(:user)

      expect do
        sign_in user
        post :change_purchaser, params: { id: @token, next: "/r/#{@token}", email: "wrong@example.com" }
      end.not_to change { @url_redirect.purchase.reload.purchaser }

      expect(response).to redirect_to(url_redirect_check_purchaser_path(@token, next: "/r/#{@token}"))
      expect(flash[:alert]).to eq("Please enter the correct email address used to purchase this product")
    end
  end

  describe "GET membership_inactive_page" do
    let(:product) { create(:membership_product) }
    let(:subscription) { create(:subscription, link: product) }
    let(:purchase) do create(:purchase, link: product, email: subscription.user.email,
                                        is_original_subscription_purchase: true,
                                        purchaser: create(:user), subscription:, created_at: 2.days.ago) end
    let(:url_redirect) { create(:url_redirect, purchase:, link: product) }

    it "renders the manage subscription link for subscriptions that can be restarted" do
      get :membership_inactive_page, params: { id: url_redirect.token }

      expect(response).to be_successful
      expect(response.body).to have_title("The Works of Edgar Gumstein - Your membership is inactive")
      expect(response.body).to have_text("Your membership is inactive")
      expect(response.body).to have_link("Manage membership", href: manage_subscription_url(subscription.external_id))
    end

    it "renders the product link for subscriptions that cannot be restarted" do
      allow_any_instance_of(Subscription).to receive(:alive_or_restartable?).and_return(false)

      get :membership_inactive_page, params: { id: url_redirect.token }

      expect(response).to be_successful
      expect(response.body).to have_link("Resubscribe", href: product.long_url)
    end
  end

  describe "GET rental_expired_page" do
    let(:url_redirect) { create(:url_redirect) }

    it "renders the page" do
      get :rental_expired_page, params: { id: @url_redirect.token }
      expect(response).to be_successful
      expect(response.body).to have_title("The Works of Edgar Gumstein - Your rental has expired")
      expect(response.body).to have_text("Your rental has expired")
    end
  end

  describe "GET expired" do
    let(:url_redirect) { create(:url_redirect) }

    it "renders the page" do
      get :expired, params: { id: @url_redirect.token }
      expect(response).to be_successful
      expect(response.body).to have_title("The Works of Edgar Gumstein - Access expired")
      expect(response.body).to have_text("Access expired")
    end
  end

  describe "GET latest_media_locations" do
    it "returns a 404 if the url redirect is not found" do
      expect do
        get :download_page, params: { id: "some non-existent id" }
      end.to raise_error(ActionController::RoutingError)
    end

    it "returns a 404 if the url redirect is for an installment" do
      seller = create(:user)
      product = create(:product, user: seller)
      seller_installment = create(:installment, seller:, installment_type: "seller", link: nil)
      seller_installment.product_files.create!(url: "https://s3.amazonaws.com/gumroad-specs/specs/magic.mp3")
      url_redirect = create(:url_redirect, installment: seller_installment, purchase: nil, link: product)

      expect do
        get :latest_media_locations, params: { id: url_redirect.token }
      end.to raise_error(ActionController::RoutingError)
    end

    it "returns latest media locations for the purchased product" do
      product = create(:product)
      video = create(:streamable_video)
      audio = create(:listenable_audio)
      readable_document = create(:readable_document)
      non_readable_document = create(:non_readable_document)
      product.product_files = [video, audio, readable_document, non_readable_document]
      product.save!
      purchase = create(:purchase, link: product)
      url_redirect = create(:url_redirect, link: product, purchase:)

      audio_consumption_timestamp = Time.current.change(usec: 0)
      create(:media_location, url_redirect_id: url_redirect.id, purchase_id: url_redirect.purchase.id,
                              product_file_id: audio.id, product_id: url_redirect.referenced_link.id, location: 5, consumed_at: audio_consumption_timestamp)
      readable_document_consumption_timestamp = Time.current.change(usec: 0) + 5.minutes
      create(:media_location, url_redirect_id: url_redirect.id, purchase_id: url_redirect.purchase.id, platform: Platform::ANDROID,
                              product_file_id: readable_document.id, product_id: url_redirect.referenced_link.id, location: 3, consumed_at: readable_document_consumption_timestamp)

      get :latest_media_locations, params: { id: url_redirect.token }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        "#{video.external_id}" => nil,
        "#{audio.external_id}" => { "location" => 5, "timestamp" => audio_consumption_timestamp.as_json, "unit" => "seconds" },
        "#{readable_document.external_id}" => { "location" => 3, "timestamp" => readable_document_consumption_timestamp.as_json, "unit" => "page_number" },
        "#{non_readable_document.external_id}" => nil
      )
    end
  end

  describe "GET 'audio_durations'" do
    it "returns empty hash if the 'file_ids' parameter is blank" do
      url_redirect = create(:url_redirect)

      get :audio_durations, params: { id: url_redirect.token, file_ids: [] }

      expect(response).to be_successful
      expect(response.parsed_body).to eq({})
    end

    it "returns the audio durations for the given file ids" do
      product = create(:product)
      audio1 = create(:listenable_audio, duration: 100)
      audio2 = create(:listenable_audio, duration: nil)
      product.product_files << audio1
      product.product_files << audio2
      product.save!
      purchase = create(:purchase, link: product)
      url_redirect = create(:url_redirect, link: product, purchase: purchase)

      get :audio_durations, params: { id: url_redirect.token, file_ids: [audio1.external_id, audio2.external_id] }

      expect(response).to be_successful
      expect(response.parsed_body).to eq("#{audio1.external_id}" => 100, "#{audio2.external_id}" => nil)

      audio2.update!(duration: 200)

      get :audio_durations, params: { id: url_redirect.token, file_ids: [audio2.external_id] }

      expect(response).to be_successful
      expect(response.parsed_body).to eq("#{audio2.external_id}" => 200)
    end
  end

  describe "GET 'media_urls" do
    before do
      @product = create(:product)
      @audio = create(:listenable_audio)
      @video = create(:streamable_video)
      @product.product_files << @audio
      @product.product_files << @video
      @product.save!
      @purchase = create(:purchase, link: @product)
      @url_redirect = create(:url_redirect, link: @product, purchase: @purchase)
    end

    it "returns empty hash if the 'file_ids' parameter is blank" do
      get :media_urls, params: { id: @url_redirect.token, file_ids: [] }

      expect(response).to be_successful
      expect(response.parsed_body).to eq({})
    end

    it "returns the media urls for the given file ids" do
      freeze_time do
        get :media_urls, params: { id: @url_redirect.token, file_ids: [@audio.external_id, @video.external_id] }

        expect(response).to be_successful
        expect(response.parsed_body.count).to eq(2)
        expect(response.parsed_body[@audio.external_id]).to eq([@url_redirect.signed_location_for_file(@audio)])
        expect(response.parsed_body[@video.external_id]).to eq([@url_redirect.hls_playlist_or_smil_xml_path(@video), @url_redirect.signed_location_for_file(@video)])
      end
    end
  end
end
