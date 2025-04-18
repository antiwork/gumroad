# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Add new mime types for use in respond_to blocks:
# Mime::Type.register "text/richtext", :rtf
# Mime::Type.register_alias "text/html", :iphone
Mime::Type.register "image/svg+xml", :svg
Mime::Type.register "application/smil+xml", :smil
Mime::Type.register "application/x-mpegurl", :m3u8

# TODO remove this when rack is updated to v3
Rack::Mime::MIME_TYPES[".mjs"] = "text/javascript"
