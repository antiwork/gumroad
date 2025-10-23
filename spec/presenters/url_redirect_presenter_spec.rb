# frozen_string_literal: true

require "spec_helper"

describe UrlRedirectPresenter do
  include Rails.application.routes.url_helpers
  describe "#download_attributes" do
    it "returns all necessary attributes for the download page" do
      allow(Aws::S3::Resource).to receive(:new).and_return(double(bucket: double(object: double(content_length: 1, public_url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/4768692737035/bb69798a4a694e19a0976390a7e40e6b/original/chapter1.srt"))))

      product = create(:product)
      folder = create(:product_folder, link: product, name: "Folder")
      file = create(:streamable_video, link: product)
      folder_file = create(:readable_document, link: product, display_name: "Display Name", description: "Description", folder_id: folder.id, pagelength: 3, size: 50)
      subtitle_file = create(:subtitle_file, product_file: file)
      purchase = create(:purchase, link: product)
      url_redirect = create(:url_redirect, purchase:)
      user = create(:user)
      file_media_location = create(:media_location, url_redirect_id: url_redirect.id, purchase_id: purchase.id,
                                                    product_file_id: file.id, product_id: product.id, location: 3)
      folder_file_media_location = create(:media_location, url_redirect_id: url_redirect.id, purchase_id: purchase.id,
                                                           product_file_id: folder_file.id, product_id: product.id, location: 2)
      instance = described_class.new(url_redirect:, logged_in_user: user)
      expect(instance.download_attributes).to eq(content_items: [{ type: "folder",
                                                                   id: folder.external_id, name: folder.name,
                                                                   children: [{
                                                                     type: "file",
                                                                     extension: "PDF",
                                                                     file_name: "Display Name",
                                                                     description: "Description",
                                                                     file_size: 50,
                                                                     isbn: nil,
                                                                     id: folder_file.external_id,
                                                                     pagelength: 3,
                                                                     duration: nil,
                                                                     subtitle_files: [],
                                                                     download_url: url_redirect_download_product_files_path(url_redirect.token, { product_file_ids: [folder_file.external_id] }),
                                                                     stream_url: nil,
                                                                     kindle_data: { email: user.kindle_email, icon_url: ActionController::Base.helpers.asset_path("white-15.png") },
                                                                     read_url: url_redirect_read_for_product_file_path(url_redirect.token, folder_file.external_id),
                                                                     latest_media_location: folder_file_media_location.as_json,
                                                                     content_length: folder_file.content_length,
                                                                     external_link_url: nil,
                                                                     pdf_stamp_enabled: false,
                                                                     processing: false,
                                                                     thumbnail_url: nil,
                                                                   }]
                                                                 },
                                                                 {
                                                                   type: "file",
                                                                   extension: "MOV",
                                                                   file_name: "ScreenRecording",
                                                                   description: nil,
                                                                   file_size: nil,
                                                                   id: file.external_id,
                                                                   pagelength: nil,
                                                                   duration: nil,
                                                                   isbn: nil,
                                                                   subtitle_files: [
                                                                     url: subtitle_file.url,
                                                                     file_name: subtitle_file.s3_display_name,
                                                                     extension: subtitle_file.s3_display_extension,
                                                                     language: subtitle_file.language,
                                                                     file_size: subtitle_file.size,
                                                                     download_url: url_redirect_download_subtitle_file_path(url_redirect.token, file.external_id, subtitle_file.external_id),
                                                                     signed_url: file.signed_download_url_for_s3_key_and_filename(subtitle_file.s3_key, subtitle_file.s3_display_name, is_video: true),
                                                                   ],
                                                                   download_url: url_redirect_download_product_files_path(url_redirect.token, { product_file_ids: [file.external_id] }),
                                                                   stream_url: url_redirect_stream_page_for_product_file_path(url_redirect.token, file.external_id),
                                                                   kindle_data: nil,
                                                                   read_url: nil,
                                                                   latest_media_location: file_media_location.as_json,
                                                                   content_length: file.content_length,
                                                                   external_link_url: nil,
                                                                   pdf_stamp_enabled: false,
                                                                   processing: false,
                                                                   thumbnail_url: nil,
                                                                 }])
    end

    it "omits empty folders" do
      product = create(:product)

      folder_one = create(:product_folder, link: product, name: "Folder 1")
      create(:product_folder, link: product, name: "Empty folder")

      create(:readable_document, link: product, display_name: "File in Folder 1", folder_id: folder_one.id)

      purchase = create(:purchase, link: product)
      url_redirect = create(:url_redirect, purchase:)
      user = create(:user)
      instance = described_class.new(url_redirect:, logged_in_user: user)

      content_items = instance.download_attributes[:content_items]
      expect(content_items.length).to eq(1)

      item_one = content_items[0]
      expect(item_one[:type]).to eq("folder")
      expect(item_one[:name]).to eq("Folder 1")
      expect(item_one[:children].length).to eq(1)
      expect(item_one[:children][0][:file_name]).to eq("File in Folder 1")
    end

    it "includes thumbnail_url for product files that have thumbnails" do
      product = create(:product)
      file = create(:streamable_video, link: product)
      file.thumbnail.attach(io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")), filename: "smilie.png")
      purchase = create(:purchase, link: product)
      url_redirect = create(:url_redirect, purchase:)
      user = create(:user)
      instance = described_class.new(url_redirect:, logged_in_user: user)

      content_items = instance.download_attributes[:content_items]
      expect(content_items.length).to eq(1)
      expect(content_items.first[:thumbnail_url]).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{file.thumbnail_variant.key}")
    end
  end

  describe "#download_page_with_content_props" do
    before do
      @user = create(:user, name: "John Doe")
      @product = create(:product, user: @user)
      @purchase = create(:purchase, link: @product, is_bundle_product_purchase: true)
      create(:bundle_product_purchase, product_purchase: @purchase, bundle_purchase: create(:purchase, link: @product, seller: @user))

      @installment = create(:seller_installment, seller: @product.user, published_at: 1.day.ago, send_emails: false, shown_on_profile: true)
      @url_redirect = create(:url_redirect, purchase: @purchase)
      @props = {
        content: {
          license: nil,
          rich_content_pages: nil,
          content_items: [],
          posts: [],
          video_transcoding_info: nil,
          custom_receipt: nil,
          discord: nil,
          community_chat_url: nil,
          download_all_button: nil,
          ios_app_url: IOS_APP_STORE_URL,
          android_app_url: ANDROID_APP_STORE_URL,
        },
        terms_page_url: HomePageLinkService.terms,
        token: @url_redirect.token,
        redirect_id: @url_redirect.external_id,
        creator: {
          name: "John Doe",
          profile_url: @user.profile_url(recommended_by: "library"),
          avatar_url: @user.avatar_url,
        },
        product_has_third_party_analytics: false,
        installment: nil,
        purchase: {
          id: @purchase.external_id,
          bundle_purchase_id: @purchase.bundle_purchase.external_id,
          created_at: @purchase.created_at,
          email: @purchase.email,
          email_digest: @purchase.email_digest,
          is_archived: false,
          product_long_url: @product.long_url,
          product_id: @product.external_id,
          product_name: @product.name,
          variant_id: nil,
          variant_name: nil,
          product_permalink: @product.unique_permalink,
          allows_review: true,
          disable_reviews_after_year: false,
          review: nil,
          membership: nil,
          purchase_custom_fields: [],
          call: nil,
        },
      }
    end

    it "returns all props for DownloadPageWithContent component" do
      instance = described_class.new(url_redirect: @url_redirect, logged_in_user: @user)

      @props[:content][:posts] = [{
        id: @installment.external_id,
        name: @installment.displayed_name,
        action_at: @installment.action_at_for_purchases([@purchase.id]),
        view_url: custom_domain_view_post_url(
          username: @installment.user.username,
          slug: @installment.slug,
          purchase_id: @purchase.external_id,
          host: @user.subdomain,
          protocol: PROTOCOL
        )
      }]
      expect(instance.download_page_with_content_props).to eq(@props)
    end

    it "includes 'custom_receipt' in props" do
      @product.update!(custom_receipt: "Lorem ipsum <b>dolor</b> sit amet https://example.com")
      instance = described_class.new(url_redirect: @url_redirect, logged_in_user: @user)
      expect(instance.download_page_with_content_props[:content][:custom_receipt]).to be_nil
    end

    it "includes 'discord' in props" do
      integration = create(:discord_integration)
      @product.active_integrations << integration
      instance = described_class.new(url_redirect: @url_redirect, logged_in_user: @user)
      expect(instance.download_page_with_content_props[:content][:discord]).to eq(connected: false)

      create(:discord_purchase_integration, integration:, purchase: @purchase)
      expect(instance.download_page_with_content_props[:content][:discord]).to eq(connected: true)
    end

    it "includes 'download_all_button' in props for installments with files" do
      freeze_time do
        installment = create(:installment, link: @product)

        url_redirect = create(:url_redirect, installment:)
        instance = described_class.new(url_redirect:, logged_in_user: @user)
        expect(instance.download_page_with_content_props[:content][:download_all_button]).to be_nil

        file1 = create(:readable_document)
        file2 = create(:streamable_video)
        installment.product_files = [file1, file2]
        installment.save!

        url_redirect = create(:url_redirect, installment:)
        instance = described_class.new(url_redirect:, logged_in_user: @user)

        expect(instance.download_page_with_content_props[:content][:download_all_button]).to be_nil

        installment.product_files_archives.create!(product_files: installment.product_files, product_files_archive_state: "ready")

        url_redirect = create(:url_redirect, installment:)
        instance = described_class.new(url_redirect:, logged_in_user: @user)

        expect(instance.download_page_with_content_props[:content][:download_all_button]).to eq(
          files: [
            { "filename" => file1.s3_filename, "url" => url_redirect.signed_location_for_file(file1) },
            { "filename" => file2.s3_filename, "url" => url_redirect.signed_location_for_file(file2) }
          ]
        )
      end
    end

    it "returns nil for `download_all_button` when the URL redirect is not for an installment" do
      file1 = create(:readable_document)
      file2 = create(:streamable_video)
      @product.product_files = [file1, file2]
      @product.product_files_archives.create!(product_files: @product.product_files, folder_id: SecureRandom.uuid, product_files_archive_state: "ready")

      instance = described_class.new(url_redirect: @url_redirect, logged_in_user: @user)
      expect(instance.download_page_with_content_props[:content][:download_all_button]).to be_nil
    end

    it "includes 'creator' in props" do
      @user.update!(name: "John Doe")
      instance = described_class.new(url_redirect: @url_redirect, logged_in_user: @user)
      expect(instance.download_page_with_content_props[:creator]).to eq(
        name: "John Doe",
        profile_url: @user.profile_url(recommended_by: "library"),
        avatar_url: @user.avatar_url,
      )
    end

    it "includes 'membership' in props" do
      product = create(:membership_product)
      subscription = create(:subscription, link: product)
      purchase = create(:purchase, link: product, email: subscription.user.email, is_original_subscription_purchase: true, subscription:, created_at: 2.days.ago)
      url_redirect = create(:url_redirect, purchase:, link: product)

      instance = described_class.new(url_redirect:, logged_in_user: @user)
      expect(instance.download_page_with_content_props[:purchase][:membership]).to eq(
        has_active_subscription: true,
        subscription_id: subscription.external_id,
        is_subscription_ended: false,
        is_installment_plan_completed: false,
        is_subscription_cancelled_or_failed: false,
        is_alive_or_restartable: true,
        in_free_trial: false,
        is_installment_plan: false,
      )
    end

    it "includes rich content in props" do
      product_content = [{ "content" => [{ "type" => "text", "text" => "Hello" }], "type" => "paragraph" }]
      rich_content = create(:rich_content, entity: @product, title: "Page title", description: product_content)
      instance = described_class.new(url_redirect: @url_redirect, logged_in_user: @user)

      @props[:content][:rich_content_pages] = [{ id: rich_content.external_id, page_id: rich_content.external_id, variant_id: nil, title: "Page title", description: { content: product_content, type: "doc" }, updated_at: rich_content.updated_at }]
      expect(instance.download_page_with_content_props).to eq(@props)
    end

    describe "'posts' in props" do
      context "when rich content is present" do
        context "when rich content contains a 'posts' embed" do
          before do
            create(:rich_content, entity: @product, title: "Page title", description: [{ "type" => "posts" }])
          end

          it "includes 'posts' in props" do
            instance = described_class.new(url_redirect: @url_redirect, logged_in_user: @user)

            expect(instance.download_page_with_content_props.dig(:content, :posts).size).to eq(1)
          end
        end

        context "when rich content does not contain a 'posts' embed" do
          before do
            create(:rich_content, entity: @product, title: "Page title", description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])
          end

          it "include empty 'posts' in props" do
            instance = described_class.new(url_redirect: @url_redirect, logged_in_user: @user)

            expect(instance.download_page_with_content_props[:content][:posts].size).to eq(0)
          end
        end
      end

      it "includes 'posts' in props for an installment URL redirect" do
        original_purchase = create(:membership_purchase, purchaser: @user, email: @user.email, is_archived_original_subscription_purchase: true)
        updated_original_purchase = create(:membership_purchase, purchaser: @user, email: @user.email, purchase_state: "not_charged", subscription: original_purchase.subscription, link: original_purchase.link)
        post = create(:installment, link: original_purchase.link, published_at: 1.day.ago)
        create(:creator_contacting_customers_email_info_sent, purchase: updated_original_purchase, installment: post)
        url_redirect = create(:url_redirect, purchase: original_purchase)
        instance = described_class.new(url_redirect: url_redirect, logged_in_user: @user)

        expect(instance.download_page_with_content_props[:content][:posts].sole[:id]).to eq(post.external_id)
      end
    end

    it "includes license in props" do
      product = create(:membership_product, is_licensed: true)
      purchase = create(:membership_purchase, :with_license, link: product)
      url_redirect = create(:url_redirect, purchase:)
      instance = described_class.new(url_redirect:, logged_in_user: @user)

      expect(instance.download_page_with_content_props[:content][:license]).to eq({ license_key: purchase.license_key, is_multiseat_license: false, seats: 1 })
    end

    describe "video_transcoding_info" do
      let(:logged_in_user) { @user }
      let(:presenter) { described_class.new(url_redirect: @url_redirect, logged_in_user:) }

      context "when rich content is not present" do
        it "returns nil" do
          expect(presenter.download_page_with_content_props[:content][:video_transcoding_info]).to be_nil
        end
      end

      context "when rich content does not contain any video embeds" do
        before do
          file = create(:readable_document, link: @product)
          product_content = [
            { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] },
            { "type" => "fileEmbed", "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }
          ]
          create(:rich_content, entity: @product, description: product_content)
        end

        it "returns nil" do
          expect(presenter.download_page_with_content_props[:content][:video_transcoding_info]).to be_nil
        end
      end

      context "when the rich content contains video embeds" do
        let(:video1) { create(:streamable_video, link: @product) }
        let(:video2) { create(:streamable_video, link: @product) }

        before do
          product_content = [
            { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] },
            { "type" => "fileEmbed", "attrs" => { "id" => video1.external_id, "uid" => SecureRandom.uuid } },
            { "type" => "fileEmbed", "attrs" => { "id" => video2.external_id, "uid" => SecureRandom.uuid } }
          ]
          create(:rich_content, entity: @product, description: product_content)
        end

        context "when logged in user is not the seller" do
          let(:logged_in_user) { create(:user) }

          it "returns nil" do
            expect(presenter.download_page_with_content_props[:content][:video_transcoding_info]).to be_nil
          end
        end

        context "when all videos are transcoded" do
          before do
            create(:transcoded_video, streamable: video1, is_hls: true)
            create(:transcoded_video, streamable: video2, is_hls: true)
          end

          it "returns nil" do
            expect(presenter.download_page_with_content_props[:content][:video_transcoding_info]).to be_nil
          end
        end

        context "when all videos are not transcoded" do
          before do
            create(:transcoded_video, streamable: video1, is_hls: true)
          end

          context "when videos are set to transcode on first sale" do
            before do
              @product.update!(transcode_videos_on_purchase: true)
            end

            it "returns the video transcoding info" do
              expect(presenter.download_page_with_content_props[:content][:video_transcoding_info]).to eq(transcode_on_first_sale: true)
            end
          end

          context "when videos are not set to transcode on first sale" do
            it "returns the video transcoding info" do
              expect(presenter.download_page_with_content_props[:content][:video_transcoding_info]).to eq(transcode_on_first_sale: false)
            end
          end
        end
      end
    end

    context "when associated with a completed commission", :vcr do
      let(:commission) { create(:commission, status: Commission::STATUS_COMPLETED) }
      let(:presenter) { described_class.new(url_redirect: commission.deposit_purchase.url_redirect) }

      before do
        commission.files.attach(file_fixture("smilie.png"))
        commission.files.attach(file_fixture("test.pdf"))
        commission.deposit_purchase.create_url_redirect!
      end

      it "includes commission files in the rich content json" do
        expect(presenter.download_page_with_content_props[:content][:content_items]).to contain_exactly(
          {
            type: "file",
            file_name: "smilie",
            description: nil,
            extension: "PNG",
            file_size: 100406,
            pagelength: nil,
            duration: nil,
            id: commission.files.first.signed_id,
            download_url: commission.files.first.blob.url,
            stream_url: nil,
            kindle_data: nil,
            latest_media_location: nil,
            content_length: nil,
            read_url: nil,
            external_link_url: nil,
            subtitle_files: [],
            pdf_stamp_enabled: false,
            processing: false,
            thumbnail_url: nil
          },
          {
            type: "file",
            file_name: "test",
            description: nil,
            extension: "PDF",
            file_size: 8278,
            pagelength: nil,
            duration: nil,
            id: commission.files.second.signed_id,
            download_url: commission.files.second.blob.url,
            stream_url: nil,
            kindle_data: nil,
            latest_media_location: nil,
            content_length: nil,
            read_url: nil,
            external_link_url: nil,
            subtitle_files: [],
            pdf_stamp_enabled: false,
            processing: false,
            thumbnail_url: nil
          }
        )
      end

      context "when the commission is not completed" do
        before { commission.update(status: Commission::STATUS_IN_PROGRESS) }

        it "does not include commission files" do
          expect(presenter.download_page_with_content_props[:content][:content_items]).to eq([])
        end
      end
    end

    context "community_chat_url prop" do
      let(:product) { create(:product) }
      let(:purchase) { create(:purchase, link: product, purchaser: @user) }
      let(:url_redirect) { create(:url_redirect, purchase:) }
      let(:presenter) { described_class.new(url_redirect:, logged_in_user: @user) }

      it "returns nil when purchase is not present" do
        url_redirect = create(:url_redirect, purchase: nil)
        presenter = described_class.new(url_redirect:, logged_in_user: @user)
        expect(presenter.download_page_with_content_props[:content][:community_chat_url]).to be_nil
      end

      it "returns nil when communities feature is not active for seller" do
        expect(presenter.download_page_with_content_props[:content][:community_chat_url]).to be_nil
      end

      context "when communities feature is active for seller" do
        before do
          Feature.activate_user(:communities, product.user)
        end

        it "returns nil when community chat is not enabled for product" do
          expect(presenter.download_page_with_content_props[:content][:community_chat_url]).to be_nil
        end

        context "when community chat is enabled for product" do
          before do
            product.update!(community_chat_enabled: true)
          end

          it "returns nil when product has no active community" do
            expect(presenter.download_page_with_content_props[:content][:community_chat_url]).to be_nil
          end

          it "returns nil when purchase has no purchaser_id" do
            purchase.update!(purchaser_id: nil)
            expect(presenter.download_page_with_content_props[:content][:community_chat_url]).to be_nil
          end

          it "returns community path when product has an active community" do
            community = create(:community, seller: product.user, resource: product)
            expect(presenter.download_page_with_content_props[:content][:community_chat_url]).to eq(community_path(product.user.external_id, community.external_id))
          end

          context "when user is not logged in" do
            let(:presenter) { described_class.new(url_redirect:, logged_in_user: nil) }

            it "returns login path with next parameter when user is not logged in" do
              community = create(:community, seller: product.user, resource: product)
              expected_path = login_path(email: purchase.email, next: community_path(product.user.external_id, community.external_id))
              expect(presenter.download_page_with_content_props[:content][:community_chat_url]).to eq(expected_path)
            end
          end

          context "when purchase has no purchaser_id" do
            before do
              purchase.update!(purchaser_id: nil)
            end

            it "returns signup path with next parameter" do
              community = create(:community, seller: product.user, resource: product)
              expected_path = signup_path(email: purchase.email, next: community_path(product.user.external_id, community.external_id))
              expect(presenter.download_page_with_content_props[:content][:community_chat_url]).to eq(expected_path)
            end
          end
        end
      end
    end
  end

  describe "#download_page_without_content_props" do
    before do
      @user = create(:user, name: "John Doe", disable_reviews_after_year: true)
      @product = create(:membership_product, user: @user)
      @subscription = create(:subscription, link: @product)
      @purchase = create(:purchase, link: @product, email: @subscription.user.email, is_original_subscription_purchase: true, subscription: @subscription, created_at: 2.days.ago)
      @url_redirect = create(:url_redirect, purchase: @purchase, link: @product)
      @custom_field = create(:custom_field, products: [@product], field_type: CustomField::TYPE_TEXT, is_post_purchase: true)
      @file_custom_field = create(:custom_field, products: [@product], field_type: CustomField::TYPE_FILE, is_post_purchase: true)
      @purchase.purchase_custom_fields << PurchaseCustomField.build_from_custom_field(custom_field: @custom_field, value: "Hello")
      file_custom_field = PurchaseCustomField.build_from_custom_field(custom_field: @file_custom_field, value: nil)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
      file_custom_field.files.attach(blob)
      @purchase.purchase_custom_fields << file_custom_field
    end

    it "returns the correct props" do
      expect(described_class.new(url_redirect: @url_redirect, logged_in_user: @user).download_page_without_content_props).to eq(
        creator: {
          name: "John Doe",
          profile_url: @user.profile_url(recommended_by: "library"),
          avatar_url: @user.avatar_url,
        },
        terms_page_url: HomePageLinkService.terms,
        token: @url_redirect.token,
        redirect_id: @url_redirect.external_id,
        installment: nil,
        purchase: {
          id: @purchase.external_id,
          bundle_purchase_id: nil,
          created_at: @purchase.created_at,
          email: @purchase.email,
          email_digest: @purchase.email_digest,
          is_archived: false,
          product_id: @product.external_id,
          product_name: @product.name,
          variant_id: nil,
          variant_name: nil,
          product_permalink: @product.unique_permalink,
          product_long_url: @product.long_url,
          allows_review: true,
          disable_reviews_after_year: true,
          review: nil,
          membership: {
            has_active_subscription: true,
            subscription_id: @subscription.external_id,
            is_subscription_ended: false,
            is_installment_plan_completed: false,
            is_subscription_cancelled_or_failed: false,
            is_alive_or_restartable: true,
            in_free_trial: false,
            is_installment_plan: false,
          },
          purchase_custom_fields: [
            {
              type: "shortAnswer",
              custom_field_id: @custom_field.external_id,
              value: "Hello",
            },
            {
              custom_field_id: @file_custom_field.external_id,
              type: "fileUpload",
              files: [
                {
                  name: "smilie",
                  size: 100_406,
                  extension: "PNG"
                }
              ]
            }
          ],
          call: nil,
        },
      )
    end

    context "when the purchase is a call purchase" do
      let!(:call) { create(:call) }

      before { call.purchase.create_url_redirect! }

      it "includes the call in the props" do
        expect(described_class.new(url_redirect: call.purchase.url_redirect).download_page_without_content_props[:purchase][:call]).to eq(
          {
            url: "https://zoom.us/j/gmrd",
            start_time: call.start_time,
            end_time: call.end_time,
          }
        )
      end

      context "when the call has no url" do
        before { call.update!(call_url: nil) }

        it "does not include the url in the props" do
          expect(described_class.new(url_redirect: call.purchase.url_redirect).download_page_without_content_props[:purchase][:call][:url]).to be_nil
        end
      end
    end

    it "does not include purchase email when the email confirmation is required" do
      props = described_class.new(url_redirect: @url_redirect, logged_in_user: @user).download_page_without_content_props(content_unavailability_reason_code: UrlRedirectPresenter::CONTENT_UNAVAILABILITY_REASON_CODES[:email_confirmation_required])

      expect(props[:purchase]).to include(email: nil)
    end

    it "includes 'installment' and correct 'creator' in props" do
      url_redirect = create(:installment_url_redirect, installment: create(:workflow_installment, name: "Thank you for the purchase!", link: nil, seller: @user, product_files: [create(:product_file)]))

      props = described_class.new(url_redirect:, logged_in_user: @user).download_page_without_content_props

      expect(props[:installment]).to eq(name: "Thank you for the purchase!")
      expect(props[:creator]).to eq(
        name: "John Doe",
        profile_url: @user.profile_url(recommended_by: "library"),
        avatar_url: @user.avatar_url,
      )
    end

    context "with completed installment plan" do
      it "marks installment plan as completed when all installments are completed" do
        purchase = create(:installment_plan_purchase)
        subscription = purchase.subscription
        product = subscription.link

        subscription.update_columns(charge_occurrence_count: product.installment_plan.number_of_installments)

        (product.installment_plan.number_of_installments - 1).times do
          create(:purchase, link: product, subscription: subscription, purchaser: subscription.user)
        end

        url_redirect = create(:url_redirect, purchase: purchase)
        props = described_class.new(url_redirect:, logged_in_user: subscription.user).download_page_without_content_props

        expect(props[:purchase][:membership][:is_installment_plan_completed]).to eq(true)
        expect(props[:purchase][:membership][:is_subscription_ended]).to eq(false)
      end

      it "does not mark installment plan as completed when installments are incomplete" do
        purchase = create(:installment_plan_purchase)
        subscription = purchase.subscription
        product = subscription.link

        subscription.update_columns(charge_occurrence_count: product.installment_plan.number_of_installments - 1)

        url_redirect = create(:url_redirect, purchase: purchase)
        props = described_class.new(url_redirect:, logged_in_user: subscription.user).download_page_without_content_props

        expect(props[:purchase][:membership][:is_installment_plan_completed]).to eq(false)
        expect(props[:purchase][:membership][:is_subscription_ended]).to eq(false)
      end
    end
  end
end
