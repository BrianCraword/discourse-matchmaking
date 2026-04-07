import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/components/d-button";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";

function formatDate(isoString) {
  if (!isoString) return "—";
  const d = new Date(isoString);
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

function formatScore(score) {
  if (score === null || score === undefined) return "—";
  return (score * 100).toFixed(0) + "%";
}

function enrichProfile(p) {
  const recLabels = { approve: "Approve", reset: "Reset", review: "Review", reject: "Reject", no_profile: "No Profile" };
  const recClasses = { approve: "rec-approve", reset: "rec-reset", review: "rec-review", reject: "rec-reject", no_profile: "" };
  const status = p.verification_status || "";
  const statusLabels = { verified: "Verified", flagged: "Flagged", pending_interview: "Pending", rejected: "Rejected", unverified: "Unverified", no_profile: "No Profile" };
  return {
    user_id: p.user_id,
    username: p.username,
    name: p.name,
    recommendation: p.recommendation,
    recommendation_reason: p.recommendation_reason,
    key_concerns: p.key_concerns || [],
    confidence_score: p.confidence_score,
    verified_by: p.verified_by,
    verification_status: status,
    completion_percentage: p.completion_percentage,
    has_conversation: p.has_conversation,
    conversation_topic_id: p.conversation_topic_id,
    profile_excerpts: p.profile_excerpts || {},
    scores: p.scores || {},
    confidenceDisplay: formatScore(p.confidence_score),
    recBadgeClass: recClasses[p.recommendation] || "",
    recBadgeLabel: recLabels[p.recommendation] || p.recommendation || "—",
    statusLabel: statusLabels[status] || status || "—",
    statusClass: "status-" + status,
    firstConcern: (p.key_concerns && p.key_concerns.length > 0) ? p.key_concerns[0] : "—",
    registeredDisplay: formatDate(p.registered_at),
    verifiedAtDisplay: formatDate(p.verified_at),
    coherenceDisplay: formatScore(p.scores?.coherence),
    depthDisplay: formatScore(p.scores?.depth),
    theologyDisplay: formatScore(p.scores?.theological_consistency),
    engagementDisplay: formatScore(p.scores?.engagement_quality),
    completenessDisplay: formatScore(p.scores?.interview_completeness),
    hasConcerns: !!(p.key_concerns && p.key_concerns.length > 0),
    hasScores: !!(p.scores?.coherence || p.scores?.depth),
    hasTestimony: !!(p.profile_excerpts?.testimony),
    hasLifeGoals: !!(p.profile_excerpts?.life_goals),
    hasPartner: !!(p.profile_excerpts?.partner_description),
    hasMinistry: !!(p.profile_excerpts?.ministry_involvement),
    hasDenomination: !!(p.profile_excerpts?.denomination),
    hasAttendance: !!(p.profile_excerpts?.church_attendance),
    hasReason: !!p.recommendation_reason,
    hasProfile: status !== "no_profile",
    isFlagged: status === "flagged",
    isVerified: status === "verified",
    isPending: status === "pending_interview" || status === "unverified",
    isRejected: status === "rejected",
  };
}

export default class AdminMatchmakingVerificationQueue extends Component {
  @tracked activeTab = "flagged";
  @tracked loading = true;
  @tracked error = null;
  @tracked _flagged = [];
  @tracked _pending = [];
  @tracked _verified = [];
  @tracked _rejected = [];
  @tracked expandedUserId = null;
  @tracked confirmActionName = null;
  @tracked confirmUserId = null;

  // Search state
  @tracked searchQuery = "";
  @tracked searchResults = [];
  @tracked searchLoading = false;
  @tracked searchPerformed = false;

  constructor() {
    super(...arguments);
    this.loadQueue();
  }

  get flagged() { return this._flagged.map((p) => this._withState(p)); }
  get pending() { return this._pending.map((p) => this._withState(p)); }
  get verified() { return this._verified.map((p) => this._withState(p)); }
  get rejected() { return this._rejected.map((p) => this._withState(p)); }
  get searchList() { return this.searchResults.map((p) => this._withState(p)); }

  _withState(p) {
    const uid = p.user_id;
    return Object.assign({}, p, {
      isExpanded: this.expandedUserId === uid,
      confirmApprove: this.confirmActionName === "approve" && this.confirmUserId === uid,
      confirmReset: this.confirmActionName === "reset" && this.confirmUserId === uid,
      confirmReject: this.confirmActionName === "reject" && this.confirmUserId === uid,
      confirmBlock: this.confirmActionName === "block" && this.confirmUserId === uid,
    });
  }

  get currentList() {
    if (this.activeTab === "search") return this.searchList;
    if (this.activeTab === "flagged") return this.flagged;
    if (this.activeTab === "pending") return this.pending;
    if (this.activeTab === "verified") return this.verified;
    if (this.activeTab === "rejected") return this.rejected;
    return [];
  }

  get flaggedCount() { return this._flagged.length; }
  get pendingCount() { return this._pending.length; }
  get verifiedCount() { return this._verified.length; }
  get rejectedCount() { return this._rejected.length; }
  get isFlaggedTab() { return this.activeTab === "flagged"; }
  get isPendingTab() { return this.activeTab === "pending"; }
  get isVerifiedTab() { return this.activeTab === "verified"; }
  get isRejectedTab() { return this.activeTab === "rejected"; }
  get isSearchTab() { return this.activeTab === "search"; }

  get emptyMessage() {
    const msgs = {
      flagged: "No flagged users awaiting review.",
      pending: "No users pending interview.",
      verified: "No recently verified users.",
      rejected: "No rejected users.",
      search: this.searchPerformed ? "No users found." : "Enter a username to search.",
    };
    return msgs[this.activeTab] || "No data.";
  }

  @action async loadQueue() {
    this.loading = true;
    this.error = null;
    try {
      const result = await ajax("/matchmaking/admin/queue");
      this._flagged = (result.flagged || []).map(enrichProfile);
      this._pending = (result.pending || []).map(enrichProfile);
      this._verified = (result.verified || []).map(enrichProfile);
      this._rejected = (result.rejected || []).map(enrichProfile);
    } catch (e) {
      this.error = "Failed to load verification queue.";
      popupAjaxError(e);
    } finally {
      this.loading = false;
    }
  }

  @action switchTab(tab) {
    this.activeTab = tab;
    this.expandedUserId = null;
    this.confirmActionName = null;
    this.confirmUserId = null;
  }

  @action toggleExpand(userId) {
    this.expandedUserId = this.expandedUserId === userId ? null : userId;
    this.confirmActionName = null;
    this.confirmUserId = null;
  }

  @action requestConfirm(actionName, userId) {
    this.confirmActionName = actionName;
    this.confirmUserId = userId;
  }

  @action cancelConfirm() {
    this.confirmActionName = null;
    this.confirmUserId = null;
  }

  @action async performAction(actionName, userId) {
    this.confirmActionName = null;
    this.confirmUserId = null;
    try {
      await ajax(`/matchmaking/admin/${actionName}/${userId}`, { type: "POST" });
      await this.loadQueue();
      // Re-run search if we're on the search tab so results update
      if (this.activeTab === "search" && this.searchQuery.trim()) {
        await this.doSearch();
      }
      this.expandedUserId = null;
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action stopProp(e) { e.stopPropagation(); }

  @action updateSearchQuery(e) {
    this.searchQuery = e.target.value;
  }

  @action handleSearchKeydown(e) {
    if (e.key === "Enter") {
      this.doSearch();
    }
  }

  @action async doSearch() {
    const q = this.searchQuery.trim();
    if (!q) return;

    this.searchLoading = true;
    this.searchPerformed = false;
    this.activeTab = "search";
    this.expandedUserId = null;
    this.confirmActionName = null;
    this.confirmUserId = null;

    try {
      const result = await ajax(`/matchmaking/admin/search?q=${encodeURIComponent(q)}`);
      this.searchResults = (result.results || []).map(enrichProfile);
      this.searchPerformed = true;
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.searchLoading = false;
    }
  }

  @action clearSearch() {
    this.searchQuery = "";
    this.searchResults = [];
    this.searchPerformed = false;
    this.activeTab = "flagged";
  }

  <template>
    <div class="admin-matchmaking-queue">
      <div class="queue-header">
        <h2>Verification Queue</h2>
        <div class="header-actions">
          <div class="search-bar">
            <input
              type="text"
              placeholder="Search by username..."
              value={{this.searchQuery}}
              class="search-input"
              {{on "input" this.updateSearchQuery}}
              {{on "keydown" this.handleSearchKeydown}}
            />
            <DButton @action={{this.doSearch}} @icon="magnifying-glass" class="btn-primary btn-small" @title="matchmaking.admin.search_title" />
            {{#if this.isSearchTab}}
              <DButton @action={{this.clearSearch}} @icon="xmark" class="btn-default btn-small" @title="matchmaking.admin.clear_search" />
            {{/if}}
          </div>
          <DButton @action={{this.loadQueue}} @icon="arrows-rotate" @label="matchmaking.admin.refresh" class="btn-default btn-small" />
        </div>
      </div>

      <div class="queue-tabs">
        <button type="button" class="btn btn-flat queue-tab {{if this.isFlaggedTab 'active'}}" {{on "click" (fn this.switchTab "flagged")}}>Needs Action{{#if this.flaggedCount}} <span class="badge-count flagged-badge">{{this.flaggedCount}}</span>{{/if}}</button>
        <button type="button" class="btn btn-flat queue-tab {{if this.isPendingTab 'active'}}" {{on "click" (fn this.switchTab "pending")}}>Pending Interview{{#if this.pendingCount}} <span class="badge-count pending-badge">{{this.pendingCount}}</span>{{/if}}</button>
        <button type="button" class="btn btn-flat queue-tab {{if this.isVerifiedTab 'active'}}" {{on "click" (fn this.switchTab "verified")}}>Recent Verified</button>
        <button type="button" class="btn btn-flat queue-tab {{if this.isRejectedTab 'active'}}" {{on "click" (fn this.switchTab "rejected")}}>Rejected{{#if this.rejectedCount}} <span class="badge-count rejected-badge">{{this.rejectedCount}}</span>{{/if}}</button>
        {{#if this.isSearchTab}}
          <button type="button" class="btn btn-flat queue-tab active">Search Results</button>
        {{/if}}
      </div>

      {{#if this.loading}}
        <div class="queue-loading">Loading verification data...</div>
      {{else if this.searchLoading}}
        <div class="queue-loading">Searching...</div>
      {{else if this.error}}
        <div class="queue-error">{{this.error}}</div>
      {{else if this.currentList.length}}
        <div class="queue-table-wrapper">

          {{! ── FLAGGED TAB ── }}
          {{#if this.isFlaggedTab}}
            {{#each this.currentList as |profile|}}
              <div class="queue-card {{if profile.isExpanded 'expanded'}}" role="button" {{on "click" (fn this.toggleExpand profile.user_id)}}>
                <div class="card-summary">
                  <div class="card-user">
                    <a href="/admin/users/{{profile.user_id}}/{{profile.username}}" class="username-link" {{on "click" this.stopProp}}>{{profile.username}}</a>
                    {{#if profile.name}}<span class="user-realname">{{profile.name}}</span>{{/if}}
                  </div>
                  <div class="card-meta">
                    <span class="confidence-score">{{profile.confidenceDisplay}}</span>
                    <span class="rec-badge {{profile.recBadgeClass}}">{{profile.recBadgeLabel}}</span>
                  </div>
                  <div class="card-concern">{{profile.firstConcern}}</div>
                  <div class="card-actions" {{on "click" this.stopProp}}>
                    {{#if profile.confirmApprove}}
                      <span class="confirm-prompt">Approve? <DButton @action={{fn this.performAction "approve" profile.user_id}} @label="matchmaking.admin.yes" class="btn-primary btn-small" /> <DButton @action={{this.cancelConfirm}} @label="matchmaking.admin.no" class="btn-default btn-small" /></span>
                    {{else if profile.confirmReset}}
                      <span class="confirm-prompt">Reset? <DButton @action={{fn this.performAction "reset" profile.user_id}} @label="matchmaking.admin.yes" class="btn-primary btn-small" /> <DButton @action={{this.cancelConfirm}} @label="matchmaking.admin.no" class="btn-default btn-small" /></span>
                    {{else if profile.confirmReject}}
                      <span class="confirm-prompt">Reject? <DButton @action={{fn this.performAction "reject" profile.user_id}} @label="matchmaking.admin.yes" class="btn-danger btn-small" /> <DButton @action={{this.cancelConfirm}} @label="matchmaking.admin.no" class="btn-default btn-small" /></span>
                    {{else if profile.confirmBlock}}
                      <span class="confirm-prompt">Reject + Block IP? <DButton @action={{fn this.performAction "block" profile.user_id}} @label="matchmaking.admin.yes" class="btn-danger btn-small" /> <DButton @action={{this.cancelConfirm}} @label="matchmaking.admin.no" class="btn-default btn-small" /></span>
                    {{else}}
                      <DButton @action={{fn this.requestConfirm "approve" profile.user_id}} @icon="check" @title="matchmaking.admin.approve_title" class="btn-primary btn-small" />
                      <DButton @action={{fn this.requestConfirm "reset" profile.user_id}} @icon="arrows-rotate" @title="matchmaking.admin.reset_title" class="btn-default btn-small" />
                      <DButton @action={{fn this.requestConfirm "reject" profile.user_id}} @icon="xmark" @title="matchmaking.admin.reject_title" class="btn-danger btn-small" />
                      <DButton @action={{fn this.requestConfirm "block" profile.user_id}} @icon="ban" @title="matchmaking.admin.block_title" class="btn-danger btn-small" />
                    {{/if}}
                  </div>
                </div>
                {{#if profile.isExpanded}}
                  <div class="card-detail">
                    {{#if profile.hasReason}}<div class="detail-section"><h4>Recommendation</h4><p class="rec-reason">{{profile.recommendation_reason}}</p></div>{{/if}}
                    {{#if profile.hasConcerns}}<div class="detail-section"><h4>Key Concerns</h4><ul class="concerns-list">{{#each profile.key_concerns as |concern|}}<li>{{concern}}</li>{{/each}}</ul></div>{{/if}}
                    {{#if profile.hasScores}}<div class="detail-section"><h4>Scores</h4><div class="scores-grid"><span class="score-chip">Coherence {{profile.coherenceDisplay}}</span><span class="score-chip">Depth {{profile.depthDisplay}}</span><span class="score-chip">Theology {{profile.theologyDisplay}}</span><span class="score-chip">Engagement {{profile.engagementDisplay}}</span><span class="score-chip">Completeness {{profile.completenessDisplay}}</span></div></div>{{/if}}
                    <div class="detail-section"><h4>Profile</h4><div class="excerpts-grid">
                      {{#if profile.hasDenomination}}<div class="excerpt-item"><strong>Denomination:</strong> {{profile.profile_excerpts.denomination}}</div>{{/if}}
                      {{#if profile.hasAttendance}}<div class="excerpt-item"><strong>Attendance:</strong> {{profile.profile_excerpts.church_attendance}}</div>{{/if}}
                      {{#if profile.hasTestimony}}<div class="excerpt-item full-width"><strong>Testimony:</strong> {{profile.profile_excerpts.testimony}}</div>{{/if}}
                      {{#if profile.hasLifeGoals}}<div class="excerpt-item full-width"><strong>Life Goals:</strong> {{profile.profile_excerpts.life_goals}}</div>{{/if}}
                      {{#if profile.hasPartner}}<div class="excerpt-item full-width"><strong>Partner:</strong> {{profile.profile_excerpts.partner_description}}</div>{{/if}}
                      {{#if profile.hasMinistry}}<div class="excerpt-item full-width"><strong>Ministry:</strong> {{profile.profile_excerpts.ministry_involvement}}</div>{{/if}}
                    </div></div>
                    <div class="detail-links">
                      {{#if profile.conversation_topic_id}}<a href="/t/{{profile.conversation_topic_id}}" class="btn btn-default btn-small" target="_blank" rel="noopener noreferrer">View Transcript</a>{{/if}}
                      <a href="/admin/users/{{profile.user_id}}/{{profile.username}}" class="btn btn-default btn-small">Admin User Page</a>
                    </div>
                  </div>
                {{/if}}
              </div>
            {{/each}}

          {{! ── SEARCH RESULTS TAB ── }}
          {{else if this.isSearchTab}}
            {{#each this.currentList as |profile|}}
              <div class="queue-card {{if profile.isExpanded 'expanded'}}" role="button" {{on "click" (fn this.toggleExpand profile.user_id)}}>
                <div class="card-summary">
                  <div class="card-user">
                    <a href="/admin/users/{{profile.user_id}}/{{profile.username}}" class="username-link" {{on "click" this.stopProp}}>{{profile.username}}</a>
                    {{#if profile.name}}<span class="user-realname">{{profile.name}}</span>{{/if}}
                  </div>
                  <div class="card-meta">
                    <span class="rec-badge {{profile.statusClass}}">{{profile.statusLabel}}</span>
                    {{#if profile.hasProfile}}<span class="meta-label">Profile {{profile.completion_percentage}}%</span>{{/if}}
                    {{#if profile.confidence_score}}<span class="confidence-score">{{profile.confidenceDisplay}}</span>{{/if}}
                  </div>
                  <div class="card-actions" {{on "click" this.stopProp}}>
                    {{#if profile.hasProfile}}
                      {{#if profile.confirmApprove}}
                        <span class="confirm-prompt">Approve? <DButton @action={{fn this.performAction "approve" profile.user_id}} @label="matchmaking.admin.yes" class="btn-primary btn-small" /> <DButton @action={{this.cancelConfirm}} @label="matchmaking.admin.no" class="btn-default btn-small" /></span>
                      {{else if profile.confirmReset}}
                        <span class="confirm-prompt">Reset? <DButton @action={{fn this.performAction "reset" profile.user_id}} @label="matchmaking.admin.yes" class="btn-primary btn-small" /> <DButton @action={{this.cancelConfirm}} @label="matchmaking.admin.no" class="btn-default btn-small" /></span>
                      {{else if profile.confirmReject}}
                        <span class="confirm-prompt">Reject? <DButton @action={{fn this.performAction "reject" profile.user_id}} @label="matchmaking.admin.yes" class="btn-danger btn-small" /> <DButton @action={{this.cancelConfirm}} @label="matchmaking.admin.no" class="btn-default btn-small" /></span>
                      {{else if profile.confirmBlock}}
                        <span class="confirm-prompt">Reject + Block IP? <DButton @action={{fn this.performAction "block" profile.user_id}} @label="matchmaking.admin.yes" class="btn-danger btn-small" /> <DButton @action={{this.cancelConfirm}} @label="matchmaking.admin.no" class="btn-default btn-small" /></span>
                      {{else}}
                        {{#if profile.isFlagged}}
                          <DButton @action={{fn this.requestConfirm "approve" profile.user_id}} @icon="check" @title="matchmaking.admin.approve_title" class="btn-primary btn-small" />
                        {{/if}}
                        <DButton @action={{fn this.requestConfirm "reset" profile.user_id}} @icon="arrows-rotate" @title="matchmaking.admin.reset_title" class="btn-default btn-small" />
                        {{#if profile.isVerified}}
                          <DButton @action={{fn this.requestConfirm "reject" profile.user_id}} @icon="xmark" @title="matchmaking.admin.reject_title" class="btn-danger btn-small" />
                        {{/if}}
                        {{#if profile.isFlagged}}
                          <DButton @action={{fn this.requestConfirm "reject" profile.user_id}} @icon="xmark" @title="matchmaking.admin.reject_title" class="btn-danger btn-small" />
                          <DButton @action={{fn this.requestConfirm "block" profile.user_id}} @icon="ban" @title="matchmaking.admin.block_title" class="btn-danger btn-small" />
                        {{/if}}
                      {{/if}}
                    {{/if}}
                  </div>
                </div>
                {{#if profile.isExpanded}}
                  <div class="card-detail">
                    {{#unless profile.hasProfile}}
                      <div class="detail-section"><p class="rec-reason">This user has not created a matchmaking profile.</p></div>
                    {{else}}
                      {{#if profile.hasReason}}<div class="detail-section"><h4>Recommendation</h4><p class="rec-reason">{{profile.recommendation_reason}}</p></div>{{/if}}
                      {{#if profile.hasConcerns}}<div class="detail-section"><h4>Key Concerns</h4><ul class="concerns-list">{{#each profile.key_concerns as |concern|}}<li>{{concern}}</li>{{/each}}</ul></div>{{/if}}
                      {{#if profile.hasScores}}<div class="detail-section"><h4>Scores</h4><div class="scores-grid"><span class="score-chip">Coherence {{profile.coherenceDisplay}}</span><span class="score-chip">Depth {{profile.depthDisplay}}</span><span class="score-chip">Theology {{profile.theologyDisplay}}</span><span class="score-chip">Engagement {{profile.engagementDisplay}}</span><span class="score-chip">Completeness {{profile.completenessDisplay}}</span></div></div>{{/if}}
                      <div class="detail-section"><h4>Profile</h4><div class="excerpts-grid">
                        {{#if profile.hasDenomination}}<div class="excerpt-item"><strong>Denomination:</strong> {{profile.profile_excerpts.denomination}}</div>{{/if}}
                        {{#if profile.hasAttendance}}<div class="excerpt-item"><strong>Attendance:</strong> {{profile.profile_excerpts.church_attendance}}</div>{{/if}}
                        {{#if profile.hasTestimony}}<div class="excerpt-item full-width"><strong>Testimony:</strong> {{profile.profile_excerpts.testimony}}</div>{{/if}}
                        {{#if profile.hasLifeGoals}}<div class="excerpt-item full-width"><strong>Life Goals:</strong> {{profile.profile_excerpts.life_goals}}</div>{{/if}}
                        {{#if profile.hasPartner}}<div class="excerpt-item full-width"><strong>Partner:</strong> {{profile.profile_excerpts.partner_description}}</div>{{/if}}
                        {{#if profile.hasMinistry}}<div class="excerpt-item full-width"><strong>Ministry:</strong> {{profile.profile_excerpts.ministry_involvement}}</div>{{/if}}
                      </div></div>
                      <div class="detail-links">
                        {{#if profile.conversation_topic_id}}<a href="/t/{{profile.conversation_topic_id}}" class="btn btn-default btn-small" target="_blank" rel="noopener noreferrer">View Transcript</a>{{/if}}
                        <a href="/admin/users/{{profile.user_id}}/{{profile.username}}" class="btn btn-default btn-small">Admin User Page</a>
                      </div>
                    {{/unless}}
                  </div>
                {{/if}}
              </div>
            {{/each}}

          {{! ── PENDING TAB ── }}
          {{else if this.isPendingTab}}
            {{#each this.currentList as |profile|}}
              <div class="queue-card simple"><div class="card-summary">
                <div class="card-user"><a href="/admin/users/{{profile.user_id}}/{{profile.username}}" class="username-link">{{profile.username}}</a>{{#if profile.name}}<span class="user-realname">{{profile.name}}</span>{{/if}}</div>
                <div class="card-meta"><span class="meta-label">Registered {{profile.registeredDisplay}}</span><span class="meta-label">Profile {{profile.completion_percentage}}%</span>{{#if profile.has_conversation}}<span class="has-conv">Has conversation</span>{{else}}<span class="no-conv">No conversation</span>{{/if}}</div>
              </div></div>
            {{/each}}

          {{! ── VERIFIED TAB ── }}
          {{else if this.isVerifiedTab}}
            {{#each this.currentList as |profile|}}
              <div class="queue-card simple"><div class="card-summary">
                <div class="card-user"><a href="/admin/users/{{profile.user_id}}/{{profile.username}}" class="username-link">{{profile.username}}</a></div>
                <div class="card-meta"><span class="meta-label">{{profile.verifiedAtDisplay}}</span><span class="meta-label">by {{profile.verified_by}}</span><span class="confidence-score">{{profile.confidenceDisplay}}</span></div>
              </div></div>
            {{/each}}

          {{! ── REJECTED TAB ── }}
          {{else if this.isRejectedTab}}
            {{#each this.currentList as |profile|}}
              <div class="queue-card"><div class="card-summary">
                <div class="card-user"><a href="/admin/users/{{profile.user_id}}/{{profile.username}}" class="username-link">{{profile.username}}</a></div>
                <div class="card-meta"><span class="meta-label">Registered {{profile.registeredDisplay}}</span></div>
                <div class="card-actions" {{on "click" this.stopProp}}>
                  {{#if profile.confirmReset}}
                    <span class="confirm-prompt">Reset? <DButton @action={{fn this.performAction "reset" profile.user_id}} @label="matchmaking.admin.yes" class="btn-primary btn-small" /> <DButton @action={{this.cancelConfirm}} @label="matchmaking.admin.no" class="btn-default btn-small" /></span>
                  {{else if profile.confirmBlock}}
                    <span class="confirm-prompt">Block IP? <DButton @action={{fn this.performAction "block" profile.user_id}} @label="matchmaking.admin.yes" class="btn-danger btn-small" /> <DButton @action={{this.cancelConfirm}} @label="matchmaking.admin.no" class="btn-default btn-small" /></span>
                  {{else}}
                    <DButton @action={{fn this.requestConfirm "reset" profile.user_id}} @icon="arrows-rotate" @title="matchmaking.admin.reset_title" class="btn-default btn-small" />
                    <DButton @action={{fn this.requestConfirm "block" profile.user_id}} @icon="ban" @title="matchmaking.admin.block_title" class="btn-danger btn-small" />
                  {{/if}}
                </div>
              </div></div>
            {{/each}}
          {{/if}}

        </div>
      {{else}}
        <div class="queue-empty">{{this.emptyMessage}}</div>
      {{/if}}
    </div>
  </template>
}
