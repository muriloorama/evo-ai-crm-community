# BMS Email Provider Configuration
# Configure any global BMS settings here if needed

Rails.application.configure do
  config.after_initialize do
    begin
      Rails.logger.info "🔧 BMS INIT: Initializing BMS email provider"

      # Load configurations from GlobalConfig (database)
      bms_api_key = GlobalConfigService.load('BMS_API_SECRET', nil) if defined?(GlobalConfigService)
      bms_ippool = GlobalConfigService.load('BMS_IPPOOL', 'default') if defined?(GlobalConfigService)

      # Fallback to ENV if GlobalConfigService not available or returns nil
      bms_api_key ||= ENV['BMS_API_SECRET']
      bms_ippool ||= ENV.fetch('BMS_IPPOOL', 'default')

      if bms_api_key.present?
        Rails.logger.info "✅ BMS INIT: BMS_API_SECRET is configured from GlobalConfig"
        Rails.logger.info "✅ BMS INIT: BMS_IPPOOL set to: #{bms_ippool}"
        Rails.logger.info "✅ BMS INIT: BMS Email Provider configured successfully"
      else
        Rails.logger.warn "⚠️  BMS INIT: BMS_API_SECRET not found in GlobalConfig or ENV. BMS email provider will not be available."
      end

      Rails.logger.info "🔧 BMS INIT: BMS provider initialization complete"
    rescue => e
      Rails.logger.error "❌ BMS INIT: Error during initialization: #{e.message}"
      Rails.logger.warn "⚠️  BMS INIT: Falling back to ENV configuration"

      # Fallback to original ENV-based logic
      if ENV['BMS_API_SECRET'].present?
        Rails.logger.info "✅ BMS INIT: BMS_API_SECRET is configured from ENV"
        Rails.logger.info "✅ BMS INIT: BMS Email Provider configured from ENV as fallback"
      end
    end
  end
end
