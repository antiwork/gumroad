# frozen_string_literal: true

GOOGLE_CLOUD_PROJECT_ID = GlobalConfig.get("GOOGLE_CLOUD_PROJECT_ID")

GUMROAD_ADMIN_ID = GlobalConfig.get("GUMROAD_ADMIN_ID", Rails.env.staging? ? 978 : 767082) # admin@gumroad.com
GUMROAD_STARTED_DATE = Date.parse("2011-04-04")
PRODUCT_EVENT_TRACKING_STARTED_DATE = Date.parse("2012-10-13")
PROFILE_EVENT_TRACKING_STARTED_DATE = Date.parse("2013-08-19")
REFERRER_DOMAIN_FOR_GUMROAD_RECOMMENDED_PRODUCTS = "recommended_by_gumroad"

COMMON_REFERRERS_NAMES = {
  "dribbble.com" => "Dribbble",
  "facebook.com" => "Facebook",
  "google.com" => "Google",
  "gumroad.com" => "Gumroad",
  "pinterest.com" => "Pinterest",
  "reddit.com" => "Reddit",
  "shutterstock.com" => "Shutterstock",
  "tumblr.com" => "Tumblr",
  "api.twitter.com" => "Twitter",
  "t.co" => "Twitter",
  "twitter.com" => "Twitter",
  "youtube.com" => "Youtube"
}.freeze

STATES = %w[AA AE AP AL AK AZ AR CA CO CT DE FL GA HI ID IL IN
            IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH
            NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT
            VT VA WA WV WI WY DC].freeze

MILITARY_STATES = %w[AA AE AP].freeze

# For about 3% of US IPs we can deduce the country but not the state. Keep track of these, and also military states, under "other" so that they're
# counted towards the overall US stats.
STATE_OTHER = "other"

STATES_SUPPORTED_BY_ANALYTICS = STATES - MILITARY_STATES + [STATE_OTHER]

QUEBEC = "QC"

DENYLIST = %w[ a about account activate add admin administrator api app apps
               archive archives assets auth balance better blog cache cancel careers
               cart challenge changelog checkout codereview community compare config configuration
               connect contact create delete direct_messages discover documentation
               download downloads edit email employment enterprise facebook
               faq favorites feed feedback feeds fleet fleets follow
               followers following friend friends group groups gist help
               home hosting hostmaster idea ideas index info invitations
               invite is it json job jobs lists login logout logs mail map
               maps mine mis news oauth oauth_clients offers openid order
               orders organizations plans popular privacy projects put post
               read recruitment register remove replies root rss sales save
               search security sessions settings shop signup sitemap ssl
               ssladmin ssladministrator sslwebmaster status stories stream
               styleguide subscribe subscriptions support sysadmin
               sysadministrator terms tour translations trends twitter
               twittr update unfollow unsubscribe url user weather widget
               widgets wiki ww www wwww xfn xml xmpp yml yaml ladygaga
               kanye kanyewest randyjackson mariahcarey atrak deadmau5
               avicii prettylights justinbieber calvinharris katyperry
               rihanna shakira barackobama kimkardashian
               taylorswift taylorswift13 nickiminaj oprah jtimberlake
               theellenshow ellen selenagomez kaka aplusk love recommended_products pay
               _dmarc _domainkey blog cloud-front-static-1 creators
               customers domains domains-staging files files-3 iffy
               m production-custom-domain-with-ip production-sample-shop public-files sample-shop
               staging staging-1 staging-2 staging-assets staging-custom-domain-with-ip
               staging-files staging-public-files staging-logs staging-sample-shop staging-static-1
               staging-static-2 static-1 static-2 static-2-direct test-custom-domain
               transactions v3he4xy3rbwt].freeze

INTERNET_EXCEPTIONS = [SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ENETUNREACH, Errno::EHOSTUNREACH,
                       Errno::EADDRNOTAVAIL, EOFError, URI::InvalidURIError, Addressable::URI::InvalidURIError,
                       Timeout::Error, Net::HTTPBadResponse, Net::OpenTimeout, Net::ReadTimeout, OpenURI::HTTPError,
                       OpenSSL::SSL::SSLError, Faraday::ConnectionFailed].freeze

FILE_REGEX = {
  archive: /rar|zip|tar/i,
  audio: /mp3|aac|wma|wav|m4a|flac/i,
  epub_document: /epub/i,
  executable: /exe/i,
  document: /doc|docx|pdf|ppt|pptx/i,
  image: /jpeg|gif|png|jpg|tif|bmp|tiff/i,
  mobi_document: /mobi/i,
  psd_image: /psd/i,
  text_document: /txt|xml|json/i,
  video: /mp4|m4v|mov|mpeg|mpeg4|wmv|movie|ogv|avi/i,
  word_document: /doc/i
}.stringify_keys

REPLICAS_HOSTS = 1.upto(3).map do |i|
  [ENV["DATABASE_REPLICA#{i}_HOST"], ENV["DATABASE_WORKER_REPLICA#{i}_HOST"]]
end.flatten.keep_if(&:present?).uniq - [ENV["DATABASE_HOST"]]

MAX_FILE_NAME_BYTESIZE = 255

# https://www.elastic.co/guide/en/elasticsearch/reference/current/search-settings.html#search-settings-max-buckets
# When used in composite aggregations, it will end up determining how many times we need to paginate results.
# If the queries end up taking too much memory, consider lowering this number.
# This number can't be more than 65_535 (65_536 - 1 parent bucket).
ES_MAX_BUCKET_SIZE = 65_535
