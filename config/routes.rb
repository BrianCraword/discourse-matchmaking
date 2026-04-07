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
  post   "/admin/reset/:user_id"   => "profiles#admin_reset"
  post   "/admin/block/:user_id"   => "profiles#admin_block"

  # Admin queue endpoints
  get    "/admin/queue"             => "profiles#admin_queue"
  get    "/admin/profile/:user_id"  => "profiles#admin_profile_detail"
  get    "/admin/search"            => "profiles#admin_search"
end
