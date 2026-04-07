class InstallationConfigPolicy < ApplicationPolicy
  # In single-tenant mode, has_permission? always returns true for all authenticated users.
  # Effective access control is: authenticate_request! (must be logged in) + administrator? (SuperAdmin type).
  # The has_permission? call future-proofs for multi-tenant permission granularity.
  def manage?
    @user&.administrator? || @user&.has_permission?('installation_configs.manage')
  end

  def index?
    manage?
  end

  def show?
    manage?
  end

  def create?
    manage?
  end

  def update?
    manage?
  end

  def destroy?
    manage?
  end
end
