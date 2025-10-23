# frozen_string_literal: true

describe "Mobile API Request Specs" do
  before do
    @product = create(:product)
  end

  describe "product download urls" do
    before do
      base_url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4"
      @product.product_files << @product.product_files << create(:product_file, url: base_url)
      purchase = create(:purchase_with_balance, link: @product)
      @url_redirect = purchase.url_redirect
      @url_redirect.mark_as_seen
      @url_redirect.increment!(:uses, 1)
      query = "AWSAccessKeyId=AKIAIKFZLOLAPOKIC6EA&Expires=1386261022&Signature=FxVDOkutrgrGFLWXISp0JroWFLo%3D&"
      query += "response-content-disposition=attachment"
      @download_url = "#{base_url}?#{query}"
      allow_any_instance_of(UrlRedirect).to receive(:signed_download_url_for_s3_key_and_filename)
                                            .with("attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4", "chapter1.mp4", { is_video: true })
                                            .and_return(@download_url)
    end

    it "redirects to download URL" do
      10.times do
        get @url_redirect.product_json_data[:file_data].last[:download_url]
        expect(response.code.to_i).to eq 302
        expect(response.location).to eq @download_url
      end
    end
  end

  describe "external link url" do
    before do
      @url_redirect = create(:url_redirect, link: @product, purchase: nil)
    end

    it "adds external_link_url for external link files" do
      @product.product_files << create(:product_file, url: "http://www.gumroad.com", filetype: "link")

      expect(@url_redirect.product_json_data[:file_data].last.key?(:external_link_url)).to eq(true)
      expect(@url_redirect.product_json_data[:file_data].last[:external_link_url]).to eq("http://www.gumroad.com")
    end

    it "does not add external_link_url for non external link files" do
      @product.product_files << create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter2.mp4")

      expect(@url_redirect.product_json_data[:file_data].last.key?(:external_link_url)).to eq(false)
    end
  end

  it "serves stream urls that are usable" do
    @product.product_files << create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter2.mp4", is_transcoded_for_hls: true)
    @transcoded_video = create(:transcoded_video, link: @product, streamable: @product.product_files.last, original_video_key: @product.product_files.last.s3_key,
                                                  transcoded_video_key: "attachments/2_1/original/chapter2/hls/index.m3u8", is_hls: true,
                                                  state: "completed")
    url_redirect = create(:url_redirect, link: @product, purchase: nil)
    url_redirect.mark_as_seen
    url_redirect.increment!(:uses, 1)
    s3_new = double("s3_new")
    s3_bucket = double("s3_bucket")
    s3_object = double("s3_object")
    allow(Aws::S3::Resource).to receive(:new).and_return(s3_new)
    allow(s3_new).to receive(:bucket).and_return(s3_bucket)
    allow(s3_bucket).to receive(:object).and_return(s3_object)
    hls = "#EXTM3U\n#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=854x480,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=1191000\nhls_480p_.m3u8\n"
    hls += "#EXT-X-STREAM-INF:PROGRAM-ID=1,RESOLUTION=1280x720,CODECS=\"avc1.4d001f,mp4a.40.2\",BANDWIDTH=2805000\nhls_720p_.m3u8\n"
    allow(s3_object).to receive(:get).and_return(double(body: double(read: hls)))
    10.times do
      get url_redirect.product_json_data[:file_data].last[:streaming_url] + "?mobile_token=#{Api::Mobile::BaseController::MOBILE_TOKEN}"
      expect(response.code.to_i).to eq 200
    end
  end

  it "sets the url redirect attributes" do
    url_redirect = create(:url_redirect, link: @product)

    expect(url_redirect.product_json_data).to include(
      url_redirect_external_id: url_redirect.external_id,
      url_redirect_token: url_redirect.token
    )
  end
end
