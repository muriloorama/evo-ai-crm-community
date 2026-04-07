require 'net/http'
require 'json'

module ConfigTest
  class BmsTestService
    TIMEOUT = 15
    BMS_API_URL = 'https://bms-api.bri.us/services/send-email'

    # Validates the BMS API key by sending a minimal empty payload.
    # The API will reject the request (400) due to missing fields, but a
    # non-401/403 response proves the key is accepted. This approach avoids
    # sending actual emails while still verifying authentication.
    def call
      api_key = GlobalConfigService.load('BMS_API_SECRET', nil)
      return { success: false, message: 'BMS API key not configured' } if api_key.blank?

      uri = URI(BMS_API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT

      request = Net::HTTP::Post.new(uri)
      request['api-key'] = api_key
      request['Content-Type'] = 'application/json'
      request.body = {}.to_json

      response = http.request(request)
      status = response.code.to_i

      if [401, 403].include?(status)
        { success: false, message: 'BMS API key is invalid or expired' }
      elsif status < 500
        # 2xx = accepted, 400/422 = key valid but payload rejected — both confirm the key works
        { success: true, message: 'BMS API connection successful' }
      else
        { success: false, message: "BMS API returned HTTP #{response.code}" }
      end
    rescue Timeout::Error
      { success: false, message: "BMS API connection timed out after #{TIMEOUT} seconds" }
    rescue StandardError => e
      { success: false, message: "BMS connection failed: #{e.message}" }
    end
  end
end
