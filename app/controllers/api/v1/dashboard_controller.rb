# frozen_string_literal: true

class Api::V1::DashboardController < Api::V1::BaseController
  require_permissions({
    customer: 'dashboard.read',
    contacts_by_location: 'dashboard.read'
  })

  def customer
    dashboard_data = Dashboard::CustomerDashboardService.new(
      params: dashboard_params
    ).call

    success_response(
      data: dashboard_data,
      message: 'Customer dashboard data retrieved successfully'
    )
  end

  # Aggregates contacts by Brazilian state (from
  # additional_attributes.location.state) so the dashboard can render a
  # heatmap of contact distribution. Unknown/empty states are bucketed as
  # "—" so the UI can call them out separately.
  def contacts_by_location
    results = Contact.where(account_id: Current.account_id)
                     .group("COALESCE(NULLIF(additional_attributes->'location'->>'state', ''), '—')")
                     .count
                     .map { |state, total| { state: state, total: total } }
                     .sort_by { |row| -row[:total] }

    success_response(
      data: results,
      message: 'Contact distribution retrieved successfully'
    )
  end

  private

  def dashboard_params
    params.permit(:pipeline_id, :team_id, :inbox_id, :user_id, :since, :until, :contact_type)
  end
end
