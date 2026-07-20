# frozen_string_literal: true

class SafeRedirectPathService
  def initialize(path, request, allow_subdomain_host: true)
    @path = normalize_path_separators(path)
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

    def normalize_path_separators(path)
      return path if path.nil?
      authority_and_path, separator, query_and_fragment = path.partition(/[?#]/)
      normalized_authority_and_path = authority_and_path.tr("\\", "/").gsub(/%5[Cc]/, "/")
      "#{normalized_authority_and_path}#{separator}#{query_and_fragment}"
    end

    def relative_path
      _path = url.path.gsub(/^\/+/, "/")
      # A host-relative path must start with "/" — otherwise Rails' redirect_to
      # concatenates it directly onto the request host (e.g. "dashboard" becomes
      # "https://gumroad.comdashboard"), which raises UnsafeRedirectError. Paths
      # that are only a query string (e.g. "?query=param") are left as-is.
      _path = "/#{_path}" unless _path.empty? || _path.start_with?("/")
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
