# frozen_string_literal: true

require "spec_helper"

describe OEmbedFinder do
  describe "#embeddable_from_url" do
    it "returns nil if there is an exceptions when getting oembed" do
      allow(OEmbed::Providers).to receive(:get).and_raise(StandardError)
      expect(OEmbedFinder.embeddable_from_url("some url")).to be(nil)
    end

    describe "video" do
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

      it "returns plain embeddable" do
        embeddable = "<oembed/>"
        expect(@response_mock).to receive(:html).and_return(embeddable)
        result = OEmbedFinder.embeddable_from_url("url")
        expect(result[:html]).to eq embeddable
        expect(result[:info]).to eq("width" => 600,
                                    "height" => 400,
                                    "thumbnail_url" => "http://example.com/url-to-thumbnail.jpg")
      end

      describe "soundcloud" do
        it "replaces http with https" do
          embeddable = "<oembed><author_url>http://w.soundcloud.com</author_url><provider_url>api.soundcloud.com</provider_url></oembed>"
          processed_embeddable = "<oembed><author_url>https://w.soundcloud.com</author_url><provider_url>api.soundcloud.com</provider_url></oembed>"
          expect(@response_mock).to receive(:html).and_return(embeddable)
          expect(OEmbedFinder.embeddable_from_url("url")[:html]).to eq processed_embeddable
        end

        it "replaces show_artwork payload with all available payloads with false value" do
          embeddable = "<oembed><author_url>http://w.soundcloud.com?show_artwork=true</author_url><provider_url>api.soundcloud.com</provider_url></oembed>"
          all_payloads_with_false_value = OEmbedFinder::SOUNDCLOUD_PARAMS.map { |k| "#{k}=false" }.join("&")
          processed_embeddable = "<oembed><author_url>https://w.soundcloud.com?#{all_payloads_with_false_value}</author_url>"
          processed_embeddable += "<provider_url>api.soundcloud.com</provider_url></oembed>"
          expect(@response_mock).to receive(:html).and_return(embeddable)
          expect(OEmbedFinder.embeddable_from_url("url")[:html]).to eq processed_embeddable
        end
      end

      describe "youtube" do
        it "replaces http with https" do
          embeddable = "<oembed><author_url>http://www.youtube.com/embed</author_url></oembed>"
          processed_embeddable = "<oembed><author_url>https://www.youtube.com/embed</author_url></oembed>"
          expect(@response_mock).to receive(:html).and_return(embeddable)
          expect(OEmbedFinder.embeddable_from_url("url")[:html]).to eq processed_embeddable
        end

        it "adds showinfor and controls payloads" do
          embeddable = "<oembed><author_url>https://www.youtube.com/embed?feature=oembed</author_url></oembed>"
          processed_embeddable = "<oembed><author_url>https://www.youtube.com/embed?feature=oembed&showinfo=0&controls=0&rel=0</author_url></oembed>"
          expect(@response_mock).to receive(:html).and_return(embeddable)
          expect(OEmbedFinder.embeddable_from_url("url")[:html]).to eq processed_embeddable
        end

        it "replaces http with https for vimeo" do
          embeddable = "<oembed><author_url>http://player.vimeo.com/video/71588076</author_url></oembed>"
          processed_embeddable = "<oembed><author_url>https://player.vimeo.com/video/71588076</author_url></oembed>"
          expect(@response_mock).to receive(:html).and_return(embeddable)
          expect(OEmbedFinder.embeddable_from_url("url")[:html]).to eq processed_embeddable
        end
      end
    end

    describe "photo" do
      before :each do
        @response_mock = double(video?: false, rich?: false, photo?: true)
        allow(OEmbed::Providers).to receive(:get) { @response_mock }
      end

      it "returns nil so that we fallback to default preview container" do
        embeddable = "Some image"
        new_url = "https://www.flickr.com/id=1"
        allow(@response_mock).to receive(:html).and_return(embeddable)
        expect(OEmbedFinder.embeddable_from_url(new_url)).to eq nil
      end
    end

    describe "video hosts outside the gem's builtin provider list" do
      it "resolves a FrameRate watch URL" do
        vcr_turned_on do
          VCR.use_cassette("OEmbedFinder/framerate_watch_url") do
            embeddable = OEmbedFinder.embeddable_from_url("https://framerate.tv/watch/AB3peBMp")

            expect(embeddable).to be_present
            expect(embeddable[:html]).to include("framerate.tv/embed/")
            expect(embeddable[:info]["width"]).to be_positive
            expect(embeddable[:info]["height"]).to be_positive
            expect(embeddable[:info]["thumbnail_url"]).to be_present
          end
        end
      end
    end
  end

  # Snapshot identities because the process-wide registry is shared across examples.
  describe "provider registry" do
    let(:unmatched_url) { "https://example.com/no-registered-provider-matches-this" }

    def registry_snapshot
      OEmbed::Providers.urls.transform_values { |providers| providers.map(&:object_id) }
    end

    def distinct_providers_for(endpoint)
      OEmbed::Providers.urls.values.flatten.uniq.select { |provider| provider.endpoint == endpoint }
    end

    it "holds one provider per url pattern however many lookups have happened" do
      3.times { OEmbedFinder.embeddable_from_url(unmatched_url) }

      # Counts, not the providers themselves: a failure here otherwise prints all 93
      # registered providers with their url lists.
      duplicated = OEmbed::Providers.urls.transform_values(&:size).select { |_pattern, count| count > 1 }

      expect(duplicated).to be_empty
      expect(OEmbed::Providers.urls).to be_present
    end

    it "builds the Wistia, Sketchfab and FrameRate providers once rather than once per lookup" do
      3.times { OEmbedFinder.embeddable_from_url(unmatched_url) }

      expect(distinct_providers_for("http://fast.wistia.com/oembed").size).to eq 1
      expect(distinct_providers_for("https://sketchfab.com/oembed").size).to eq 1
      expect(distinct_providers_for("https://framerate.tv/api/oembed").size).to eq 1
    end

    it "leaves the registry untouched across a lookup that resolves" do
      vcr_turned_on do
        VCR.use_cassette("OEmbedFinder/framerate_watch_url", allow_playback_repeats: true) do
          OEmbedFinder.embeddable_from_url("https://framerate.tv/watch/AB3peBMp")
          before = registry_snapshot

          OEmbedFinder.embeddable_from_url("https://framerate.tv/watch/AB3peBMp")

          expect(registry_snapshot).to eq before
        end
      end
    end

    it "leaves the registry untouched when lookups run concurrently" do
      OEmbedFinder.embeddable_from_url(unmatched_url)
      before = registry_snapshot

      8.times.map do
        Thread.new { 3.times { OEmbedFinder.embeddable_from_url(unmatched_url) } }
      end.each(&:join)

      expect(registry_snapshot).to eq before
    end

    it "resolves each registered host to its own endpoint and nothing to an unregistered one" do
      OEmbedFinder.embeddable_from_url(unmatched_url)

      expect(OEmbed::Providers.find("https://www.youtube.com/watch?v=jNQXAC9IVRw").endpoint).to eq "https://www.youtube.com/oembed/?scheme=https"
      expect(OEmbed::Providers.find("https://vimeo.com/71588076").endpoint).to eq "https://vimeo.com/api/oembed.{format}"
      expect(OEmbed::Providers.find("https://soundcloud.com/seller/track").endpoint).to eq "https://soundcloud.com/oembed"
      expect(OEmbed::Providers.find("https://fast.wistia.com/embed/medias/abc").endpoint).to eq "http://fast.wistia.com/oembed"
      expect(OEmbed::Providers.find("https://sketchfab.com/models/abc").endpoint).to eq "https://sketchfab.com/oembed"
      expect(OEmbed::Providers.find("https://framerate.tv/watch/AB3peBMp").endpoint).to eq "https://framerate.tv/api/oembed"
      expect(OEmbed::Providers.find(unmatched_url)).to be_nil
    end

    it "returns nil for an unmatched url without falling back to discovery or an aggregator" do
      expect(OEmbedFinder.embeddable_from_url(unmatched_url)).to be_nil
      expect(OEmbed::Providers.fallback).to be_empty
    end
  end
end
