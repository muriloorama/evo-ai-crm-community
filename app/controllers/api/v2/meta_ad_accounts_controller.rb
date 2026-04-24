# Manages Meta Ads (Facebook/Instagram) integration for the current account.
#
# Flow:
#   1. POST /validate_token  → user pastes token, gets list of ad accounts
#   2. POST /                → create record with chosen ad_account_id
#   3. POST /:id/sync_now    → trigger immediate sync
#   4. DELETE /:id           → disconnect
class Api::V2::MetaAdAccountsController < Api::V1::BaseController
  require_permissions({
    index: 'reports.read',
    show: 'reports.read',
    create: 'reports.create_custom',
    update: 'reports.create_custom',
    destroy: 'reports.create_custom'
  })

  before_action :set_account, only: [:show, :update, :destroy, :sync_now]

  def index
    accounts = MetaAdAccount.where(account_id: Current.account_id).order(created_at: :desc)
    render json: accounts.map { |a| serialize(a) }
  end

  def show
    render json: serialize(@account)
  end

  def validate_token
    token = params[:access_token].to_s
    return render(json: { ok: false, error: 'access_token is required' }, status: :bad_request) if token.blank?

    result = MetaAds::TokenService.new(token).validate
    render json: result
  end

  def create
    if MetaAdAccount.where(account_id: Current.account_id).exists?
      return render json: {
        errors: ['Já existe uma conta Meta Ads conectada. Desconecte a atual antes de conectar outra.']
      }, status: :unprocessable_entity
    end

    account = MetaAdAccount.new(create_params.merge(account_id: Current.account_id))
    if account.save
      MetaAds::SyncJob.perform_later(account.id)
      render json: serialize(account), status: :created
    else
      render json: { errors: account.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @account.update(update_params)
      render json: serialize(@account)
    else
      render json: { errors: @account.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def sync_now
    MetaAds::SyncJob.perform_later(@account.id)
    render json: { ok: true, message: 'Sync iniciada em background' }
  end

  def destroy
    @account.destroy
    head :no_content
  end

  private

  def set_account
    @account = MetaAdAccount.where(account_id: Current.account_id).find(params[:id])
  end

  def create_params
    params.require(:meta_ad_account).permit(
      :ad_account_id, :ad_account_name, :business_name,
      :access_token, :token_expires_at, :currency, :active
    )
  end

  def update_params
    params.require(:meta_ad_account).permit(
      :access_token, :token_expires_at, :currency, :active, :ad_account_name
    )
  end

  def serialize(a)
    {
      id: a.id,
      ad_account_id: a.ad_account_id,
      ad_account_name: a.ad_account_name,
      business_name: a.business_name,
      currency: a.currency,
      active: a.active,
      token_expires_at: a.token_expires_at,
      token_expired: a.token_expired?,
      token_expiring_soon: a.token_expiring_soon?,
      token_days_until_expiry: a.token_days_until_expiry,
      last_sync_at: a.last_sync_at,
      last_sync_status: a.last_sync_status,
      last_sync_error: a.last_sync_error,
      last_sync_campaigns_count: a.last_sync_campaigns_count,
      created_at: a.created_at
    }
  end
end
