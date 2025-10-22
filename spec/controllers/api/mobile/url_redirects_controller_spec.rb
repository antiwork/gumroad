# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::UrlRedirectsController do
  before do
    @product = create(:product, name: "The Works of Edgar Gumstein", description: "A collection of works spanning 1984 — 1994")
    @product_file1 = create(:product_file, position: 0, link: @product, description: nil, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/kFDzu.png")
    @product_file3 = create(:product_file, position: 1, link: @product, description: "A magic song", url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/magic.mp3")
    @product_file2 = create(:product_file, position: 2, link: @product, description: "A picture", url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/test.png")
    @product.product_files = [@product_file1, @product_file2, @product_file3]
    @url_redirect = create(:url_redirect, link: @product)
    @env_double = double
    allow(Rails).to receive(:env).at_least(1).and_return(@env_double)
    %w[production staging test development].each do |env|
      allow(@env_double).to receive(:"#{ env }?").and_return(false)
    end
  end

  let(:s3_object) { double("s3_object") }

  let(:stub_playlist_s3_object_get) do
    -> do
      s3_new = double("s3_new")
      s3_bucket = double("s3_bucket")
      allow(Aws::S3::Resource).to receive(:new).and_return(s3_new)
      allow(s3_new).to receive(:bucket).and_return(s3_bucket)
      allow(s3_bucket).to receive(:object).and_return(s3_object)
      hls = "#EXTM3U\n#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=854x480,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=1191000\nhls_480p_.m3u8\n"
      hls += "#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=1280x720,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=2805000\nhls_720p_.m3u8\n"
      allow(s3_object).to receive(:get).and_return(double(body: double(read: hls)))
    end
  end

  describe "GET fetch_placeholder_products" do
    it "does not provide any placeholder products" do
      get :fetch_placeholder_products, params: { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, current_product_unique_permalinks: ["mobile_friendly_placeholder_product"] }

      assert_response 200
      expect(response.parsed_body).to eq({ success: true, placeholder_products: [] }.as_json)
    end
  end

  describe "GET url_redirect_attributes" do
    before do
      create(:rich_content, entity: @product, description: [
               { "type" => "fileEmbed", "attrs" => { "id" => @product_file1.external_id, "uid" => SecureRandom.uuid } },
               { "type" => "fileEmbed", "attrs" => { "id" => @product_file3.external_id, "uid" => SecureRandom.uuid } },
               { "type" => "fileEmbed", "attrs" => { "id" => @product_file2.external_id, "uid" => SecureRandom.uuid } },
             ])
    end
    it "provides purchase link and file data if the url redirect is still valid" do
      create(:purchase, url_redirect: @url_redirect, link: @product)

      get :url_redirect_attributes, params: { id: @url_redirect.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }
      assert_response 200
      expect(response).to match_json_schema("api/mobile/url_redirect")

      expect(response.parsed_body).to include(success: true, purchase_valid: true)
      expect(response.parsed_body[:product]).to include(name: "The Works of Edgar Gumstein", description: "A collection of works spanning 1984 — 1994")
      expect(response.parsed_body[:product][:file_data][0]).to include(name_displayable: "kFDzu", description: nil)
      expect(response.parsed_body[:product][:file_data][1]).to include(name_displayable: "magic", description: "A magic song")
      expect(response.parsed_body[:product][:file_data][2]).to include(name_displayable: "test", description: "A picture")
    end

    it "correctly marks if the url_redirect's purchase is invalid" do
      create(:purchase, url_redirect: @url_redirect, purchase_state: "failed", link: @product)
      get :url_redirect_attributes, params: { id: @url_redirect.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }
      assert_response 200
      expect(response.parsed_body).to eq({ success: true, product: @url_redirect.product_json_data, purchase_valid: false }.as_json)
    end

    it "does not return purchase link and file data redirect external id is invalid" do
      get :url_redirect_attributes, params: { id: @url_redirect.external_id + "invalid", mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }
      assert_response 404
      expect(response.parsed_body).to eq({ success: false, message: "Could not find url redirect" }.as_json)
    end

    it "returns files in the correct order" do
      create(:purchase, url_redirect: @url_redirect, link: @product)
      get :url_redirect_attributes, params: { id: @url_redirect.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }
      assert_response 200
      expect(response.parsed_body).to eq({ success: true, product: @url_redirect.product_json_data, purchase_valid: true }.as_json)
      expect(response.parsed_body["product"]["file_data"].map { |file| file["name"] }).to eq ["kFDzu.png", "magic.mp3", "test.png"]
    end

    it "returns only files for specific version purchase" do
      video_product_file = create(:streamable_video)
      pdf_product_file = create(:readable_document)
      @product.product_files = [video_product_file, pdf_product_file]
      variant_category = create(:variant_category, link: @product)
      video_variant = create(:variant, variant_category:)
      video_variant.product_files = [video_product_file]
      pdf_variant = create(:variant, variant_category:)
      pdf_variant.product_files = [pdf_product_file]

      create(:purchase, url_redirect: @url_redirect, link: @product, variant_attributes: [pdf_variant])
      get :url_redirect_attributes, params: { id: @url_redirect.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }
      assert_response 200
      expect(response.parsed_body).to eq({ success: true, product: @url_redirect.product_json_data, purchase_valid: true }.as_json)
      expect(response.parsed_body["product"]["file_data"].map { |file| file["name"] }).to eq ["billion-dollar-company-chapter-0.pdf"]
    end

    it "provides purchase link and file data if the url redirect is still valid" do
      product = create(:subscription_product, price_cents: 100)
      url_redirect = create(:url_redirect, link: product)
      product.product_files << create(:product_file, position: 0, link: product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png")
      subscription = create(:subscription, link: product, cancelled_at: Time.current)
      create(:purchase, url_redirect:, is_original_subscription_purchase: true, purchaser: subscription.user, link: product, subscription:)
      get :url_redirect_attributes, params: { id: url_redirect.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }
      assert_response 200
      expect(response.parsed_body["success"]).to eq true
      expect(response.parsed_body["product"]["file_data"]).to be_nil
    end
  end

  describe "GET stream" do
    let!(:product) do
      @product.product_files << file_1
      @product
    end
    let!(:file_1) do
      create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter2.mp4", is_transcoded_for_hls: true)
    end
    let!(:transcoded_video) do
      create(:transcoded_video, link: product,
                                streamable: file_1,
                                original_video_key: file_1.s3_key,
                                transcoded_video_key: "attachments/2_1/original/chapter2/hls/index.m3u8",
                                is_hls: true, state: "completed")
    end
    let!(:url_redirect) { create(:url_redirect, link: product, purchase: nil) }
    let(:subtitle_en_file_path) { "attachment/english.srt" }
    let(:subtitle_fr_file_path) { "attachment/french.srt" }
    let(:subtitle_url_bucket_url) { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/" }
    let(:subtitle_en_url) { "#{subtitle_url_bucket_url}#{subtitle_en_file_path}" }
    let(:subtitle_fr_url) { "#{subtitle_url_bucket_url}#{subtitle_fr_file_path}" }

    it "returns an unauthorized response if the user does not provide the correct mobile token" do
      get :stream, params: { token: url_redirect.token, product_file_id: file_1.external_id, format: :json }
      expect(response.code).to eq "401"
      expect(response.parsed_body).to eq({ success: false, message: "Invalid request" }.as_json)
    end

    it "returns an unauthorized response if the rental has expired" do
      url_redirect.purchase = create(:purchase, is_rental: true)
      url_redirect.purchase.save!
      url_redirect.update!(is_rental: true, rental_first_viewed_at: 10.days.ago)
      ExpireRentalPurchasesWorker.new.perform
      get :stream, params: { token: url_redirect.token, product_file_id: file_1.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, format: :json }
      expect(response.code).to eq "401"
      expect(response.parsed_body).to eq({ success: false, message: "Your rental has expired." }.as_json)
    end

    it "returns a progressive download url if a m3u8 location does not exist for the product file" do
      expect_any_instance_of(ProductFile).to receive(:hls_playlist).and_return(nil)
      allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)
      progressive_download_url = url_redirect.signed_video_url(file_1)
      expect_any_instance_of(UrlRedirect).to receive(:signed_video_url).and_return(progressive_download_url)
      stub_playlist_s3_object_get.call

      travel_to(Date.parse("2014-01-27")) do
        get :stream, params: { token: url_redirect.token, product_file_id: file_1.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, format: :json }
      end
      expect(response).to be_successful
      expect(response.parsed_body).to eq({ success: true, playlist_url: progressive_download_url, subtitles: [] }.as_json)
    end

    it "returns an m3u8 url if there is an m3u8 file for the product file" do
      stub_playlist_s3_object_get.call
      travel_to(Date.parse("2014-01-27")) do
        get :stream, params: { token: url_redirect.token, product_file_id: file_1.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, format: :json }
      end
      expect(response).to be_successful
      expect(response.parsed_body).to eq({
        success: true,
        playlist_url: api_mobile_hls_playlist_url(url_redirect.token, file_1.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, host: UrlService.api_domain_with_protocol),
        subtitles: []
      }.as_json)
    end

    it "returns an m3u8 url if there is an m3u8 file for the product file" do
      stub_playlist_s3_object_get.call
      travel_to(Date.parse("2014-01-27")) do
        get :stream, params: { token: url_redirect.token, product_file_id: file_1.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, format: :json }
      end
      expect(response).to be_successful
      playlist_link = api_mobile_hls_playlist_url(url_redirect.token, file_1.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, host: UrlService.api_domain_with_protocol)
      expect(response.parsed_body).to eq({ success: true, playlist_url: playlist_link, subtitles: [] }.as_json)
      additional_params = CGI.parse(playlist_link.partition("?").last).reduce({}) { |memo, (k, v)| memo.merge(k.to_sym => v.first) }
      get :hls_playlist, params: { token: url_redirect.token, product_file_id: file_1.external_id }.merge(additional_params)
      expect(response).to be_successful
    end

    it "returns subtitle file information if any subtitle exists" do
      stub_playlist_s3_object_get.call
      subtitle_file_en = create(:subtitle_file, language: "English", url: subtitle_en_url, product_file: file_1)
      subtitle_file_fr = create(:subtitle_file, language: "Français", url: subtitle_fr_url, product_file: file_1)
      allow(s3_object).to receive(:content_length).and_return(100, 105)
      allow(s3_object).to receive(:public_url).and_return(subtitle_en_file_path, subtitle_fr_file_path)
      travel_to Time.current # Freeze time so we can generate the expected URL(that is based on time)
      subtitle_en_path =
        file_1.signed_download_url_for_s3_key_and_filename(subtitle_file_en.s3_key, subtitle_file_en.s3_filename,
                                                           is_video: true)
      subtitle_fr_path =
        file_1.signed_download_url_for_s3_key_and_filename(subtitle_file_fr.s3_key, subtitle_file_fr.s3_filename,
                                                           is_video: true)
      expected_playlist_url = api_mobile_hls_playlist_url(url_redirect.token, file_1.external_id,
                                                          mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
                                                          host: UrlService.api_domain_with_protocol)

      get :stream, params: { token: url_redirect.token, product_file_id: file_1.external_id,
                             mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, format: :json }

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["playlist_url"]).to eq(expected_playlist_url)
      expect(response.parsed_body["subtitles"].size).to eq 2
      expect(response.parsed_body["subtitles"][0]["language"]).to eq subtitle_file_en.language
      expect(response.parsed_body["subtitles"][0]["url"]).to eq(subtitle_en_path)
      expect(response.parsed_body["subtitles"][1]["language"]).to eq subtitle_file_fr.language
      expect(response.parsed_body["subtitles"][1]["url"]).to eq(subtitle_fr_path)
    end

    it "creates the proper consumption events for watching" do
      stub_playlist_s3_object_get.call
      @request.user_agent = "iOSBuyer/1.3 CFNetwork/711.3.18 Darwin/14.3.0"
      travel_to(Date.parse("2014-01-27")) do
        get :stream, params: { token: url_redirect.token, product_file_id: file_1.external_id,
                               mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN },  format: :json
      end
      expect(response).to be_successful
      expect(ConsumptionEvent.count).to eq 1
      event = ConsumptionEvent.last
      expect(event.product_file_id).to eq file_1.id
      expect(event.url_redirect_id).to eq url_redirect.id
      expect(event.purchase_id).to eq nil
      expect(event.event_type).to eq ConsumptionEvent::EVENT_TYPE_WATCH
      expect(event.platform).to eq Platform::IPHONE
      expect(event.ip_address).to eq @request.remote_ip

      @request.user_agent = "Dalvik/2.1.0 (Linux; U; Android 5.0.1; Android SDK built for x86 Build/LSX66B)"
      travel_to(Date.parse("2014-01-27")) do
        get :stream, params: { token: url_redirect.token, product_file_id: file_1.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }, format: :json
      end
      expect(response).to be_successful
      expect(ConsumptionEvent.count).to eq 2
      event = ConsumptionEvent.last
      expect(event.product_file_id).to eq file_1.id
      expect(event.url_redirect_id).to eq url_redirect.id
      expect(event.purchase_id).to eq nil
      expect(event.event_type).to eq ConsumptionEvent::EVENT_TYPE_WATCH
      expect(event.platform).to eq Platform::ANDROID
      expect(event.ip_address).to eq @request.remote_ip
    end

    it "increments the uses count on the url_redirect" do
      stub_playlist_s3_object_get.call
      expect do get :stream, params: { token: url_redirect.token,
                                       product_file_id: file_1.external_id,
                                       mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
                                       format: :json }
      end.to change { url_redirect.reload.uses }.from(0).to(1)
    end
  end

  describe "GET hls_playlist" do
    before do
      product = create(:product)
      @file_1 = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter2.mp4", is_transcoded_for_hls: true)
      product.product_files << @file_1
      create(:transcoded_video, link: product,
                                streamable: @file_1,
                                original_video_key: @file_1.s3_key,
                                transcoded_video_key: "attachments/2_1/original/chapter2/hls/index.m3u8",
                                is_hls: true, state: "completed")
      @url_redirect = create(:url_redirect, link: product, purchase: nil)
    end

    it "sets the rental_first_viewed_at property for a rental" do
      stub_playlist_s3_object_get.call
      @url_redirect.update!(is_rental: true)
      now = Date.parse("2015-03-10")

      travel_to(now) do
        get :hls_playlist, params: { token: @url_redirect.token, product_file_id: @file_1.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }
      end

      expect(response).to be_successful
      expect(@url_redirect.reload.rental_first_viewed_at).to eq(now)
    end

    it "creates consumption event" do
      @request.user_agent = "iOSBuyer/1.3 CFNetwork/711.3.18 Darwin/14.3.0"

      stub_playlist_s3_object_get.call
      travel_to(Date.parse("2015-03-10")) do
        expect do
          get :hls_playlist, params: { token: @url_redirect.token, product_file_id: @file_1.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }
        end.to change(ConsumptionEvent, :count).by(1)
      end
      expect(response).to be_successful

      event = ConsumptionEvent.last
      expect(event.product_file_id).to eq @file_1.id
      expect(event.url_redirect_id).to eq @url_redirect.id
      expect(event.purchase_id).to eq @url_redirect.purchase_id
      expect(event.link_id).to eq @url_redirect.link_id
      expect(event.event_type).to eq ConsumptionEvent::EVENT_TYPE_WATCH
      expect(event.platform).to eq Platform::IPHONE
    end

    it "never displays a confirmation page for mobile stream urls" do
      @url_redirect.mark_as_seen
      @url_redirect.increment!(:uses, 1)
      @request.remote_ip = "123.4.5.6"
      stub_playlist_s3_object_get.call
      travel_to Date.parse("2014-01-27")

      10.times do
        get :hls_playlist, params: { token: @url_redirect.token, product_file_id: @file_1.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }

        expect(response).to be_successful
        expect(response.body =~ /,CODECS=.+$/).to be_truthy
      end
      expect(@url_redirect.uses).to eq 1
    end
  end

  describe "GET download" do
    before do
      @product.product_files = [create(
        :product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4"
      ),
                                create(
                                  :product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter2.mp4"
                                )]
      @url_redirect = create(:url_redirect, link: @product, purchase: nil)
    end

    it "increments the uses count on the url_redirect" do
      allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(100)

      expect do
        get :download, params: { token: @url_redirect.token,
                                 product_file_id: @product.product_files.first.external_id,
                                 mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }
      end.to change { @url_redirect.reload.uses }.from(0).to(1)
    end

    it "never displays a confirmation page for download urls" do
      s3_url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4?AWSAccessKeyId=AKIAIKFZLOLAPOKIC6EA&"
      s3_url += "Expires=1386261022&Signature=FxVDOkutrgrGFLWXISp0JroWFLo%3D&response-content-disposition=attachment"
      allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)
      allow_any_instance_of(UrlRedirect).to receive(:signed_download_url_for_s3_key_and_filename)
                                              .with("attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4", "chapter1.mp4", { is_video: true })
                                              .and_return(s3_url)
      @url_redirect.mark_as_seen
      @url_redirect.increment!(:uses, 1)
      @request.remote_ip = "123.4.5.6"
      loc_url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4?AWSAccessKeyId=AKIAIKFZLOLAPOKIC6EA&"
      loc_url += "Expires=1386261022&Signature=FxVDOkutrgrGFLWXISp0JroWFLo%3D&response-content-disposition=attachment"
      @request.user_agent = "iOSBuyer/1.3 CFNetwork/711.3.18 Darwin/14.3.0"

      10.times do
        get :download, params: { token: @url_redirect.token, product_file_id: @product.product_files.first.external_id, mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN }
        expect(response.code.to_i).to eq 302
        expect(response.headers["Location"]).to eq loc_url
      end

      expect(@url_redirect.uses).to eq 1
      expect(ConsumptionEvent.count).to eq 10
      event = ConsumptionEvent.last
      expect(event.product_file_id).to eq @product.product_files.first.id
      expect(event.url_redirect_id).to eq @url_redirect.id
      expect(event.purchase_id).to eq nil
      expect(event.link_id).to eq @product.id
      expect(event.event_type).to eq ConsumptionEvent::EVENT_TYPE_DOWNLOAD
      expect(event.platform).to eq Platform::IPHONE
      expect(event.ip_address).to eq @request.remote_ip
    end

    it "creates consumption event" do
      allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(100)

      @request.user_agent = "iOSBuyer/1.3 CFNetwork/711.3.18 Darwin/14.3.0"

      product_file = @product.product_files.first
      expect do
        get :download, params: {
          token: @url_redirect.token,
          product_file_id: product_file.external_id,
          mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN
        }
      end.to change(ConsumptionEvent, :count).by(1)
      expect(response).to be_redirect

      event = ConsumptionEvent.last
      expect(event.product_file_id).to eq product_file.id
      expect(event.url_redirect_id).to eq @url_redirect.id
      expect(event.purchase_id).to eq @url_redirect.purchase_id
      expect(event.link_id).to eq @url_redirect.link_id
      expect(event.event_type).to eq ConsumptionEvent::EVENT_TYPE_DOWNLOAD
      expect(event.platform).to eq Platform::IPHONE
    end
  end
end
