# frozen_string_literal: true

class SellerProfilePostsSection < SellerProfileSection
  # Sections written before the flag existed carry no key, and the editor binds this to a switch.
  def add_new_posts = !!json_data["add_new_posts"]
end
