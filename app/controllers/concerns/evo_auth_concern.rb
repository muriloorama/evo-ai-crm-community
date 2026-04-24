require 'digest'
require 'base64'
require 'json'

module EvoAuthConcern
  extend ActiveSupport::Concern

  AUTH_VALIDATE_CACHE_TTL = 20.seconds

  private

  def authenticate_user_with_evo_auth(token, token_type)
    Current.evo_auth_validation_cache ||= {}
    cache_key = evo_auth_validation_cache_key(token, token_type)
    user_data = Current.evo_auth_validation_cache[cache_key]

    auth_service = EvoAuthService.new
    unless user_data
      store_key = evo_auth_validation_store_key(cache_key)
      user_data = Rails.cache.read(store_key)

      unless user_data
        user_data = auth_service.validate_token(token: token, token_type: token_type)
        ttl = auth_validation_cache_ttl(token, token_type)
        Rails.cache.write(store_key, user_data, expires_in: ttl) if ttl.positive?
      end
    end

    Current.evo_auth_validation_cache[cache_key] = user_data

    set_current_user_from_auth_data(user_data, token, token_type)
    true
  rescue EvoAuthService::ValidationError => e
    Rails.logger.warn "EvoAuth: Token validation failed: #{e.message}"
    error_code = e.code.presence || ApiErrorCodes::UNAUTHORIZED
    error_status = e.status.presence || :unauthorized
    error_response(error_code, e.message, status: error_status)
    false
  rescue EvoAuthService::AuthenticationError => e
    Rails.logger.error "EvoAuth: Authentication service error: #{e.message}"
    error_response(ApiErrorCodes::SERVICE_UNAVAILABLE, 'Authentication service unavailable', status: :service_unavailable)
    false
  end

  def bearer_token_present?
    request.headers['Authorization']&.start_with?('Bearer ')
  end

  def set_current_user_from_auth_data(user_data, token, token_type)
    user = find_local_user(user_data['user'])
    raise EvoAuthService::ValidationError, 'User not found locally' unless user

    # Set current user
    Current.user = user
    @current_user = user
    Current.authentication_method = token_type

    Current.super_admin = !!user_data['super_admin']
    Current.accounts    = user_data['accounts'] || []

    active_account = resolve_active_account(user_data)
    Current.account        = active_account
    Current.account_id     = active_account&.dig('id')
    Current.account_number = active_account&.dig('number') || user_data['active_account_number']

    # Store the role key the user holds *in the active account* (or the global
    # role key if super_admin with no active account). Falls back to the top-level
    # role field for legacy single-account responses.
    Current.evo_role_key = resolve_role_key(user_data, active_account)

    # Store tokens for downstream services
    if token_type == 'bearer'
      Current.bearer_token = token
    elsif token_type == 'api_access_token'
      Current.api_access_token = token
    end
  end

  def resolve_active_account(user_data)
    accounts     = user_data['accounts'] || []
    active_id    = user_data['active_account_id']
    active_num   = user_data['active_account_number']
    super_admin  = !!user_data['super_admin']

    # Highest priority: trust the JWT's active_account_id when it's present.
    # For super_admins, the active workspace may not appear in their
    # memberships list — they are platform operators that can enter any
    # workspace from the switcher. Falling back to `accounts.first` here
    # silently undid the switch and made all data appear under Oramatech.
    if active_id.present?
      from_membership = accounts.find { |a| a['id'] == active_id }
      return from_membership if from_membership
      return { 'id' => active_id, 'number' => active_num } if super_admin
    end

    accounts.first
  end

  def resolve_role_key(user_data, active_account)
    active_account&.dig('role', 'key') ||
      user_data.dig('user', 'role', 'key') ||
      user_data.dig('role', 'key')
  end

  def find_local_user(user_data)
    return nil unless user_data

    User.find_by(email: user_data['email']) || User.find_by(id: user_data['id'])
  end

  # Override current_user method to return our authenticated user
  def current_user
    @current_user || Current.user
  end

  def evo_auth_validation_cache_key(token, token_type)
    "#{token_type}:#{Digest::SHA256.hexdigest(token.to_s)}"
  end

  def evo_auth_validation_store_key(cache_key)
    "evo_auth:validate:#{cache_key}"
  end

  def auth_validation_cache_ttl(token, token_type)
    ttl = AUTH_VALIDATE_CACHE_TTL
    return ttl unless token_type.to_s == 'bearer'

    payload = decode_jwt_payload(token)
    return ttl unless payload.is_a?(Hash) && payload['exp'].present?

    remaining = payload['exp'].to_i - Time.now.to_i
    return 0.seconds if remaining <= 0

    [ttl, remaining.seconds].min
  rescue StandardError
    ttl
  end

  def decode_jwt_payload(token)
    segments = token.to_s.split('.')
    return {} if segments.length < 2

    payload_segment = segments[1]
    padding = '=' * ((4 - payload_segment.length % 4) % 4)
    decoded = Base64.urlsafe_decode64("#{payload_segment}#{padding}")
    JSON.parse(decoded)
  rescue StandardError
    {}
  end
end
