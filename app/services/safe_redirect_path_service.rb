# frozen_string_literal: true

class SafeRedirectPathService
  def initialize(path, request, allow_subdomain_host: true)
    @path = path
    @allow_subdomain_host = allow_subdomain_host
    @request = request
  end

  def process
    if (allow_subdomain_host && subdomain_host?) || same_host?
      path
    else
      relative_path
    end
  end

  private
    attr_reader :path, :request, :allow_subdomain_host

    def relative_path
      _path = url.path.gsub(/^\/+/, "/")
      [_path, url.query].compact.join("?")
    end

    def subdomain_host?
      url.host =~ /.*\.#{Regexp.escape(domain)}\z/
    end

    def same_host?
      url.host == request.host
    end

    def url
      @_url ||= URI.parse(Addressable::URI.escape(CGI.unescape(path).split("#").first))
    end

    def domain
      ROOT_DOMAIN
    end
end
