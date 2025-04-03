# frozen_string_literal: true

# Overrides the 'bg0' pallete of Rouge's Gruvbox light theme
# https://github.com/rouge-ruby/rouge/blob/43d346cceb1123510de67ec58a2fa1e29d22cc7b/lib/rouge/themes/gruvbox.rb
class CustomRougeTheme < Rouge::Themes::Gruvbox
  def self.make_light!
    super

    palette bg0: "#fff"
  end
end
