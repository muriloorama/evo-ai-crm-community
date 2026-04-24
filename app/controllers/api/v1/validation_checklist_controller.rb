# frozen_string_literal: true

# Account-wide validation checklist state for the Tutoriais page.
# GET  /api/v1/validation_checklist           list all checked items for current account
# POST /api/v1/validation_checklist           toggle a single item
#   body: { item_key: "string", checked: true|false }
class Api::V1::ValidationChecklistController < Api::V1::BaseController
  def index
    rows = ValidationCheckItem.where(account_id: Current.account_id)
                              .includes(:checked_by)
                              .order(updated_at: :desc)

    success_response(data: rows.map { |row| serialize(row) })
  end

  def toggle
    key = params[:item_key].to_s
    return error_response(ApiErrorCodes::VALIDATION_ERROR, 'item_key required',
                          status: :unprocessable_entity) if key.blank?

    if ActiveModel::Type::Boolean.new.cast(params[:checked])
      row = ValidationCheckItem.find_or_initialize_by(
        account_id: Current.account_id,
        item_key: key
      )
      row.checked_by = Current.user
      row.save!
      success_response(data: serialize(row), message: 'Item marcado')
    else
      ValidationCheckItem.where(account_id: Current.account_id, item_key: key).destroy_all
      success_response(data: { item_key: key, checked: false }, message: 'Item desmarcado')
    end
  end

  def reset
    ValidationCheckItem.where(account_id: Current.account_id).destroy_all
    success_response(data: [], message: 'Lista zerada')
  end

  private

  def serialize(row)
    {
      item_key: row.item_key,
      checked: true,
      checked_by: {
        id: row.checked_by_id,
        name: row.checked_by&.name
      },
      checked_at: row.updated_at
    }
  end
end
