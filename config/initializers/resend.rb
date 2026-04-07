require 'resend'

# Boot-time: use ENV fallback. Dynamic loading from DB happens per-email in ApplicationMailer.
Resend.api_key = if defined?(GlobalConfigService)
                   GlobalConfigService.load('RESEND_API_SECRET', ENV.fetch('RESEND_API_KEY', nil))
                 else
                   ENV.fetch('RESEND_API_KEY', nil)
                 end
