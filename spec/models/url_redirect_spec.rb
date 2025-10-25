# frozen_string_literal: true

require "spec_helper"

describe UrlRedirect do
  before do
    allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)
    @good_kindle_email = "maxwell_1234@kindle.com"
  end

  it "has a token that is unique" do
    url_redirect = create(:url_redirect)
    expect(url_redirect.token).to_not be(nil)
    expect(url_redirect.token.size).to be > 10
  end

  describe "product_files_hash" do
    let(:product) { create(:product) }
    let!(:readable_document) { create(:readable_document, link: product) }
    let!(:video) { create(:streamable_video, link: product) }
    let!(:stream_only_video) { create(:streamable_video, stream_only: true, link: product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/43a5363194e74e9ee75b6203eaea6705/original/episode2.mp4") }
    let!(:deleted_file) { create(:listenable_audio, deleted_at: Time.current) }
    let(:purchase) { create(:purchase, link: product) }
    let(:url_redirect) { create(:url_redirect, purchase:) }

    before do
      allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)
    end

    it "only contains alive, non-stream only product files" do
      travel_to(Time.current) do
        product_files_hash = JSON.parse(url_redirect.product_files_hash)

        expect(product_files_hash.length).to eq 2

        expect(product_files_hash).to include("url" => purchase.url_redirect.signed_location_for_file(readable_document),
                                              "filename" => readable_document.s3_filename)
        expect(product_files_hash).to include("url" => purchase.url_redirect.signed_location_for_file(video),
                                              "filename" => video.s3_filename)
        expect(product_files_hash).to_not include("url" => purchase.url_redirect.signed_location_for_file(stream_only_video),
                                                  "filename" => stream_only_video.s3_filename)
        expect(product_files_hash).to_not include("url" => purchase.url_redirect.signed_location_for_file(deleted_file),
                                                  "filename" => deleted_file.s3_filename)
      end
    end
  end

  describe "referenced_link" do
    describe "test purchase" do
      before do
        @product = create(:product)
        @url_redirect = create(:url_redirect, link: @product, purchase: nil)
      end

      it "returns the correct link" do
        expect(@url_redirect.referenced_link).to eq @product
      end
    end

    describe "imported_customer" do
      before do
        @product = create(:product)
        @imported_customer = create(:imported_customer, link: @product, importing_user: @product.user)
        @url_redirect = create(:url_redirect, link: @product, imported_customer: @imported_customer, purchase: nil)
      end

      it "returns the correct link for an imported_customer without a url_redirect" do
        expect(@url_redirect.referenced_link).to eq @product
      end
    end

    describe "normal purchase" do
      before do
        @product = create(:product)
        @purchase = create(:purchase, link: @product)
        @url_redirect = create(:url_redirect, purchase: @purchase)
      end

      it "returns the correct link" do
        expect(@url_redirect.referenced_link).to eq @product
      end
    end
  end

  describe "url" do
    before do
      @url_redirect = create(:url_redirect)
    end

    it "returns the correct url" do
      expect(@url_redirect.url).to eq "http://#{DOMAIN}/r/#{@url_redirect.token}"
    end
  end

  describe "redirect_or_s3_location" do
    describe "imported_customer" do
      before do
        @product = create(:product)
        @imported_customer = create(:imported_customer, link: @product, importing_user: @product.user)
        travel_to(Time.current)
      end

      it "returns the right url when there is no provided url redirect for and installment" do
        @url_redirect = create(:url_redirect, link: @product, imported_customer: @imported_customer, purchase: nil)
        @installment = create(:installment, link: @product, installment_type: "product")
        @product.product_files << create(
          :product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/43a5363194e74e9ee75b6203eaea6705/original/manual.pdf"
        )
        expect(@url_redirect.redirect_or_s3_location).to eq @url_redirect.signed_location_for_file(@product.alive_product_files.first)
      end

      it "returns the file url for an external link file" do
        @url_redirect = create(:url_redirect, link: @product, purchase: nil)
        @product.product_files << create(:product_file, url: "http://gumroad.com", filetype: "link")
        expect(@url_redirect.redirect_or_s3_location).to eq @url_redirect.signed_location_for_file(@product.alive_product_files.first)
      end

      it "returns the right url when there is no provided url redirect for an installment and there are multiple files" do
        @url_redirect = create(:url_redirect, link: @product, imported_customer: @imported_customer, purchase: nil)
        @installment = create(:installment, link: @product, installment_type: "product")
        3.times do
          @product.product_files << create(
            :product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/43a5363194e74e9ee75b6203eaea6705/original/manual.pdf"
          )
        end
        expect(@url_redirect.redirect_or_s3_location).to eq @url_redirect.download_page_url
      end

      it "returns the right url when there is a provided url redirect for an installment" do
        @installment = create(:installment, link: @product, installment_type: "product")
        url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4"
        @installment.product_files << create(:product_file, url:)
        @installment_url_redirect = create(:url_redirect, installment: @installment, imported_customer: @imported_customer, link: @product)
        @product.product_files << create(:product_file, url:)
        url = "https://d3t5lixau6dhwk.cloudfront.net/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4?response-content-disposition="
        url += "attachment&Expires=1414098718&Signature=gidpQSe4zFcVs5K9fTzno4wb3RTJrDlwX3s4I4zC1FVaNNSDmMlUj2Vqkaa8S7X7mE4Ep4BHtn+"
        url += "ZZa8aEJ4WM4JC4fXQJLElrR4XNNOq8UfXsVX6CwNGLeZQue1rCpq9Gj3anqml5zj1jrSGr3qGk6P4eeKJy6y1D5XF51CE0no=&Key-Pair-Id=APKAISH5PKOS7WQUJ6SA"
        expect_any_instance_of(UrlRedirect).to receive(:signed_download_url_for_s3_key_and_filename)
          .with("attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4", "chapter1.mp4", { is_video: true }).and_return(url)
        url =  "https://d3t5lixau6dhwk.cloudfront.net/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4?response-content-disposition="
        url += "attachment&Expires=1414098718&Signature=gidpQSe4zFcVs5K9fTzno4wb3RTJrDlwX3s4I4zC1FVaNNSDmMlUj2Vqkaa8S7X7mE4Ep4BHtn+ZZa8"
        url += "aEJ4WM4JC4fXQJLElrR4XNNOq8UfXsVX6CwNGLeZQue1rCpq9Gj3anqml5zj1jrSGr3qGk6P4eeKJy6y1D5XF51CE0no=&Key-Pair-Id=APKAISH5PKOS7WQUJ6SA"
        expect(@installment_url_redirect.redirect_or_s3_location)
          .to eq(url)
      end
    end
  end

  describe "#is_file_downloadable" do
    let(:product) { create(:product) }
    let(:url_redirect) { create(:url_redirect, link: product) }

    it "returns false if product is a rental and file is streamable" do
      url_redirect.update!(is_rental: true)
      product_file = create(:streamable_video, link: product)

      expect(url_redirect.is_file_downloadable?(product_file)).to eq(false)
    end

    it "returns false if file is an external link" do
      product_file = create(:external_link, link: product)

      expect(url_redirect.is_file_downloadable?(product_file)).to eq(false)
    end

    it "returns false if file is stream-only" do
      product_file = create(:streamable_video, stream_only: true, link: product)

      expect(url_redirect.is_file_downloadable?(product_file)).to eq(false)
    end

    it "returns true if file can be downloaded" do
      product_file = create(:readable_document, link: product)

      expect(url_redirect.is_file_downloadable?(product_file)).to eq(true)
    end
  end

  describe "#entity_archive" do
    before do
      @product = create(:product)
      @url_redirect = create(:url_redirect, link: @product, purchase: create(:purchase, link: @product, purchaser: create(:user)))
      create(:product_files_archive, link: @product, product_files_archive_state: :ready)
      @last_product_files_archive = create(:product_files_archive, link: @product, product_files_archive_state: :ready)
    end

    it "returns the most recent archive" do
      expect(@url_redirect.entity_archive).to eq(@last_product_files_archive)
    end

    it "returns nil if product has stampable pdfs" do
      @product.product_files << create(:readable_document, pdf_stamp_enabled: true)

      expect(@url_redirect.entity_archive).to eq(nil)
    end
  end

  describe "#folder_archive" do
    before do
      @product = create(:product)
      @folder_id = SecureRandom.uuid
      folder_archive1 = @product.product_files_archives.create!(folder_id: @folder_id)
      folder_archive1.mark_in_progress!
      folder_archive1.mark_ready!

      @folder_archive2 = @product.product_files_archives.create!(folder_id: @folder_id)
      @folder_archive2.mark_in_progress!
      @folder_archive2.mark_ready!

      purchase = create(:purchase, link: @product, purchaser: create(:user))
      @url_redirect = create(:url_redirect, link: @product, purchase:)
    end

    it "returns the most recent archive" do
      expect(@url_redirect.folder_archive(@folder_id)).to eq(@folder_archive2)
    end

    it "returns nil if product has stampable pdfs" do
      @product.product_files << create(:readable_document, pdf_stamp_enabled: true)

      expect(UrlRedirect.find(@url_redirect.id).folder_archive(@folder_id)).to eq(nil)
    end
  end

  describe "streaming" do
    before do
      @product = create(:product)
      @product.product_files << create(
        :product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/43a5363194e74e9ee75b6203eaea6705/original/episode1.mp4"
      )
      @product.product_files << create(
        :product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/43a5363194e74e9ee75b6203eaea6705/original/episode2.mp4"
      )
      @product.product_files << create(
        :product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/43a5363194e74e9ee75b6203eaea6705/original/manual.pdf"
      )
      @product.save!
      @url_redirect = create(:url_redirect, link: @product, purchase: nil)
    end

    it "creates the right signed url for a file" do
      signed_s3_url = @url_redirect.signed_location_for_file(@product.product_files.first)
      expect(signed_s3_url).to match(/verify=/)
      expect(signed_s3_url).to match(/episode1/)
      expect(signed_s3_url).to_not match(/episode2/)
      expect(signed_s3_url).to_not match(/manual/)
    end

    it "creates the correct signed URL for a stamped pdf" do
      pdf_product_file = @product.product_files.alive.pdf.last
      pdf_product_file.update!(pdf_stamp_enabled: true)
      url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/43a5363194e74e9ee75b6203eaea6705/original/stamped_manual.pdf"
      @url_redirect.stamped_pdfs.create!(product_file: pdf_product_file, url:)
      signed_s3_url = @url_redirect.signed_location_for_file(pdf_product_file)
      expect(signed_s3_url).to match(/verify=/)
      expect(signed_s3_url).to match(/stamped_manual/)
    end
  end

  describe "product_file_json_data_for_mobile" do
    context "when there is an associated purchase" do
      it "contains the purchase information if there is an associated purchase" do
        product = create(:product)
        product.product_files << create(
          :product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/6996320f4de6424990904fcda5808cef/original/Don&amp;#39;t Stop.mp3"
        )
        product.product_files << create(
          :product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/a1a5b8c8c38749e2b3cb27099a817517/original/Alice&#39;s Adventures in Wonderland.pdf"
        )
        purchase = create(:purchase, link: product, purchaser: create(:user))
        url_redirect = create(:url_redirect, link: product, purchase:)

        product_json = url_redirect.product_json_data
        expect(product_json[:purchased_at]).to eq purchase.created_at
        expect(product_json[:user_id]).to eq purchase.purchaser.external_id
      end

      it "includes deprecated `custom_delivery_url` attribute" do
        product = create(:product)
        purchase = create(:purchase, link: product)
        url_redirect = create(:url_redirect, link: product, purchase:)

        expect(url_redirect.product_json_data).to include(custom_delivery_url: nil)
      end
    end
  end

  describe "#video_files_playlist" do
    let(:product) { create(:product) }
    let(:file2) { create(:product_file, link: product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter2.mp4", position: 3) }
    let(:file4) { create(:product_file, link: product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/4/original/chapter4.mp4", position: 0) }
    let(:file1) { create(:product_file, link: product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/1/original/chapter1.mp4", position: 2) }
    let(:file3) { create(:product_file, link: product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/3/original/chapter3.mp4", position: 1) }

    before do
      allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)

      product.product_files = [file2, file4, file1, file3]
      product.save!
    end

    context "when the purchased product has rich content" do
      let(:rich_content_description) do [
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] },
        { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "World" }] },
        { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Lorem ipsum" }] },
        { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
        { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
      ] end

      context "when the purchase is associated with the product" do
        let(:purchase) { build(:purchase, link: product) }
        let(:url_redirect) { create(:url_redirect, link: product, purchase:) }
        let!(:rich_content) { create(:product_rich_content, entity: product, description: rich_content_description) }

        it "returns the video files playlist with files ordered by how they appear in the product-level rich content" do
          video_playlist = url_redirect.video_files_playlist(file1)[:playlist]
          expect(video_playlist.size).to eq 4
          expect(video_playlist[0][:sources][1]).to include file1.s3_filename
          expect(video_playlist[1][:sources][1]).to include file2.s3_filename
          expect(video_playlist[2][:sources][1]).to include file3.s3_filename
          expect(video_playlist[3][:sources][1]).to include file4.s3_filename
        end
      end

      context "when the purchase is associated with a product variant" do
        let(:category) { create(:variant_category, link: product) }
        let(:variant1) { create(:variant, variant_category: category, product_files: [file1, file3, file4, file2]) }
        let(:variant2) { create(:variant, variant_category: category, product_files: [file2]) }
        let(:purchase) { build(:purchase, link: product, variant_attributes: [variant1]) }
        let(:url_redirect) { create(:url_redirect, link: product, purchase:) }
        let!(:variant1_rich_content) { create(:product_rich_content, entity: variant1, description: rich_content_description) }
        let!(:variant2_rich_content) { create(:product_rich_content, entity: variant2, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }, { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } }]) }

        it "returns the video files playlist with files ordered by how they appear in the variant-level rich content" do
          video_playlist = url_redirect.video_files_playlist(file1)[:playlist]
          expect(video_playlist.size).to eq 4
          expect(video_playlist[0][:sources][1]).to include file1.s3_filename
          expect(video_playlist[1][:sources][1]).to include file2.s3_filename
          expect(video_playlist[2][:sources][1]).to include file3.s3_filename
          expect(video_playlist[3][:sources][1]).to include file4.s3_filename
        end
      end
    end

    it "returns the video files playlist with files ordered by their position for an installment" do
      installment = create(:installment)
      installment.product_files = [file2, file4, file1, file3]
      url_redirect = create(:installment_url_redirect, installment:)
      url_redirect_id = url_redirect.id

      video_playlist = url_redirect.video_files_playlist(file2)[:playlist]
      expect(video_playlist.size).to eq 4
      expect(video_playlist[0][:sources][1]).to include file4.s3_filename
      expect(video_playlist[1][:sources][1]).to include file3.s3_filename
      expect(video_playlist[2][:sources][1]).to include file1.s3_filename
      expect(video_playlist[3][:sources][1]).to include file2.s3_filename

      [file1, file2, file3, file4].each_with_index do |file, index|
        file.position = index
        file.save!
      end

      url_redirect = UrlRedirect.find(url_redirect_id) # clears the cached #alive_product_files
      video_playlist = url_redirect.video_files_playlist(file2)[:playlist]
      expect(video_playlist.size).to eq 4
      expect(video_playlist[0][:sources][1]).to include file1.s3_filename
      expect(video_playlist[1][:sources][1]).to include file2.s3_filename
      expect(video_playlist[2][:sources][1]).to include file3.s3_filename
      expect(video_playlist[3][:sources][1]).to include file4.s3_filename
    end

    it "sets the `index_to_play` to 0 if there are no files to include" do
      url_redirect = create(:url_redirect, link: product, purchase: build(:purchase, link: product))
      product.product_files.destroy_all

      expect(url_redirect.video_files_playlist(file2)[:index_to_play]).to eq(0)
    end

    it "sets the `index_to_play` to 0 if the initial_product_file is not a part of the products belonging to the UrlRedirect" do
      url_redirect = create(:url_redirect, link: product, purchase: build(:purchase, link: product))

      expect(url_redirect.video_files_playlist(create(:product_file))[:index_to_play]).to eq(0)
    end
  end

  describe "#html5_video_url_and_guid_for_product_file" do
    before do
      @multifile_product = create(:product)
      @file_1 = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter2.mp4")
      @multifile_product.product_files << @file_1
      @file_2 = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/3/original/chapter3.mp4")
      @multifile_product.product_files << @file_2
      @multifile_url_redirect = create(:url_redirect, link: @multifile_product, purchase: nil)

      allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)
    end

    it "returns the video URL and GUID for the file" do
      expected_video_url = @multifile_url_redirect.signed_video_url(@file_1)
      expected_guid = expected_video_url[described_class::GUID_GETTER_FROM_S3_URL_REGEX, 1]
      expected_video_url.sub!(expected_guid, described_class::FAKE_VIDEO_URL_GUID_FOR_OBFUSCATION)

      video_url, guid = @multifile_url_redirect.send(:html5_video_url_and_guid_for_product_file, @file_1)
      expect(video_url).to eq(expected_video_url)
      expect(guid).to eq(expected_guid)

      expected_video_url = @multifile_url_redirect.signed_video_url(@file_2)
      expected_guid = expected_video_url[described_class::GUID_GETTER_FROM_S3_URL_REGEX, 1]
      expected_video_url.sub!(expected_guid, described_class::FAKE_VIDEO_URL_GUID_FOR_OBFUSCATION)

      video_url, guid = @multifile_url_redirect.send(:html5_video_url_and_guid_for_product_file, @file_2)
      expect(video_url).to eq(expected_video_url)
      expect(guid).to eq(expected_guid)
    end
  end

  describe "#update_rental_expired" do
    it "updates purchase rental_expired if is_rental is set to false" do
      url_redirect = create(:url_redirect, is_rental: true)
      url_redirect.update!(is_rental: false)
      expect(url_redirect.purchase.rental_expired).to eq(nil)
    end
  end

  describe "#with_product_files" do
    it "returns the correct object when associated with an installment" do
      product = create(:product_with_files)
      purchase = create(:purchase, link: product)
      installment = create(:installment, link: product, installment_type: "product")
      installment.product_files << product.product_files.first
      installment.save!
      url_redirect = create(:url_redirect, link: product, purchase:, installment:)
      expect(url_redirect.with_product_files).to eq installment
    end

    it "returns the correct object when associated with a product" do
      product = create(:product)
      purchase = create(:purchase, link: product)
      url_redirect = create(:url_redirect, purchase:)
      expect(url_redirect.with_product_files).to eq product
    end

    context "for a variant" do
      before do
        @product = create(:product_with_files)
        @variant = create(:variant, variant_category: create(:variant_category, link: @product))
        @variant.product_files << @product.product_files.first
        @purchase = create(:purchase, link: @variant.link, variant_attributes: [@variant])
        @url_redirect = create(:url_redirect, purchase: @purchase)
      end

      context "when the variant has no associated product files" do
        before do
          @variant.product_files = []
          @variant.save!
        end

        it "returns the variant" do
          expect(@url_redirect.with_product_files).to eq(@variant)
        end
      end

      it "returns the correct object" do
        expect(@url_redirect.with_product_files).to eq @variant
      end

      it "returns the correct object when associated with a variant that has been deleted" do
        @variant.mark_deleted!
        expect(@url_redirect.reload.with_product_files).to eq @variant
      end

      it "returns the object for the non-deleted variant if only some variants have been deleted" do
        @variant.mark_deleted!
        live_variant = create(:variant, variant_category: create(:variant_category, link: @product))
        @variant.product_files << @product.product_files.last
        @purchase.variant_attributes << live_variant

        expect(@url_redirect.reload.with_product_files).to eq live_variant
      end
    end
  end

  describe "#rich_content_json" do
    it "returns empty hash if there's no associated object" do
      url_redirect = create(:url_redirect)

      expect(url_redirect.rich_content_json).to eq([])
    end

    it "returns nil when associated with an installment" do
      product = create(:product_with_files)
      create(:product_rich_content, entity: product)
      purchase = create(:purchase, link: product)
      installment = create(:installment, link: product, installment_type: "product")
      installment.product_files << product.product_files.first
      installment.save!
      url_redirect = create(:url_redirect, link: product, purchase:, installment:)

      expect(url_redirect.rich_content_json).to be_nil
    end

    context "when associated with a variant" do
      before do
        @product = create(:product_with_files)
        create(:rich_content, entity: @product, title: "Product-level page", description: [{ "type" => "paragraph", "content" => [{ "text" => "This is product-level rich content", "type" => "text" }] }])
        @variant = create(:variant, variant_category: create(:variant_category, link: @product), price_difference_cents: 100)
        @variant.product_files << @product.product_files.first
        create(:rich_content, entity: @variant, title: "Variant-level page", description: [{ "type" => "paragraph", "content" => [{ "text" => "This is variant-level rich content", "type" => "text" }] }])
        @purchase = create(:purchase, link: @variant.link, variant_attributes: [@variant])
        @url_redirect = create(:url_redirect, purchase: @purchase)
      end

      context "when associated product's `has_same_rich_content_for_all_variants` is set to true" do
        before do
          @product.update!(has_same_rich_content_for_all_variants: true)
        end

        it "returns the product-level rich content" do
          rich_content = @product.alive_rich_contents.first
          expect(@url_redirect.rich_content_json).to eq([{ id: rich_content.external_id, page_id: rich_content.external_id, variant_id: nil, title: "Product-level page", description: { type: "doc", content: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "This is product-level rich content" }] }] }, updated_at: rich_content.updated_at }])
        end
      end

      context "when associated product's `has_same_rich_content_for_all_variants` is set to false" do
        before do
          @product.update!(has_same_rich_content_for_all_variants: false)
        end

        it "returns the variant-level rich content" do
          rich_content = @variant.alive_rich_contents.first
          expect(@url_redirect.rich_content_json).to eq([{ id: rich_content.external_id, page_id: rich_content.external_id, variant_id: @variant.external_id, title: "Variant-level page", description: { type: "doc", content: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "This is variant-level rich content" }] }] }, updated_at: rich_content.updated_at }])
        end
      end

      it "returns the rich content of the cheapest variant when the purchase is associated with a deleted variant" do
        @product.alive_rich_contents.find_each(&:mark_deleted!)

        variant_category = create(:variant_category, link: @product)
        old_variant = create(:variant, variant_category:, price_difference_cents: 100, product_files: @product.product_files)
        variant1 = create(:variant, variant_category:, price_difference_cents: 100, product_files: @product.product_files)
        variant2 = create(:variant, variant_category:, price_difference_cents: 50, product_files: @product.product_files)
        old_variant_rich_content = create(:rich_content, entity: old_variant, title: "Old variant page title", description: [{ "type" => "paragraph", "content" => [{ "text" => "Lorem ipsum", "type" => "text" }] }])
        create(:rich_content, entity: variant1, title: "Variant 1 page title", description: [{ "type" => "paragraph", "content" => [{ "text" => "Lorem ipsum", "type" => "text" }] }])
        variant2_rich_content = create(:rich_content, entity: variant2, title: "Variant 2 page title", description: [{ "type" => "paragraph", "content" => [{ "text" => "Lorem ipsum", "type" => "text" }] }])

        @purchase.variant_attributes = [old_variant]

        expect(@url_redirect.rich_content_json).to eq([{ id: old_variant_rich_content.external_id, page_id: old_variant_rich_content.external_id, variant_id: old_variant.external_id, title: "Old variant page title", description: { type: "doc", content: old_variant_rich_content.description }, updated_at: old_variant_rich_content.updated_at }])

        old_variant.mark_deleted!
        old_variant.alive_rich_contents.find_each(&:mark_deleted!)

        expect(UrlRedirect.find(@url_redirect.id).rich_content_json).to eq([{ id: variant2_rich_content.external_id, page_id: variant2_rich_content.external_id, variant_id: variant2.external_id, title: "Variant 2 page title", description: { type: "doc", content: variant2_rich_content.description }, updated_at: variant2_rich_content.updated_at }])
      end

      it "returns the product-level rich content when the purchase is associated with a deleted variant and there are no other variants" do
        old_variant_rich_content = @variant.alive_rich_contents.first
        expect(@url_redirect.rich_content_json).to eq([{ id: old_variant_rich_content.external_id, page_id: old_variant_rich_content.external_id, variant_id: @variant.external_id, title: "Variant-level page", description: { type: "doc", content: old_variant_rich_content.description }, updated_at: old_variant_rich_content.updated_at }])

        @variant.mark_deleted!
        @variant.alive_rich_contents.find_each(&:mark_deleted!)

        product_level_rich_content = @product.alive_rich_contents.first
        expect(UrlRedirect.find(@url_redirect.id).rich_content_json).to eq([{ id: product_level_rich_content.external_id, page_id: product_level_rich_content.external_id, variant_id: nil, title: "Product-level page", description: { type: "doc", content: product_level_rich_content.description }, updated_at: product_level_rich_content.updated_at }])
      end
    end

    context "when associated with a product" do
      before do
        @product = create(:product_with_files)
        @rich_content = create(:product_rich_content, entity: @product, title: "Page title", description: [{ "type" => "paragraph", "content" => [{ "text" => "Lorem ipsum", "type" => "text" }] }])
        @purchase = create(:purchase, link: @product)
        @url_redirect = create(:url_redirect, purchase: @purchase)
      end

      it "returns product-level rich content" do
        expect(@url_redirect.rich_content_json).to eq([{ id: @rich_content.external_id, page_id: @rich_content.external_id, variant_id: nil, title: "Page title", description: { type: "doc", content: @rich_content.description }, updated_at: @rich_content.updated_at }])
      end

      it "returns the rich content of the cheapest variant when the purchase is associated with the product but there are variants" do
        variant_category = create(:variant_category, link: @product)
        variant1 = create(:variant, variant_category:, price_difference_cents: 100, product_files: @product.product_files)
        variant2 = create(:variant, variant_category:, price_difference_cents: 50, product_files: @product.product_files)
        create(:rich_content, entity: variant1, title: "Variant 1 page title", description: [{ "type" => "paragraph", "content" => [{ "text" => "Lorem ipsum", "type" => "text" }] }])
        variant2_rich_content = create(:rich_content, entity: variant2, title: "Variant 2 page title", description: [{ "type" => "paragraph", "content" => [{ "text" => "Lorem ipsum", "type" => "text" }] }])

        # On adding a variant, the product-level rich content gets deleted automatically
        @product.alive_rich_contents.find_each(&:mark_deleted!)

        expect(@url_redirect.rich_content_json).to eq([{ id: variant2_rich_content.external_id, page_id: variant2_rich_content.external_id, variant_id: variant2.external_id, title: "Variant 2 page title", description: { type: "doc", content: variant2_rich_content.description }, updated_at: variant2_rich_content.updated_at }])
      end
    end

    context "when associated with a completed commission", :vcr do
      let(:commission) { create(:commission, status: Commission::STATUS_COMPLETED) }

      before do
        commission.files.attach(file_fixture("smilie.png"))
        commission.files.attach(file_fixture("test.pdf"))
        commission.deposit_purchase.create_url_redirect!
      end

      it "includes commission files in the rich content json" do
        rich_content_json = commission.deposit_purchase.url_redirect.rich_content_json

        expect(rich_content_json).to eq(
          [
            {
              id: "",
              page_id: "",
              title: "Downloads",
              variant_id: nil,
              description: {
                type: "doc",
                content: [
                  {
                    type: "fileEmbed",
                    attrs: {
                      id: commission.files.first.signed_id,
                    }
                  },
                  {
                    type: "fileEmbed",
                    attrs: {
                      id: commission.files.second.signed_id,
                    }
                  }
                ]
              },
              updated_at: commission.reload.updated_at,
            }
          ]
        )
      end

      context "when the commission is not completed" do
        before { commission.update(status: Commission::STATUS_IN_PROGRESS) }

        it "does not include commission files" do
          rich_content_json = commission.deposit_purchase.url_redirect.rich_content_json

          expect(rich_content_json).to eq([])
        end
      end
    end
  end

  describe "#has_embedded_posts?" do
    context "when associated with a product" do
      let(:product) { create(:product) }
      let(:purchase) { create(:purchase, link: product) }
      let(:url_redirect) { create(:url_redirect, purchase:) }

      it "returns true if the product has rich content with embedded posts" do
        create(:rich_content, entity: product, description: [{ "type" => "posts" }])

        expect(url_redirect.has_embedded_posts?).to be(true)
      end

      it "returns false if the product has rich content without embedded posts" do
        create(:rich_content, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])

        expect(url_redirect.has_embedded_posts?).to be(false)
      end

      it "returns false if the product has no rich content" do
        expect(url_redirect.has_embedded_posts?).to be(false)
      end
    end

    context "when associated with a variant" do
      let(:product) { create(:product) }
      let(:variant) { create(:variant, variant_category: create(:variant_category, link: product)) }
      let(:purchase) { create(:purchase, link: product, variant_attributes: [variant]) }
      let(:url_redirect) { create(:url_redirect, purchase:) }

      it "returns true if the variant has rich content with embedded posts" do
        create(:rich_content, entity: variant, description: [{ "type" => "posts" }])

        expect(url_redirect.has_embedded_posts?).to be(true)
      end

      it "returns false if the variant has rich content without embedded posts" do
        create(:rich_content, entity: variant, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])

        expect(url_redirect.has_embedded_posts?).to be(false)
      end

      it "returns false if the variant has no rich content" do
        expect(url_redirect.has_embedded_posts?).to be(false)
      end

      it "returns true if the corresponding product's `has_same_rich_content_for_all_variants` is set to true and it has rich content with embedded posts" do
        product.update!(has_same_rich_content_for_all_variants: true)
        create(:rich_content, entity: product, description: [{ "type" => "posts" }])
        create(:rich_content, entity: variant, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])

        expect(url_redirect.has_embedded_posts?).to be(true)
      end
    end
  end

  describe "#alive_product_files" do
    describe "for installment" do
      before do
        @product = create(:product_with_files, files_count: 3)
        purchase = create(:purchase, link: @product)
        @installment = create(:installment, link: @product, installment_type: "product")
        @url_redirect = create(:url_redirect, link: @product, purchase:, installment: @installment)
      end

      it "returns the installment files if the installment has files" do
        @installment.product_files << @product.product_files.first

        expect(@url_redirect.reload.alive_product_files).to eq [@product.product_files.first]
      end

      it "returns all product files if the installment has no files" do
        expect(@url_redirect.alive_product_files).to match_array @product.product_files
        expect(@url_redirect.alive_product_files.size).to eq 3
      end
    end

    describe "for purchase" do
      before do
        @product = create(:product)
        @product_file2 = create(:product_file, link: @product, position: 1)
        @product_file1 = create(:product_file, link: @product, position: 3)
        @product_file4 = create(:product_file, link: @product, position: 2)
        @product_file3 = create(:product_file, link: @product, position: 0)
        @product.product_files = [@product_file1, @product_file2, @product_file3, @product_file4]
        category_1 = create(:variant_category, link: @product, title: "Format")
        @category_1_option_a = create(:variant, variant_category: category_1, name: "mp3")
        @category_1_option_b = create(:variant, variant_category: category_1, name: "m4a")

        category_2 = @product.variant_categories.create(title: "Version")
        @category_2_option_a = create(:variant, variant_category: category_2, name: "Basic")
        @category_2_option_b = create(:variant, variant_category: category_2, name: "Extended cut", price_difference_cents: 50)

        @purchase = build(:purchase, link: @product)

        @category_1_option_a.product_files = [@product_file1, @product_file4, @product_file2]
        @category_2_option_b.product_files = [@product_file4]
        @purchase.variant_attributes = [@category_1_option_a]

        @url_redirect = create(:url_redirect, link: @product, purchase: @purchase)
        create(:product_rich_content, entity: @product, description: [
                 { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] },
                 { "type" => "fileEmbed", "attrs" => { "id" => @product_file1.external_id, "uid" => SecureRandom.uuid } },
                 { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "World" }] },
                 { "type" => "fileEmbed", "attrs" => { "id" => @product_file2.external_id, "uid" => SecureRandom.uuid } },
                 { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Lorem ipsum" }] },
                 { "type" => "fileEmbed", "attrs" => { "id" => @product_file3.external_id, "uid" => SecureRandom.uuid } },
                 { "type" => "fileEmbed", "attrs" => { "id" => @product_file4.external_id, "uid" => SecureRandom.uuid } },
               ])
        create(:rich_content, entity: @category_1_option_a, description: [
                 { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "This is variant-level rich content" }] },
                 { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "World" }] },
                 { "type" => "fileEmbed", "attrs" => { "id" => @product_file1.external_id, "uid" => SecureRandom.uuid } },
                 { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Lorem ipsum" }] },
                 { "type" => "fileEmbed", "attrs" => { "id" => @product_file2.external_id, "uid" => SecureRandom.uuid } },
                 { "type" => "fileEmbed", "attrs" => { "id" => @product_file4.external_id, "uid" => SecureRandom.uuid } },
               ])
      end

      context "when `has_same_rich_content_for_all_variants` flag is set to true" do
        before do
          @product.update!(has_same_rich_content_for_all_variants: true)
        end

        it "returns product-level product files in the order they appear in the product-level rich content" do
          expect(@url_redirect.alive_product_files.size).to eq(4)
          expect(@url_redirect.alive_product_files).to match_array(@product.product_files)
          expect(@url_redirect.alive_product_files).to eq([@product_file1, @product_file2, @product_file3, @product_file4])
        end
      end

      context "when `has_same_rich_content_for_all_variants` flag is set to false" do
        before do
          @product.update!(has_same_rich_content_for_all_variants: false)
        end

        it "returns purchased variant-level product files in the order they appear in the variant-level rich content" do
          expect(@url_redirect.alive_product_files).to eq([@product_file1, @product_file2, @product_file4])
        end

        context "when the purchased variant is deleted" do
          before do
            @category_1_option_a.mark_deleted!
          end

          it "returns the product-level product files in the order they appear in the product-level rich content" do
            expect(@url_redirect.alive_product_files).to eq([@product_file1, @product_file2, @product_file3, @product_file4])
          end
        end
      end

      context "when the purchase does not have variants" do
        before do
          @purchase.variant_attributes = []
        end

        it "returns product-level product files in the order they appear in the product-level rich content" do
          url_redirect = create(:url_redirect, link: @product, purchase: @purchase)
          expect(url_redirect.alive_product_files).to match_array @product.product_files
          expect(@url_redirect.alive_product_files).to eq([@product_file1, @product_file2, @product_file3, @product_file4])
        end
      end
    end
  end

  describe "#enqueue_job_to_regenerate_deleted_stamped_pdfs" do
    it "enqueues StampPdfForPurchaseJob only for missing deleted stamped pdfs" do
      url_redirect = create(:url_redirect)
      product_file = create(:pdf_product_file, link: url_redirect.link, pdf_stamp_enabled: true)

      url_redirect.enqueue_job_to_regenerate_deleted_stamped_pdfs
      expect(StampPdfForPurchaseJob.jobs).to be_empty

      stamped_pdf = create(:stamped_pdf, url_redirect:, product_file:)
      url_redirect.enqueue_job_to_regenerate_deleted_stamped_pdfs
      expect(StampPdfForPurchaseJob.jobs).to be_empty

      stamped_pdf.mark_deleted!
      url_redirect.enqueue_job_to_regenerate_deleted_stamped_pdfs
      expect(StampPdfForPurchaseJob).to have_enqueued_sidekiq_job(url_redirect.purchase_id)
    end
  end

  describe "#missing_stamped_pdf?" do
    it "returns true when no alive stamped pdf exists for the file" do
      url_redirect = create(:url_redirect)
      product_file = create(:pdf_product_file, link: url_redirect.link, pdf_stamp_enabled: true)

      expect(url_redirect.missing_stamped_pdf?(product_file)).to be(true)
    end

    it "returns false when an alive stamped pdf exists for the file" do
      url_redirect = create(:url_redirect)
      product_file = create(:pdf_product_file, link: url_redirect.link, pdf_stamp_enabled: true)
      create(:stamped_pdf, url_redirect:, product_file:)

      expect(url_redirect.missing_stamped_pdf?(product_file)).to be(false)
    end
  end

  describe "#update_transcoded_videos_last_accessed_at", :freeze_time do
    it "sets last_accessed_at to now" do
      product_file = create(:streamable_video)
      transcoded_video = create(:transcoded_video, streamable: product_file, last_accessed_at: 5.days.ago)
      url_redirect = create(:url_redirect, link: product_file.link)

      url_redirect.update_transcoded_videos_last_accessed_at
      expect(transcoded_video.reload.last_accessed_at).to eq(Time.current)
    end
  end

  describe "#enqueue_job_to_regenerate_deleted_transcoded_videos" do
    it "enqueues a job for the deleted transcoded videos" do
      product_file = create(:streamable_video, :analyze)
      create(:transcoded_video, streamable: product_file, state: "completed", deleted_at: Time.current)
      url_redirect = create(:url_redirect, link: product_file.link)

      url_redirect.enqueue_job_to_regenerate_deleted_transcoded_videos
      expect(TranscodeVideoForStreamingWorker)
        .to have_enqueued_sidekiq_job(product_file.id, product_file.class.name)
    end

    it "doesn't enqueue a job when nothing is missing" do
      product_file = create(:streamable_video, :analyze)
      create(:transcoded_video, streamable: product_file)
      url_redirect = create(:url_redirect, link: product_file.link)

      url_redirect.enqueue_job_to_regenerate_deleted_transcoded_videos
      expect(TranscodeVideoForStreamingWorker.jobs).to be_empty
    end
  end
end
