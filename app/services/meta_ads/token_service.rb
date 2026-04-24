# Validates a Meta access token and lists the ad accounts it can read.
# Used during the "Conectar Meta" flow so the operator picks which ad
# account to sync from a dropdown.
class MetaAds::TokenService
  def initialize(access_token)
    @client = MetaAds::ApiClient.new(access_token)
  end

  # Returns { ok: true, user: {...}, ad_accounts: [...] } on success
  # or { ok: false, error: '...' } on failure.
  def validate
    me = @client.get('/me', fields: 'id,name')
    accounts = @client.get('/me/adaccounts', fields: 'id,name,account_status,business_name,currency')

    {
      ok: true,
      user: { id: me['id'], name: me['name'] },
      ad_accounts: (accounts['data'] || []).map do |a|
        {
          id: a['id'],
          name: a['name'],
          currency: a['currency'],
          business_name: a['business_name'],
          status: a['account_status']
        }
      end
    }
  rescue MetaAds::ApiClient::ApiError => e
    { ok: false, error: e.message, status: e.status }
  end
end
