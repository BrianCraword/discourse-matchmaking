# frozen_string_literal: true

DiscourseMatchmaking::Engine.routes.draw do
  # Profile CRUD
  get    "/profile"        => "profiles#show"
  post   "/profile"        => "profiles#create"
  put    "/profile"        => "profiles#update"
  delete "/profile"        => "profiles#destroy"

  # Consent management
  get    "/consent-status"  => "profiles#consent_status"
  post   "/grant-consent"   => "profiles#grant_consent"

  # Phase 5: Data export
  get    "/export"          => "profiles#export_data"

  # Admin verification actions
  post   "/admin/approve/:user_id" => "profiles#admin_approve"
  post   "/admin/reject/:user_id"  => "profiles#admin_reject"
end
