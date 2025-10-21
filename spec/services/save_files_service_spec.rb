# frozen_string_literal: true

require "spec_helper"

describe SaveFilesService do
  before do
    @product = create(:product)
  end

  subject(:service) { described_class }

  describe ".perform" do
    context "when params is empty" do
      it "does not raise an error" do
        service.perform(@product, {})
      end
    end

    it "updates files" do
      file_1 = create(:product_file, link: @product, description: "pencil", url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png")
      file_2 = create(:product_file, link: @product, description: "manual", url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf")

      @product.product_files << file_1
      @product.product_files << file_2

      service.perform(@product, {
                        files: [{
                          external_id: file_2.external_id,
                          url: file_2.url,
                          display_name: "new manual",
                          description: "new manual description",
                          position: 2
                        },
                                {
                                  external_id: SecureRandom.uuid,
                                  url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/book.pdf",
                                  display_name: "new book",
                                  description: "new book description",
                                  position: 1
                                },
                                {
                                  external_id: SecureRandom.uuid,
                                  url: "https://www.gumroad.com",
                                  display_name: "new link",
                                  description: "new link description",
                                  extension: "URL",
                                  position: 0
                                }]
                      })

      expect(@product.product_files.count).to eq(4)
      expect(@product.product_files.alive.count).to eq(3)

      manual_file = @product.product_files.alive[0].reload
      expect(manual_file.display_name).to eq("new manual")
      expect(manual_file.description).to eq("new manual description")
      expect(manual_file.position).to eq(2)

      book_file = @product.product_files.alive[1].reload
      expect(book_file.url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/book.pdf")
      expect(book_file.unique_url_identifier).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/book.pdf")
      expect(book_file.display_name).to eq("new book")
      expect(book_file.description).to eq("new book description")
      expect(book_file.position).to eq(1)

      link_file = @product.product_files.alive[2].reload
      expect(link_file.url).to eq("https://www.gumroad.com")
      expect(link_file.unique_url_identifier).to eq("https://www.gumroad.com")
      expect(link_file.display_name).to eq("new link")
      expect(link_file.description).to eq("new link description")
      expect(link_file.external_link?).to eq(true)
      expect(link_file.position).to eq(0)

      pencil_file = @product.product_files[0].reload
      expect(pencil_file.deleted?).to eq(true)
    end

    it "updates subtitles" do
      @product.product_files << create(:streamable_video)
      @product.product_files << create(:listenable_audio)
      @product.product_files << create(:non_streamable_video)
      @product.product_files << create(:readable_document)
      video_1 = @product.product_files.first
      video_2 = @product.product_files.third
      video_1.subtitle_files << create(:subtitle_file)
      video_2.subtitle_files << create(:subtitle_file)
      video_2.subtitle_files << create(:subtitle_file)

      service.perform(@product, {
                        files: [{
                          external_id: @product.product_files.first.external_id,
                          url: @product.product_files.first.url,
                          subtitle_files: [{
                            "url" => "https://newurl1.srt",
                            "language" => "new-language1"
                          }]
                        },
                                {
                                  external_id: @product.product_files.second.external_id,
                                  url: @product.product_files.second.url
                                },
                                {
                                  external_id: @product.product_files.third.external_id,
                                  url: @product.product_files.third.url,
                                  subtitle_files: [{
                                    "url" => "https://newurl2.srt",
                                    "language" => "new-language2"
                                  }]
                                },
                                {
                                  external_id: @product.product_files.fourth.external_id,
                                  url: @product.product_files.fourth.url
                                },
                        ]
                      })

      expect(@product.product_files.count).to eq(4)

      video_1_subtitles = video_1.subtitle_files.reload.alive
      expect(video_1_subtitles.count).to eq(1)
      expect(video_1_subtitles.first.url).to eq("https://newurl1.srt")
      expect(video_1_subtitles.first.language).to eq("new-language1")

      video_2_subtitles = video_2.subtitle_files.reload.alive
      expect(video_2_subtitles.count).to eq(1)
      expect(video_2_subtitles.first.url).to eq("https://newurl2.srt")
      expect(video_2_subtitles.first.language).to eq("new-language2")
    end

    it "supports `files` param as an array" do
      installment = create(:installment, workflow: create(:workflow))
      file1 = create(:product_file, installment:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png")
      file2 = create(:product_file, installment:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf")
      service.perform(installment, {
                        files: [
                          {
                            external_id: file1.external_id,
                            url: file2.url,
                            position: 1,
                            stream_only: false,
                            subtitle_files: [],
                          },
                          {
                            external_id: file2.external_id,
                            url: file2.url,
                            position: 2,
                            stream_only: false,
                            subtitle_files: [],
                          },
                        ]
                      })
      expect(installment.product_files.alive.count).to eq(2)
      expect(installment.product_files.pluck(:id, :position, :url)).to match_array([[file1.id, 1, file2.url], [file2.id, 2, file2.url]])
    end
  end
end
