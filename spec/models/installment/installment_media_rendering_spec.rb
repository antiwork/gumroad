# frozen_string_literal: true

require "spec_helper"

describe Installment do
  describe "#message_with_inline_syntax_highlighting_and_upsells" do
    let(:installment) { create(:audience_installment, message:) }
    let(:rendered_message) { Capybara.string(installment.message_with_inline_syntax_highlighting_and_upsells) }

    # An embed reaches email as its thumbnail linked to the original, so the image's alt is all
    # that names the link.
    context "with a media embed that has a thumbnail" do
      let(:embed_url) { "https://www.youtube.com/watch?v=drMMDclhgsc" }
      let(:title_attribute) { %(data-title="Q4 2024 Antiwork All Hands") }
      let(:message) do
        %(<div class="tiptap__raw" #{title_attribute} data-url="#{embed_url}" data-thumbnail="https://i.ytimg.com/vi/drMMDclhgsc/maxresdefault.jpg"><iframe src="//cdn.iframe.ly/api/iframe"></iframe></div>)
      end

      it "names the link after the embed's title" do
        expect(rendered_message).to have_link("Q4 2024 Antiwork All Hands", href: embed_url, exact: true)
        expect(rendered_message).to have_css("img[src='https://i.ytimg.com/vi/drMMDclhgsc/maxresdefault.jpg']")
      end

      context "when the title contains an apostrophe" do
        let(:title_attribute) { %(data-title="Don't miss this") }

        it "keeps the whole title as the link's name" do
          expect(rendered_message).to have_link("Don't miss this", href: embed_url, exact: true)
        end
      end

      context "when the embed has no title" do
        let(:title_attribute) { "" }

        it "still names the link" do
          expect(rendered_message).to have_link("Open embedded media", href: embed_url, exact: true)
        end
      end
    end
  end
end
