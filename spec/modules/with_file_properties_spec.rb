# frozen_string_literal: true

require "spec_helper"

describe WithFileProperties do
  PROPERTIES = %i[size duration width height framerate bitrate pagelength].freeze

  def stub_for_word_doc
    output_double = double
    allow(output_double).to receive(:output).and_return("Number of Pages = 2")
    allow(Subexec).to receive(:run).and_return(output_double)
  end

  def stub_for_pdf
    output_double = double
    allow(output_double).to receive(:page_count).and_return("6")
    allow(PDF::Reader).to receive(:new).and_return(output_double)
  end

  def stub_for_ppt
    output_double = double
    allow(output_double).to receive(:output).and_return("Number of Slides = 7")
    allow(Subexec).to receive(:run).and_return(output_double)
  end

  before do
    allow(FFMPEG::Movie).to receive(:new) do |path|
      extension = File.extname(path)
      if extension.match(FILE_REGEX["audio"])
        double.tap do |song_double|
          allow(song_double).to receive(:duration).and_return(46)
          allow(song_double).to receive(:bitrate).and_return(128)
        end
      elsif extension.match(FILE_REGEX["video"])
        double.tap do |movie_double|
          allow(movie_double).to receive(:duration).and_return(13)
          allow(movie_double).to receive(:frame_rate).and_return(60)
          allow(movie_double).to receive(:height).and_return(240)
          allow(movie_double).to receive(:width).and_return(320)
          allow(movie_double).to receive(:bitrate).and_return(125_779)
        end
      else
        raise "Unsupported path: #{path}"
      end
    end
  end

  { audio: { fake_uri: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/magic.mp3",
             filename: "magic.mp3", filegroup: "audio", constraints: { size: 466_312, duration: 46, bitrate: 128 } },
    exe: { fake_uri: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/test.exe",
           filename: "test.exe", filegroup: "executable", constraints: { size: 118 } },
    archive: { fake_uri: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/test.zip",
               filename: "test.zip", filegroup: "archive", constraints: { size: 67_852 } },
    psd: { fake_uri: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/index.psd",
           filename: "index.psd", filegroup: "image", constraints: { size: 132_284 } },
    text: { fake_uri: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/blah.txt",
            filename: "blah.txt", filegroup: "document", constraints: { size: 52 } },
    video: { fake_uri: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/small.m4v",
             filename: "small.m4v", filegroup: "video",
             constraints: { size: 208_857, width: 320, height: 240, duration: 13, framerate: 60, bitrate: 125_779 } },
    image: { fake_uri: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/kFDzu.png",
             filename: "kFDzu.png", filegroup: "image", constraints: { size: 47_684, width: 1633, height: 512 } },
    pdf_document: { fake_uri: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/billion-dollar-company-chapter-0.pdf",
                    filename: "billion-dollar-company-chapter-0.pdf", filegroup: "document",
                    constraints: { size: 111_237, pagelength: 6 }, stubbing_method: :stub_for_pdf },
    word_document_docx: { fake_uri: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/sample_doc.docx",
                          filename: "sample_doc.docx", filegroup: "document",
                          constraints: { size: 156_126, pagelength: 4 } },
    word_document: { fake_uri: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/test_doc.doc",
                     filename: "test_doc.doc", filegroup: "document", constraints: { size: 28_672, pagelength: 2 },
                     stubbing_method: :stub_for_word_doc },
    epub: { fake_uri: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/sample.epub",
            filename: "test.epub", filegroup: "document", constraints: { size: 881_436, pagelength: 13 } },
    powerpoint: { fake_uri: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/test.ppt",
                  filename: "test.ppt", filegroup: "document",
                  constraints: { size: 954_368, pagelength: 7 }, stubbing_method: :stub_for_ppt },
    powerpoint_pptx: { fake_uri: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/test.pptx",
                       filename: "test.pptx", filegroup: "document",
                       constraints: { size: 1_346_541, pagelength: 2 } } }.each do |file_type, properties|
    describe "#{file_type} files" do
      before do
        send(properties[:stubbing_method]) if properties[:stubbing_method]
        @product_file = create(:product_file, url: properties[:fake_uri])
        s3_double = double
        allow(s3_double).to receive(:content_length).and_return(properties[:constraints][:size])
        allow(s3_double).to receive(:get) do |options|
          File.open(options[:response_target], "w+") do |f|
            f.write(File.open("#{Rails.root}/spec/support/fixtures/#{properties[:filename]}").read)
          end
        end
        allow(@product_file).to receive(:s3_object).and_return(s3_double)
        allow(@product_file).to receive(:confirm_s3_key!)
        @product_file.analyze
      end

      it "has the correct filegroup for #{file_type}" do
        expect(@product_file.filegroup).to eq properties[:filegroup]
      end

      it "has the correct properties" do
        PROPERTIES.each do |property|
          expect(@product_file.send(property)).to eq properties[:constraints][property]
        end
      end
    end
  end

  describe "videos" do
    before do
      @video_file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/sample.mov")
      @file_path = file_fixture("sample.mov").to_s
    end

    it "sets the metadata and the analyze_completed flag" do
      expected_metadata = {
        bitrate: 27_506,
        duration: 4,
        framerate: 60,
        height: 132,
        width: 176
      }

      expect do
        @video_file.assign_video_attributes(@file_path)

        @video_file.reload
        expected_metadata.each do |property, value|
          expect(@video_file.public_send(property)).to eq(value)
        end
      end.to change { @video_file.analyze_completed? }.from(false).to(true)
    end

    context "when auto-transcode is disabled for the product" do
      it "doesn't transcode the video and sets product.transcode_videos_on_purchase to true" do
        @video_file.assign_video_attributes(@file_path)

        expect(TranscodeVideoForStreamingWorker.jobs.size).to eq(0)
        expect(@video_file.link.transcode_videos_on_purchase?).to eq true
      end
    end

    context "when auto-transcode is enabled for the product" do
      before do
        allow(@video_file.link).to receive(:auto_transcode_videos?).and_return(true)
      end

      it "transcodes the video" do
        @video_file.assign_video_attributes(@file_path)

        expect(TranscodeVideoForStreamingWorker).to have_enqueued_sidekiq_job(@video_file.id, @video_file.class.name)
      end
    end
  end

  describe "epubs" do
    before do
      @epub_file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/sample.epub")
      file_path = file_fixture("sample.epub")
      @epub_file.assign_epub_document_attributes(file_path)
    end

    it "sets the pagelength" do
      expect(@epub_file.pagelength).to eq 10
    end

    it "returns nil in pagelength for json" do
      @epub_file.pagelength = 10
      @epub_file.save!
      @epub_file.reload
      expect(@epub_file.as_json[:pagelength]).to be_nil
      expect(@epub_file.mobile_json_data[:pagelength]).to be_nil
    end

    it "sets the epub section information" do
      epub_section_info = @epub_file.epub_section_info

      expect(epub_section_info.keys).to eq %w[i s1a s1b s2a s2b s3a s3b s4a s4b s5]

      expect(epub_section_info["s1a"]["section_number"]).to eq 2
      expect(epub_section_info["s1a"]["section_name"]).to eq "Childhood"

      expect(epub_section_info["s3a"]["section_number"]).to eq 6
      expect(epub_section_info["s3a"]["section_name"]).to eq "Manhood"
    end
  end

  describe "very large files" do
    before do
      @product_file = create(:product_file)
      @product_file.url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/some-video-file.mov"

      s3_double = double
      allow(s3_double).to receive(:content_length).and_return(2_000_000_000)
      allow(@product_file).to receive(:s3_object).and_return(s3_double)
      allow(@product_file).to receive(:confirm_s3_key!)
      @product_file.analyze
    end

    it "does not have framerate, resolution, duraration" do
      expect(@product_file.framerate).to be(nil)
      expect(@product_file.width).to be(nil)
      expect(@product_file.height).to be(nil)
      expect(@product_file.duration).to be(nil)
    end
  end

  describe "long file names" do
    before do
      @product_file = create(:product_file)
      @product_file.url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/5635138219475/1dc6d2b8f68c4da9b944e8930602057c/original/SET GS สปาหน้าเด็ก หน้าใส ไร้สิว อ่อนเยาว์ สวย เด้ง.jpg"

      s3_double = double
      allow(s3_double).to receive(:content_length).and_return(1000)
      allow(s3_double).to receive(:get) do |options|
        File.open(options[:response_target], "w+") do |f|
          f.write("")
        end
      end
      allow(@product_file).to receive(:s3_object).and_return(s3_double)
      allow(@product_file).to receive(:confirm_s3_key!)
    end

    it "does not throw an exception due to long tempfile name" do
      expect { @product_file.analyze }.to_not raise_error
    end
  end

  it "raises a descriptive exception if the S3 object doesn't exist" do
    file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/missing.txt")

    expect do
      file.analyze
    end.to raise_error(Aws::S3::Errors::NotFound, /Key = attachments\/missing.txt .* ProductFile.id = #{file.id}/)
  end

  context "with a incorrect s3_key" do
    it "corrects it and succeeds in analyzing the file" do
      s3_directory = "#{SecureRandom.hex}/#{SecureRandom.hex}/original"

      Aws::S3::Resource.new.bucket(S3_BUCKET).object("#{s3_directory}/file.pdf").upload_file(
        File.new("spec/support/fixtures/test.pdf"),
        content_type: "application/pdf"
      )

      file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{s3_directory}/incorrect-file-name.pdf")
      file.analyze
      file.reload

      expect(file.s3_key).to eq(s3_directory + "/file.pdf")
      expect(file.filetype).to eq("pdf")
    end
  end
end
