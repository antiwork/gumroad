# frozen_string_literal: true

# OEmbed::Providers holds its registry in a class variable and `register` appends to it
# without deduping, so registering from OEmbedFinder appended all 93 url patterns again on
# every cover-URL lookup and leaked a fresh Provider per custom host. Registering at boot
# keeps it to one pass: it runs before any request thread exists, and a code reload drops
# OEmbedFinder without touching the gem's registry, so nothing re-registers.
#
# Registration order is matching order — OEmbed::Providers#find walks url patterns in
# insertion order — so the builtins have to go first, as they did when OEmbedFinder
# called register_all before adding these three.
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
