# frozen_string_literal: true

require "json"
require "net/http"
require "thor"
require "uri"

module GumroadCli
  class Products < Thor
    namespace :products

    desc "show PERMALINK", "Fetch and print a product"
    def show(permalink)
      print_json(request(:get, product_uri(permalink)))
    end

    desc "update PERMALINK", "Update a product"
    option :custom_html, type: :string, desc: "Path to an HTML file, or an empty string to clear custom_html"
    def update(permalink)
      unless options.key?("custom_html")
        raise Thor::Error, "Pass --custom-html with a file path, or --custom-html '' to clear custom_html."
      end

      payload = { custom_html: custom_html_payload(options["custom_html"]) }
      print_json(request(:put, product_uri(permalink), payload))
    end

    no_commands do
      def custom_html_payload(path)
        return "" if path == ""

        File.read(path)
      rescue Errno::ENOENT
        raise Thor::Error, "Custom HTML file not found: #{path}"
      rescue Errno::EACCES, Errno::EISDIR
        raise Thor::Error, "Custom HTML file is not readable: #{path}"
      end

      def product_uri(permalink)
        URI("#{api_base_url}/products/#{URI.encode_www_form_component(permalink)}")
      end

      def api_base_url
        ENV.fetch("GUMROAD_API_BASE_URL", "https://api.gumroad.com/v2").delete_suffix("/")
      end

      def api_token
        token = ENV["GUMROAD_API_TOKEN"].to_s
        return token unless token.empty?

        raise Thor::Error, "Set GUMROAD_API_TOKEN."
      end

      def request(method, uri, payload = nil)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        klass = method == :get ? Net::HTTP::Get : Net::HTTP::Put
        request = klass.new(uri)
        request["Authorization"] = "Bearer #{api_token}"
        request["Accept"] = "application/json"
        if payload
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(payload)
        end

        response = http.request(request)
        body = JSON.parse(response.body)
        raise Thor::Error, body["message"] || "Request failed with HTTP #{response.code}." unless response.is_a?(Net::HTTPSuccess)

        body
      end

      def print_json(body)
        puts JSON.pretty_generate(body)
      end
    end
  end

  class CLI < Thor
    desc "products SUBCOMMAND", "Manage products"
    subcommand "products", Products
  end
end
