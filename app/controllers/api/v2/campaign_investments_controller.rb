# Manual investment input feeding the Dashboard "Rastreamento" tab.
# Each row is one campaign's spend over a date range; ROI / CPL on the
# dashboard come from summing rows that overlap the selected period.
class Api::V2::CampaignInvestmentsController < Api::V1::BaseController
  require_permissions({
    index: 'reports.read',
    create: 'reports.create_custom',
    update: 'reports.create_custom',
    destroy: 'reports.create_custom'
  })

  before_action :set_investment, only: [:update, :destroy]
  before_action :block_manual_when_meta_connected, only: [:create, :update, :destroy]

  def index
    investments = CampaignInvestment.where(account_id: Current.account_id).order(period_start: :desc)
    investments = investments.overlapping(date_range) if params[:start_date].present? && params[:end_date].present?
    render json: investments.map { |i| serialize(i) }
  end

  def create
    investment = CampaignInvestment.new(investment_params.merge(account_id: Current.account_id))
    if investment.save
      render json: serialize(investment), status: :created
    else
      render json: { errors: investment.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @investment.update(investment_params)
      render json: serialize(@investment)
    else
      render json: { errors: @investment.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @investment.destroy
    head :no_content
  end

  private

  def block_manual_when_meta_connected
    return unless MetaAdAccount.where(account_id: Current.account_id).exists?

    render json: {
      errors: ['Há uma conta Meta Ads conectada — os valores de investimento são sincronizados automaticamente. Desconecte a conta Meta para editar manualmente.']
    }, status: :unprocessable_entity
  end

  def set_investment
    @investment = CampaignInvestment.where(account_id: Current.account_id).find(params[:id])
  end

  def investment_params
    params.require(:campaign_investment).permit(
      :campaign_key, :campaign_name, :source_type,
      :amount, :currency, :period_start, :period_end, :notes
    )
  end

  def date_range
    Date.parse(params[:start_date])..Date.parse(params[:end_date])
  end

  def serialize(investment)
    {
      id: investment.id,
      campaign_key: investment.campaign_key,
      campaign_name: investment.campaign_name,
      source_type: investment.source_type,
      amount: investment.amount.to_f,
      currency: investment.currency,
      period_start: investment.period_start,
      period_end: investment.period_end,
      notes: investment.notes,
      created_at: investment.created_at,
      updated_at: investment.updated_at
    }
  end
end
