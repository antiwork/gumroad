# frozen_string_literal: true

require "test_helper"

class OEmbedFinderTest < ActiveSupport::TestCase
  self.described_class = OEmbedFinder



  context_ OEmbedFinder do
  context_ "#embeddable_from_url" do
      before :each do
        expect(OEmbed::Providers).to receive(:register_all)
      end

  test "returns nil if there is an exceptions when getting oembed" do
        allow(OEmbed::Providers).to receive(:get).and_raise(StandardError)
        expect(OEmbedFinder.embeddable_from_url("some url")).to be(nil)
      end

  context_ "video" do
        before :each do
          @width = 600
          @height = 400
          @thumbnail_url = "http://example.com/url-to-thumbnail.jpg"
          @response_mock = double(video?: true)
          allow(@response_mock).to receive(:fields).and_return("width" => 600,
                                                               "height" => 400,
                                                               "thumbnail_url" => "http://example.com/url-to-thumbnail.jpg",
                                                               "thumbnail_width" => 200,
                                                               "thumbnail_height" => 133)
          allow(OEmbed::Providers).to receive(:get) { @response_mock }
        end

  test "returns plain embeddable" do
          embeddable = "<oembed/>"
          expect(@response_mock).to receive(:html).and_return(embeddable)
          result = OEmbedFinder.embeddable_from_url("url")
          expect(result[:html]).to eq embeddable
          expect(result[:info]).to eq("width" => 600,
                                      "height" => 400,
                                      "thumbnail_url" => "http://example.com/url-to-thumbnail.jpg")
        end

  context_ "soundcloud" do
  test "replaces http with https" do
            embeddable = "<oembed><author_url>http://w.soundcloud.com</author_url><provider_url>api.soundcloud.com</provider_url></oembed>"
            processed_embeddable = "<oembed><author_url>https://w.soundcloud.com</author_url><provider_url>api.soundcloud.com</provider_url></oembed>"
            expect(@response_mock).to receive(:html).and_return(embeddable)
            expect(OEmbedFinder.embeddable_from_url("url")[:html]).to eq processed_embeddable
          end

  test "replaces show_artwork payload with all available payloads with false value" do
            embeddable = "<oembed><author_url>http://w.soundcloud.com?show_artwork=true</author_url><provider_url>api.soundcloud.com</provider_url></oembed>"
            all_payloads_with_false_value = OEmbedFinder::SOUNDCLOUD_PARAMS.map { |k| "#{k}=false" }.join("&")
            processed_embeddable = "<oembed><author_url>https://w.soundcloud.com?#{all_payloads_with_false_value}</author_url>"
            processed_embeddable += "<provider_url>api.soundcloud.com</provider_url></oembed>"
            expect(@response_mock).to receive(:html).and_return(embeddable)
            expect(OEmbedFinder.embeddable_from_url("url")[:html]).to eq processed_embeddable
          end
        end

  context_ "youtube" do
  test "replaces http with https" do
            embeddable = "<oembed><author_url>http://www.youtube.com/embed</author_url></oembed>"
            processed_embeddable = "<oembed><author_url>https://www.youtube.com/embed</author_url></oembed>"
            expect(@response_mock).to receive(:html).and_return(embeddable)
            expect(OEmbedFinder.embeddable_from_url("url")[:html]).to eq processed_embeddable
          end

  test "adds showinfor and controls payloads" do
            embeddable = "<oembed><author_url>https://www.youtube.com/embed?feature=oembed</author_url></oembed>"
            processed_embeddable = "<oembed><author_url>https://www.youtube.com/embed?feature=oembed&showinfo=0&controls=0&rel=0</author_url></oembed>"
            expect(@response_mock).to receive(:html).and_return(embeddable)
            expect(OEmbedFinder.embeddable_from_url("url")[:html]).to eq processed_embeddable
          end

  test "replaces http with https for vimeo" do
            embeddable = "<oembed><author_url>http://player.vimeo.com/video/71588076</author_url></oembed>"
            processed_embeddable = "<oembed><author_url>https://player.vimeo.com/video/71588076</author_url></oembed>"
            expect(@response_mock).to receive(:html).and_return(embeddable)
            expect(OEmbedFinder.embeddable_from_url("url")[:html]).to eq processed_embeddable
          end
        end
      end

  context_ "photo" do
        before :each do
          @response_mock = double(video?: false, rich?: false, photo?: true)
          allow(OEmbed::Providers).to receive(:get) { @response_mock }
        end

  test "returns nil so that we fallback to default preview container" do
          embeddable = "Some image"
          new_url = "https://www.flickr.com/id=1"
          allow(@response_mock).to receive(:html).and_return(embeddable)
          expect(OEmbedFinder.embeddable_from_url(new_url)).to eq nil
        end
      end
    end
  end
end
