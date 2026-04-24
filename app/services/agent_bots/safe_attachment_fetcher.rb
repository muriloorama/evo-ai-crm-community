# frozen_string_literal: true

require 'net/http'
require 'resolv'
require 'ipaddr'

# Fetches attachment URLs configured by operators via agent_bot.bot_config.
# URLs are admin-controlled but still untrusted for SSRF purposes: we must
# reject non-http(s) schemes, private/loopback/link-local/metadata IPs,
# revalidate every redirect hop, and cap response size so a hostile URL
# can't be used to read internal services or exfiltrate arbitrary bytes
# through the tenant attachment UI.
class AgentBots::SafeAttachmentFetcher
  class Error < StandardError; end

  ALLOWED_SCHEMES = %w[http https].freeze
  MAX_BYTES       = 25 * 1024 * 1024
  MAX_REDIRECTS   = 3
  OPEN_TIMEOUT    = 5
  READ_TIMEOUT    = 15

  # IPAddr#{loopback?,link_local?,private?} cover the bulk of unroutable
  # ranges, but cloud-provider metadata IPs are globally routable and must
  # be blocked explicitly.
  METADATA_IPS = %w[
    169.254.169.254
    fd00:ec2::254
    100.100.100.200
  ].map { |ip| IPAddr.new(ip) }.freeze

  def self.call(url)
    new(url).fetch
  end

  def initialize(url)
    @url = url
  end

  def fetch
    uri       = parse_and_validate(@url)
    redirects = 0

    loop do
      result = perform_request(uri)

      case result[:status]
      when :success
        return result[:body]
      when :redirect
        redirects += 1
        raise Error, 'too many redirects' if redirects > MAX_REDIRECTS

        uri = parse_and_validate(URI.join(uri.to_s, result[:location].to_s).to_s)
      end
    end
  end

  private

  def parse_and_validate(url)
    uri = URI.parse(url)
    raise Error, "invalid scheme #{uri.scheme.inspect}" unless ALLOWED_SCHEMES.include?(uri.scheme)
    raise Error, 'host missing' if uri.host.to_s.empty?

    addresses = Resolv.getaddresses(uri.host)
    raise Error, "dns lookup failed for #{uri.host}" if addresses.empty?

    addresses.each do |addr|
      ip = IPAddr.new(addr)
      raise Error, "blocked ip #{addr}" if blocked_ip?(ip)
    end

    uri
  rescue URI::InvalidURIError, Resolv::ResolvError, IPAddr::Error => e
    raise Error, e.message
  end

  def blocked_ip?(ip)
    return true if ip.loopback? || ip.link_local? || ip.private?
    return true if METADATA_IPS.any? { |range| range.include?(ip) }

    false
  end

  def perform_request(uri)
    result = nil

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = uri.scheme == 'https'
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT

    http.start do |conn|
      req = Net::HTTP::Get.new(uri.request_uri)
      conn.request(req) do |response|
        result =
          case response
          when Net::HTTPSuccess
            { status: :success, body: read_streamed(response) }
          when Net::HTTPRedirection
            location = response['location']
            raise Error, 'redirect without location' if location.to_s.empty?

            { status: :redirect, location: location }
          else
            raise Error, "unexpected response #{response.code}"
          end
      end
    end

    result
  end

  def read_streamed(response)
    content_length = response['content-length']&.to_i
    raise Error, "response too large (content-length=#{content_length})" if content_length && content_length > MAX_BYTES

    buffer = String.new
    response.read_body do |chunk|
      buffer << chunk
      raise Error, 'response exceeded size cap' if buffer.bytesize > MAX_BYTES
    end

    StringIO.new(buffer)
  end
end
