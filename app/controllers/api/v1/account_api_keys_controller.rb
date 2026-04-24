# frozen_string_literal: true

# CRUD for account-scoped API keys. Only administrators can manage them.
# GET    /api/v1/account_api_keys           list keys (raw tokens never returned)
# POST   /api/v1/account_api_keys           create a new key — raw token
#                                            returned ONCE in this response
# DELETE /api/v1/account_api_keys/:id       revoke a key (soft delete)
class Api::V1::AccountApiKeysController < Api::V1::BaseController
  before_action :require_admin!

  def index
    keys = AccountApiKey.where(account_id: Current.account_id)
                       .order(created_at: :desc)
    success_response(data: keys.map { |key| serialize(key) })
  end

  def create
    key = AccountApiKey.new(
      account_id: Current.account_id,
      created_by: Current.user,
      name: params[:name].to_s.strip
    )

    if key.save
      # Return the RAW token once — client must copy it now, it won't be
      # shown again (only last4 in subsequent list requests).
      success_response(
        data: serialize(key).merge(token: key.token),
        message: 'API key created. Copy the token now — it will not be shown again.',
        status: :created
      )
    else
      error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        key.errors.full_messages.join(', '),
        status: :unprocessable_entity
      )
    end
  end

  def destroy
    key = AccountApiKey.where(account_id: Current.account_id).find(params[:id])
    key.revoke!
    success_response(data: serialize(key), message: 'API key revoked')
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'API key not found', status: :not_found)
  end

  private

  def require_admin!
    return if Current.user&.administrator? || Current.evo_role_key.to_s == 'administrator'

    error_response(ApiErrorCodes::FORBIDDEN, 'Only administrators can manage API keys',
                   status: :forbidden)
  end

  def serialize(key)
    {
      id: key.id,
      name: key.name,
      last4: key.last4,
      created_by: { id: key.created_by_id, name: key.created_by&.name },
      last_used_at: key.last_used_at,
      revoked_at: key.revoked_at,
      active: key.active?,
      created_at: key.created_at
    }
  end
end
