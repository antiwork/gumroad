# frozen_string_literal: true

describe Post::SocialImage do
  it "parses the embedded image correctly" do
    content_with_one_image = <<~HTML
      <p>First paragraph</p>
      <figure>
        <img src="path/to/image.jpg">
        <p class="figcaption">Image description</p>
      </figure>
      <p>Second paragraph</p>
    HTML
    social_image = Post::SocialImage.for(content_with_one_image)
    expect(social_image.url).to eq("path/to/image.jpg")
    expect(social_image.caption).to eq("Image description")
    expect(social_image.blank?).to be_falsey
  end

  context "when image is an ActiveStorage upload" do
    it "sets the full social image URL" do
      content_with_one_image = <<~HTML
      <p>First paragraph</p>
      <figure>
        <img src="#{AWS_S3_ENDPOINT}/#{PUBLIC_STORAGE_S3_BUCKET}/blobKey">
        <p class="figcaption">Image description</p>
      </figure>
      <p>Second paragraph</p>
      HTML
      social_image = Post::SocialImage.for(content_with_one_image)
      expect(social_image.url).to eq("#{AWS_S3_ENDPOINT}/#{PUBLIC_STORAGE_S3_BUCKET}/blobKey")
    end
  end

  context "when no embedded image" do
    it "is blank" do
      social_image = Post::SocialImage.for("<p>hi!</p>")
      expect(social_image.url).to be_blank
      expect(social_image.caption).to be_blank
      expect(social_image.blank?).to be_truthy
    end
  end

  context "when multiple embedded images" do
    it "uses the first image" do
      content_with_one_image = <<~HTML
      <figure>
        <img src="path/to/first_image.jpg">
        <p class="figcaption">First image description</p>
      </figure>
      <figure>
        <img src="path/to/second_image.jpg">
        <p class="figcaption">Second image description</p>
      </figure>
      HTML
      social_image = Post::SocialImage.for(content_with_one_image)
      expect(social_image.url).to eq("path/to/first_image.jpg")
      expect(social_image.caption).to eq("First image description")
    end

    context "when first image has no caption, but second image has a caption" do
      it "does not use second image's caption" do
        content_with_one_image = <<~HTML
        <figure>
          <img src="path/to/first_image.jpg">
        </figure>
        <figure>
          <img src="path/to/second_image.jpg">
          <p class="figcaption">Second image description</p>
        </figure>
        HTML
        social_image = Post::SocialImage.for(content_with_one_image)
        expect(social_image.url).to eq("path/to/first_image.jpg")
        expect(social_image.caption).to be_blank
      end
    end
  end

  context "when different media types are embedded" do
    it "ignores non-image embeds" do
      content_with_one_image = <<~HTML
      <figure>
        <iframe src="embedded_tweet"/>
      </figure>
      <figure>
        <img src="path/to/image.jpg">
        <p class="figcaption">Image description</p>
      </figure>
      HTML
      social_image = Post::SocialImage.for(content_with_one_image)
      expect(social_image.url).to eq("path/to/image.jpg")
      expect(social_image.caption).to eq("Image description")
    end
  end
end
