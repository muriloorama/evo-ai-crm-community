module ConfigTest
  class ResendTestService
    def call
      api_key = GlobalConfigService.load('RESEND_API_SECRET', ENV.fetch('RESEND_API_KEY', nil))
      return { success: false, message: 'Resend API key not configured' } if api_key.blank?

      client = Resend::Client.new(api_key: api_key)
      client.domains.list
      { success: true, message: 'Resend API connection successful' }
    rescue Resend::Error => e
      { success: false, message: "Resend API error: #{e.message}" }
    rescue StandardError => e
      { success: false, message: "Resend connection failed: #{e.message}" }
    end
  end
end
