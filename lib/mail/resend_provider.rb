module Mail
  class ResendProvider
    class DeliveryError < StandardError; end

    attr_reader :settings

    def initialize(settings = {})
      @settings = settings
    end

    def deliver!(mail)
      client = build_client
      client.emails.send(
        from: mail.header[:from].to_s,
        to: mail.header[:to].to_s,
        subject: mail.header[:subject].to_s,
        html: mail.decoded,
        text: sanitize_html(mail.decoded)
      )
    rescue Resend::Error => e
      raise DeliveryError, "Failed to send email: #{e.message}"
    rescue StandardError => e
      raise DeliveryError, "An error occurred while sending email: #{e.message}"
    end

    private

    def build_client
      api_key = settings[:api_key] || Resend.api_key
      Resend::Client.new(api_key: api_key)
    end

    def sanitize_html(html)
      sanitized = ActionView::Base.full_sanitizer.sanitize(html)
      # NOTE: Remove more than two consecutive newlines
      sanitized.lines.map(&:strip).join("\n").gsub(/\n{3,}/, "\n\n").strip
    end
  end
end
