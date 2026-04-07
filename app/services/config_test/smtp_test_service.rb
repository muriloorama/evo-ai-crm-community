require 'net/smtp'

module ConfigTest
  class SmtpTestService
    TIMEOUT = 15

    def call
      smtp = Net::SMTP.new(smtp_address, smtp_port)
      smtp.open_timeout = TIMEOUT
      smtp.read_timeout = TIMEOUT

      configure_tls(smtp)
      smtp.start(smtp_domain, smtp_username, smtp_password, smtp_authentication) do |_|
        # Connection successful — start/login completed
      end

      { success: true, message: 'SMTP connection successful' }
    rescue Net::SMTPAuthenticationError => e
      { success: false, message: "Authentication failed: #{e.message}" }
    rescue Net::SMTPServerBusy => e
      { success: false, message: "Server busy: #{e.message}" }
    rescue Timeout::Error
      { success: false, message: "Connection timed out after #{TIMEOUT} seconds" }
    rescue Errno::ECONNREFUSED
      { success: false, message: 'Connection refused — check server address and port' }
    rescue SocketError => e
      { success: false, message: "Could not resolve hostname: #{e.message}" }
    rescue StandardError => e
      { success: false, message: "Connection failed: #{e.message}" }
    end

    private

    def smtp_address
      GlobalConfigService.load('SMTP_ADDRESS', ENV.fetch('SMTP_ADDRESS', 'localhost'))
    end

    def smtp_port
      GlobalConfigService.load('SMTP_PORT', ENV.fetch('SMTP_PORT', 587)).to_i
    end

    def smtp_username
      GlobalConfigService.load('SMTP_USERNAME', ENV.fetch('SMTP_USERNAME', nil))
    end

    def smtp_password
      GlobalConfigService.load('SMTP_PASSWORD_SECRET', ENV.fetch('SMTP_PASSWORD', nil))
    end

    def smtp_domain
      GlobalConfigService.load('SMTP_DOMAIN', ENV.fetch('SMTP_DOMAIN', nil))
    end

    def smtp_authentication
      auth = GlobalConfigService.load('SMTP_AUTHENTICATION', ENV.fetch('SMTP_AUTHENTICATION', 'login'))
      auth&.to_sym
    end

    def configure_tls(smtp)
      starttls = GlobalConfigService.load('SMTP_ENABLE_STARTTLS_AUTO', 'true')
      smtp.enable_starttls_auto if ActiveModel::Type::Boolean.new.cast(starttls)
    end
  end
end
