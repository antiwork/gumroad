# frozen_string_literal: true

# Gruvbox light on the email stylesheet's <pre> surface ($color-subtle), whatever the seller's theme.
class CustomRougeTheme < Rouge::Themes::Gruvbox
  def self.make_light!
    super

    palette bg0: "#f8f8f5"
  end
end
