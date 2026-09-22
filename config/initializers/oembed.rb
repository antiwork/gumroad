# frozen_string_literal: true

# The gem's registry survives Rails reloads and appends without deduplication.
# Initialize before request threads start, not on each lookup or reload.
# Keep builtins first: registration order determines matching precedence.
OEmbed::Providers.register_all

wistia = OEmbed::Provider.new("http://fast.wistia.com/oembed")
wistia << "http://*.wistia.com/*"
wistia << "http://*.wistia.net/*"
wistia << "https://*.wistia.com/*"
wistia << "https://*.wistia.net/*"
OEmbed::Providers.register(wistia)

sketchfab = OEmbed::Provider.new("https://sketchfab.com/oembed")
sketchfab << "http://sketchfab.com/models/*"
sketchfab << "https://sketchfab.com/models/*"
OEmbed::Providers.register(sketchfab)

framerate = OEmbed::Provider.new("https://framerate.tv/api/oembed")
framerate << "http://*.framerate.tv/watch/*"
framerate << "https://*.framerate.tv/watch/*"
OEmbed::Providers.register(framerate)
