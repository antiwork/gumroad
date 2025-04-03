# frozen_string_literal: true

require "spec_helper"

describe CommentMailer do
  describe "notify_seller_of_new_comment" do
    let(:comment) { create(:comment, content: "Their -> they're") }
    subject(:mail) { described_class.notify_seller_of_new_comment(comment.id) }

    it "emails to seller" do
      expect(mail.to).to eq([comment.commentable.seller.form_email])
      expect(mail.subject).to eq("New comment on #{comment.commentable.name}")
      expect(mail.body.encoded).to include("#{comment.author.display_name} commented on #{CGI.escape_html comment.commentable.name}")
      expect(mail.body.encoded).to include("Their -&gt; they're")
      expect(mail.body.encoded).to include(%Q{<a class="button primary" target="_blank" href="#{custom_domain_view_post_url(slug: comment.commentable.slug, host: comment.commentable.seller.subdomain_with_protocol)}">View comment</a>})
      expect(mail.body.encoded).to include(%Q{To stop receiving comment notifications, please <a target="_blank" href="#{settings_main_url(anchor: "notifications")}">change your notification settings</a>.})
    end
  end
end
