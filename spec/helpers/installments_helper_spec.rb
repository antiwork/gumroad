# frozen_string_literal: true

require "spec_helper"

describe InstallmentsHelper do
  describe "#post_title_displayable" do
    let(:url) { nil }
    let(:post) { create(:installment) }

    subject { helper.post_title_displayable(post:, url:) }

    context "when url is missing" do
      it "displays the post title as plain text" do
        is_expected.to eq("<span class=\"title\">#{post.subject}</span>")
      end
    end

    context "when url is present" do
      let(:url) { "https://example.com/p/#{post.slug}" }

      it "displays the post title as an anchor tag" do
        is_expected.to eq("<a target=\"_blank\" class=\"title\" href=\"#{url}\">#{post.subject}</a>")
      end
    end
  end
end
