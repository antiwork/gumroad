# frozen_string_literal: true

module PageMeta::Favicon
  extend ActiveSupport::Concern

  include PageMeta::Base

  private
    # head_key matches the defaults set in set_default_meta_tags so this call
    # replaces them instead of appending a second icon link — see that method
    # for why the key must be explicit (gp#1966: two <link rel="shortcut icon">
    # tags rendered when the keys didn't match).
    def set_favicon_meta_tags(user)
      return unless user.avatar_url.present?

      set_meta_tag(tag_name: "link", rel: "shortcut icon", href: user.avatar_url, head_key: "shortcut-icon")
      set_meta_tag(tag_name: "link", rel: "apple-touch-icon", href: user.avatar_url, head_key: "apple-touch-icon")
    end
end
