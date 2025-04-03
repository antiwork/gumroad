# frozen_string_literal: true

module InstallmentsHelper
  def post_title_displayable(post:, url: nil)
    return content_tag(:span, post.subject, class: "title") unless url.present?
    link_to post.subject, url, target: "_blank", class: "title"
  end
end
