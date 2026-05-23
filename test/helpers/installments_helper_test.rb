# frozen_string_literal: true

require "test_helper"

class InstallmentsHelperTest < ActionView::TestCase
  self.described_class = InstallmentsHelper
  tests InstallmentsHelper



  context_ InstallmentsHelper do
  context_ "#post_title_displayable" do
      let(:url) { nil }
      let(:post) { create(:installment) }

      subject { helper.post_title_displayable(post:, url:) }

  context_ "when url is missing" do
  test "displays the post title as plain text" do
          is_expected.to eq("<span class=\"title\">#{ERB::Util.html_escape(post.subject)}</span>")
        end
      end

  context_ "when url is present" do
        let(:url) { "https://example.com/p/#{post.slug}" }

  test "displays the post title as an anchor tag" do
          is_expected.to eq("<a target=\"_blank\" class=\"title\" href=\"#{url}\">#{ERB::Util.html_escape(post.subject)}</a>")
        end
      end
    end
  end
end
