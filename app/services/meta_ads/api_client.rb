# Thin wrapper around the Meta Graph API. Handles GET requests with the
# access_token query param and parses JSON responses, raising on errors.
#
# Used by `MetaAds::TokenService` (validate + list ad accounts) and
# `MetaAds::SyncService` (pull campaign insights).
class MetaAds::ApiClient
  GRAPH_VERSION = 'v19.0'.freeze
  BASE_URL = "https://graph.facebook.com/#{GRAPH_VERSION}".freeze

  class ApiError < StandardError
    attr_reader :response_body, :status

    def initialize(message, response_body: nil, status: nil)
      super(message)
      @response_body = response_body
      @status = status
    end
  end

  def initialize(access_token)
    @access_token = access_token
  end

  def get(path, params = {})
    uri = URI.parse("#{BASE_URL}#{path.start_with?('/') ? path : "/#{path}"}")
    uri.query = URI.encode_www_form(params.merge(access_token: @access_token))

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    response = http.request(Net::HTTP::Get.new(uri))
    body = JSON.parse(response.body) rescue {}

    if response.is_a?(Net::HTTPSuccess)
      body
    else
      msg = body.dig('error', 'message') || "HTTP #{response.code}"
      raise ApiError.new(msg, response_body: body, status: response.code.to_i)
    end
  end

  # Paginated endpoint helper — yields each page of `data` and follows next links.
  def paginate(path, params = {})
    next_url = nil
    loop do
      result = next_url ? get_url(next_url) : get(path, params)
      yield(result['data'] || []) if result['data']
      next_url = result.dig('paging', 'next')
      break unless next_url
    end
  end

  private

  def get_url(url)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    response = http.request(Net::HTTP::Get.new(uri))
    JSON.parse(response.body) rescue {}
  end
end
